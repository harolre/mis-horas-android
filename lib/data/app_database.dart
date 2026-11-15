import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import 'attachment_store.dart';
import '../domain/work_time.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  final ValueNotifier<int> revision = ValueNotifier(0);
  Database? _database;
  Future<void>? _attachmentMigration;

  void _notifyChanged() => revision.value++;

  Future<Database> get database async {
    if (_database != null) {
      await _attachmentMigration;
      return _database!;
    }
    final path = p.join(await getDatabasesPath(), 'mis_horas.db');
    _database = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            color INTEGER NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE movements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            account_id INTEGER NOT NULL,
            start_minute INTEGER NOT NULL,
            end_minute INTEGER NOT NULL,
            break_minutes INTEGER NOT NULL DEFAULT 0,
            crosses_midnight INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (account_id) REFERENCES accounts (id)
          )
        ''');
        await db.execute(
          'CREATE INDEX movements_date_index ON movements(date)',
        );
        await db.execute('''
          CREATE TABLE days (
            date TEXT PRIMARY KEY,
            kind TEXT NOT NULL DEFAULT 'work',
            note TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            name TEXT NOT NULL,
            mime TEXT NOT NULL,
            size INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            data BLOB NOT NULL,
            file_path TEXT,
            thumbnail_path TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX attachments_date_index ON attachments(date, created_at)',
        );
        await db.execute('''
          CREATE TABLE settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            daily_targets TEXT NOT NULL,
            date_overrides TEXT NOT NULL DEFAULT '',
            week_start INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await db.insert('accounts', {
          'name': 'Trabajo',
          'color': 0xff3978f6,
          'archived': 0,
        });
        await db.insert('settings', {
          'id': 1,
          'daily_targets': '480,480,480,480,480,0,0',
          'date_overrides': '',
          'week_start': 1,
        });
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE settings ADD COLUMN date_overrides TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE days ADD COLUMN note TEXT NOT NULL DEFAULT ''",
          );
          await db.execute('''
            CREATE TABLE attachments (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date TEXT NOT NULL,
              name TEXT NOT NULL,
              mime TEXT NOT NULL,
              size INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              data BLOB NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX attachments_date_index ON attachments(date, created_at)',
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE settings ADD COLUMN week_start INTEGER NOT NULL DEFAULT 1',
          );
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE attachments ADD COLUMN file_path TEXT');
          await db.execute(
            'ALTER TABLE attachments ADD COLUMN thumbnail_path TEXT',
          );
        }
      },
    );
    _attachmentMigration = _migrateLegacyAttachments(_database!);
    await _attachmentMigration;
    return _database!;
  }

  Future<void> _migrateLegacyAttachments(Database db) async {
    final ids = await db.query(
      'attachments',
      columns: ['id'],
      where: 'file_path IS NULL',
      orderBy: 'id',
    );
    if (ids.isEmpty) return;
    final store = await AttachmentStore.open();
    for (final item in ids) {
      final id = item['id'] as int;
      final rows = await db.query(
        'attachments',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final row = rows.first;
      final bytes = (row['data'] as List?)?.cast<int>() ?? const <int>[];
      if (bytes.isEmpty) {
        throw StateError('No se pudo migrar el adjunto ${row['name']}.');
      }
      final stored = await store.importBytes(
        id: id.toString(),
        name: row['name'] as String,
        mime: row['mime'] as String,
        bytes: bytes,
      );
      await db.update(
        'attachments',
        {
          'size': stored.size,
          'file_path': stored.filePath,
          'thumbnail_path': stored.thumbnailPath,
          'data': <int>[],
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<List<Map<String, Object?>>> accounts() async {
    final db = await database;
    return db.query('accounts', where: 'archived = 0', orderBy: 'name');
  }

  Future<List<Map<String, Object?>>> allAccounts() async {
    final db = await database;
    return db.query('accounts', orderBy: 'archived, name');
  }

  Future<int> createAccount(String name, int color) async {
    final cleanName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleanName.isEmpty) {
      throw ArgumentError('Escribe un nombre para la cuenta.');
    }
    if (cleanName.length > 40) {
      throw ArgumentError('El nombre no puede superar los 40 caracteres.');
    }
    final db = await database;
    final duplicate = await db.query(
      'accounts',
      where: 'lower(name) = lower(?)',
      whereArgs: [cleanName],
      limit: 1,
    );
    if (duplicate.isNotEmpty) {
      throw ArgumentError('Ya existe una cuenta con ese nombre.');
    }
    final id = await db.insert('accounts', {
      'name': cleanName,
      'color': color,
      'archived': 0,
    });
    _notifyChanged();
    return id;
  }

  Future<void> updateAccount(
    int id, {
    String? name,
    int? color,
    int? archived,
  }) async {
    final db = await database;
    final changes = <String, Object?>{};
    if (archived == 1) {
      final selected = await db.query(
        'accounts',
        columns: ['archived'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final active = await db.query(
        'accounts',
        columns: ['id'],
        where: 'archived = 0',
      );
      if (selected.isNotEmpty &&
          selected.first['archived'] == 0 &&
          active.length <= 1) {
        throw StateError('Debe quedar al menos una cuenta activa.');
      }
    }
    if (name != null) {
      final cleanName = name.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (cleanName.isEmpty) {
        throw ArgumentError('Escribe un nombre para la cuenta.');
      }
      if (cleanName.length > 40) {
        throw ArgumentError('El nombre no puede superar los 40 caracteres.');
      }
      final duplicate = await db.query(
        'accounts',
        where: 'lower(name) = lower(?) AND id != ?',
        whereArgs: [cleanName, id],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw ArgumentError('Ya existe una cuenta con ese nombre.');
      }
      changes['name'] = cleanName;
    }
    if (color != null) changes['color'] = color;
    if (archived != null) changes['archived'] = archived;
    if (changes.isNotEmpty) {
      await db.update('accounts', changes, where: 'id = ?', whereArgs: [id]);
      _notifyChanged();
    }
  }

  Future<void> deleteAccount(int id) async {
    final db = await database;
    final movements = await db.query(
      'movements',
      columns: ['id'],
      where: 'account_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (movements.isNotEmpty) {
      throw StateError(
        'La cuenta tiene movimientos. Archívala si ya no la usas.',
      );
    }
    final active = await db.query(
      'accounts',
      columns: ['id'],
      where: 'archived = 0',
    );
    final selected = await db.query(
      'accounts',
      columns: ['archived'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (selected.isNotEmpty &&
        selected.first['archived'] == 0 &&
        active.length <= 1) {
      throw StateError('Debe quedar al menos una cuenta activa.');
    }
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    _notifyChanged();
  }

  Future<List<WorkMovement>> allMovements() async {
    final db = await database;
    final rows = await db.query('movements', orderBy: 'date, start_minute');
    return rows.map(WorkMovement.fromMap).toList();
  }

  Future<List<WorkMovement>> movementsBetween(
    DateTime from,
    DateTime through,
  ) async {
    final db = await database;
    final rows = await db.query(
      'movements',
      where: 'date BETWEEN ? AND ?',
      whereArgs: [dateKey(from), dateKey(through)],
      orderBy: 'date, start_minute',
    );
    return rows.map(WorkMovement.fromMap).toList();
  }

  Future<Map<String, DayKind>> dayKindsBetween(
    DateTime from,
    DateTime through,
  ) async {
    final db = await database;
    final rows = await db.query(
      'days',
      where: 'date BETWEEN ? AND ?',
      whereArgs: [dateKey(from), dateKey(through)],
    );
    return {
      for (final row in rows)
        row['date'] as String: DayKindLabel.parse(row['kind'] as String?),
    };
  }

  Future<void> saveDayNote(DateTime date, String note) async {
    final db = await database;
    final key = dateKey(date);
    final current = await db.query(
      'days',
      columns: ['kind'],
      where: 'date = ?',
      whereArgs: [key],
      limit: 1,
    );
    await db.insert('days', {
      'date': key,
      'kind': current.isEmpty ? 'work' : current.first['kind'] ?? 'work',
      'note': note.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyChanged();
  }

  Future<List<Map<String, Object?>>> attachmentsForDate(DateTime date) async {
    final db = await database;
    final rows = await db.query(
      'attachments',
      where: 'date = ?',
      whereArgs: [dateKey(date)],
      orderBy: 'created_at',
    );
    final store = await AttachmentStore.open();
    return rows.map((row) {
      final filePath = row['file_path'] as String?;
      final thumbnailPath = row['thumbnail_path'] as String?;
      return {
        ...row,
        'local_path': filePath == null ? null : store.resolve(filePath),
        'local_thumbnail_path': thumbnailPath == null
            ? null
            : store.resolve(thumbnailPath),
      };
    }).toList();
  }

  Future<Map<String, int>> attachmentCountsBetween(
    DateTime from,
    DateTime through,
  ) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT date, COUNT(*) AS count FROM attachments '
      'WHERE date BETWEEN ? AND ? GROUP BY date',
      [dateKey(from), dateKey(through)],
    );
    return {for (final row in rows) row['date'] as String: row['count'] as int};
  }

  Future<Map<String, String>> dayNotesBetween(
    DateTime from,
    DateTime through,
  ) async {
    final db = await database;
    final rows = await db.query(
      'days',
      columns: ['date', 'note'],
      where: 'date BETWEEN ? AND ?',
      whereArgs: [dateKey(from), dateKey(through)],
    );
    return {
      for (final row in rows)
        if ((row['note'] as String? ?? '').isNotEmpty)
          row['date'] as String: row['note'] as String,
    };
  }

  Future<int> addAttachment({
    required DateTime date,
    required String name,
    required String mime,
    required Stream<List<int>> bytes,
  }) async {
    final db = await database;
    final id = await db.insert('attachments', {
      'date': dateKey(date),
      'name': name,
      'mime': mime,
      'size': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'data': <int>[],
    });
    try {
      final store = await AttachmentStore.open();
      final stored = await store.importStream(
        id: id.toString(),
        name: name,
        mime: mime,
        bytes: bytes,
      );
      await db.update(
        'attachments',
        {
          'name': stored.name,
          'mime': stored.mime,
          'size': stored.size,
          'file_path': stored.filePath,
          'thumbnail_path': stored.thumbnailPath,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (_) {
      await db.delete('attachments', where: 'id = ?', whereArgs: [id]);
      rethrow;
    }
    _notifyChanged();
    return id;
  }

  Future<void> deleteAttachment(int id) async {
    final db = await database;
    final rows = await db.query(
      'attachments',
      columns: ['file_path', 'thumbnail_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    await db.delete('attachments', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final store = await AttachmentStore.open();
      await store.delete(
        rows.first['file_path'] as String?,
        rows.first['thumbnail_path'] as String?,
      );
    }
    _notifyChanged();
  }

  Future<void> restoreBackupData({
    required List<Map<String, Object?>> accounts,
    required List<Map<String, Object?>> movements,
    required List<Map<String, Object?>> days,
    required List<Map<String, Object?>> attachments,
    required List<int> targets,
    required Map<String, int> overrides,
    required int weekStart,
  }) async {
    final db = await database;
    final store = await AttachmentStore.open();
    final previousAttachments = await db.query(
      'attachments',
      columns: ['file_path', 'thumbnail_path'],
    );
    final stagedAttachments =
        <({Map<String, Object?> row, StoredAttachment file})>[];
    try {
      for (var index = 0; index < attachments.length; index++) {
        final attachment = attachments[index];
        final rawData = attachment['data'];
        final sourcePath = attachment['sourcePath'];
        final stored = sourcePath is String
            ? await store.importStream(
                id: 'restore-${const Uuid().v4()}',
                name: attachment['name'] as String,
                mime: attachment['mime'] as String,
                bytes: File(sourcePath).openRead(
                  attachment['sourceOffset'] as int,
                  (attachment['sourceOffset'] as int) +
                      (attachment['sourceLength'] as int),
                ),
                compressImage: false,
              )
            : await _restoreLegacyAttachment(store, attachment, rawData);
        stagedAttachments.add((row: attachment, file: stored));
      }
      await db.transaction((transaction) async {
        await transaction.delete('movements');
        await transaction.delete('attachments');
        await transaction.delete('days');
        await transaction.delete('accounts');

        final accountIds = <String, int>{};
        for (final account in accounts) {
          final oldId = account['id'].toString();
          final id = await transaction.insert('accounts', {
            'name': account['name'],
            'color': account['color'],
            'archived': account['archived'] ?? 0,
          });
          accountIds[oldId] = id;
        }
        if (accountIds.isEmpty) {
          final id = await transaction.insert('accounts', {
            'name': 'Trabajo',
            'color': 0xff3978f6,
            'archived': 0,
          });
          accountIds['Trabajo'] = id;
        }

        for (final movement in movements) {
          final accountId = accountIds[movement['accountId'].toString()];
          if (accountId == null) {
            throw StateError(
              'Un tramo hace referencia a una cuenta inexistente.',
            );
          }
          await transaction.insert('movements', {
            'date': movement['date'],
            'account_id': accountId,
            'start_minute': movement['startMin'],
            'end_minute': movement['endMin'],
            'break_minutes': movement['breakMin'],
            'crosses_midnight':
                movement['crossesMidnight'] == true ||
                    movement['crossesMidnight'] == 1
                ? 1
                : 0,
          });
        }

        for (final day in days) {
          await transaction.insert('days', {
            'date': day['date'],
            'kind': day['kind'] ?? 'work',
            'note': day['note'] ?? '',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final staged in stagedAttachments) {
          final attachment = staged.row;
          final date = attachment['date'] as String;
          await transaction.insert('days', {
            'date': date,
            'kind': 'work',
            'note': '',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          await transaction.insert('attachments', {
            'date': date,
            'name': staged.file.name,
            'mime': staged.file.mime,
            'size': staged.file.size,
            'created_at': attachment['createdAt'] ?? 0,
            'data': <int>[],
            'file_path': staged.file.filePath,
            'thumbnail_path': staged.file.thumbnailPath,
          });
        }

        final overrideString = overrides.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join(';');
        await transaction.insert('settings', {
          'id': 1,
          'daily_targets': targets.join(','),
          'date_overrides': overrideString,
          'week_start': weekStart,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });
      for (final previous in previousAttachments) {
        try {
          await store.delete(
            previous['file_path'] as String?,
            previous['thumbnail_path'] as String?,
          );
        } catch (_) {
          // The replacement is committed; stale old files can be cleaned up
          // later, but must not cause the newly restored files to be removed.
        }
      }
    } catch (_) {
      for (final staged in stagedAttachments) {
        await store.delete(staged.file.filePath, staged.file.thumbnailPath);
      }
      rethrow;
    }
    _notifyChanged();
  }

  Future<StoredAttachment> _restoreLegacyAttachment(
    AttachmentStore store,
    Map<String, Object?> attachment,
    Object? rawData,
  ) async {
    if (rawData is! List || rawData.isEmpty) {
      throw FormatException(
        'El adjunto ${attachment['name']} no contiene datos.',
      );
    }
    return store.importBytes(
      id: 'restore-${const Uuid().v4()}',
      name: attachment['name'] as String,
      mime: attachment['mime'] as String,
      bytes: rawData.cast<int>(),
      compressImage: false,
    );
  }

  Future<List<int>> dailyTargets() async {
    final db = await database;
    final row = await db.query('settings', where: 'id = 1', limit: 1);
    if (row.isEmpty) return [480, 480, 480, 480, 480, 0, 0];
    return (row.first['daily_targets'] as String)
        .split(',')
        .map(int.parse)
        .toList();
  }

  Future<void> saveDailyTargets(List<int> targets) async {
    if (targets.length != 7 ||
        targets.any((minutes) => minutes < 0 || minutes > 1440)) {
      throw ArgumentError('Cada objetivo debe estar entre 0 y 24 horas.');
    }
    final db = await database;
    await db.update('settings', {
      'daily_targets': targets.join(','),
    }, where: 'id = 1');
    _notifyChanged();
  }

  Future<int> weekStart() async {
    final db = await database;
    final rows = await db.query('settings', columns: ['week_start'], limit: 1);
    if (rows.isEmpty) return 1;
    final value = rows.first['week_start'] as int? ?? 1;
    return value >= 1 && value <= 7 ? value : 1;
  }

  Future<void> saveWeekStart(int weekday) async {
    if (weekday < 1 || weekday > 7) {
      throw ArgumentError('El inicio de semana no es válido.');
    }
    final db = await database;
    await db.update('settings', {'week_start': weekday}, where: 'id = 1');
    _notifyChanged();
  }

  Future<Map<String, int>> dateOverrides() async {
    final db = await database;
    final rows = await db.query('settings', columns: ['date_overrides']);
    if (rows.isEmpty) return {};
    final raw = rows.first['date_overrides'] as String? ?? '';
    if (raw.isEmpty) return {};
    return {
      for (final entry in raw.split(';'))
        if (entry.contains('='))
          entry.split('=')[0]: int.parse(entry.split('=')[1]),
    };
  }

  Future<void> saveDateOverride(DateTime date, int? minutes) async {
    final overrides = await dateOverrides();
    if (minutes == null) {
      overrides.remove(dateKey(date));
    } else {
      if (minutes < 0 || minutes > 1440) {
        throw ArgumentError('El objetivo debe estar entre 0 y 24 horas.');
      }
      overrides[dateKey(date)] = minutes;
    }
    final encoded = overrides.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(';');
    final db = await database;
    await db.update('settings', {'date_overrides': encoded}, where: 'id = 1');
    _notifyChanged();
  }

  Future<void> saveMovement(WorkMovement movement) async {
    final db = await database;
    final values = movement.toMap()..remove('id');
    if (movement.id == null) {
      await db.insert('movements', values);
    } else {
      await db.update(
        'movements',
        values,
        where: 'id = ?',
        whereArgs: [movement.id],
      );
    }
    _notifyChanged();
  }

  Future<void> deleteMovement(int id) async {
    final db = await database;
    await db.delete('movements', where: 'id = ?', whereArgs: [id]);
    _notifyChanged();
  }

  Future<void> saveDayKind(DateTime date, DayKind kind) async {
    final db = await database;
    await db.insert('days', {
      'date': dateKey(date),
      'kind': kind.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyChanged();
  }
}
