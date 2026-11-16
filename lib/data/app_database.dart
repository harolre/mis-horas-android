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
      version: 9,
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
            account_id INTEGER,
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
            week_start INTEGER NOT NULL DEFAULT 1,
            active_account_id INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE account_targets (
            account_id INTEGER PRIMARY KEY,
            daily_targets TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE medical_time (
            date TEXT NOT NULL,
            account_id INTEGER NOT NULL,
            minutes INTEGER NOT NULL,
            PRIMARY KEY (date, account_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE account_days (
            date TEXT NOT NULL,
            account_id INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'work',
            note TEXT NOT NULL DEFAULT '',
            target_override INTEGER,
            PRIMARY KEY (date, account_id)
          )
        ''');
        final accountId = await db.insert('accounts', {
          'name': 'Trabajo',
          'color': 0xff3978f6,
          'archived': 0,
        });
        await db.insert('account_targets', {
          'account_id': accountId,
          'daily_targets': '480,480,480,480,480,0,0',
        });
        await db.insert('settings', {
          'id': 1,
          'daily_targets': '480,480,480,480,480,0,0',
          'date_overrides': '',
          'week_start': 1,
          'active_account_id': accountId,
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
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE account_targets (
              account_id INTEGER PRIMARY KEY,
              daily_targets TEXT NOT NULL
            )
          ''');
          await db.execute(
            'ALTER TABLE settings ADD COLUMN active_account_id INTEGER',
          );
          final accounts = await db.query(
            'accounts',
            columns: ['id', 'archived'],
            orderBy: 'id',
          );
          final activeAccounts = accounts.where(
            (account) => account['archived'] == 0,
          );
          final legacyAccount = activeAccounts.where(
            (account) => (account['name'] as String).toLowerCase() == 'trabajo',
          );
          final activeId = legacyAccount.isNotEmpty
              ? legacyAccount.first['id'] as int
              : activeAccounts.isEmpty
              ? null
              : activeAccounts.first['id'] as int;
          final settings = await db.query(
            'settings',
            columns: ['daily_targets'],
            where: 'id = 1',
            limit: 1,
          );
          const emptyTargets = '0,0,0,0,0,0,0';
          final legacyTargets = settings.isEmpty
              ? '480,480,480,480,480,0,0'
              : settings.first['daily_targets'] as String;
          for (final account in accounts) {
            await db.insert('account_targets', {
              'account_id': account['id'],
              'daily_targets': account['id'] == activeId
                  ? legacyTargets
                  : emptyTargets,
            });
          }
          if (activeId != null) {
            await db.update('settings', {
              'active_account_id': activeId,
            }, where: 'id = 1');
          }
        }
        if (oldVersion < 7) {
          await db.execute(
            'ALTER TABLE attachments ADD COLUMN account_id INTEGER',
          );
          final accounts = await db.query(
            'accounts',
            columns: ['id'],
            where: "lower(name) = 'trabajo'",
            orderBy: 'archived, id',
            limit: 1,
          );
          final fallbackAccountId = accounts.isNotEmpty
              ? accounts.first['id'] as int
              : (await db.query(
                      'accounts',
                      columns: ['id'],
                      where: 'archived = 0',
                      orderBy: 'id',
                      limit: 1,
                    )).firstOrNull?['id']
                    as int?;
          final attachments = await db.query(
            'attachments',
            columns: ['id', 'date'],
            orderBy: 'id',
          );
          for (final attachment in attachments) {
            final movements = await db.query(
              'movements',
              columns: ['account_id'],
              where: 'date = ?',
              whereArgs: [attachment['date']],
            );
            final owners = movements
                .map((movement) => movement['account_id'] as int)
                .toSet();
            final accountId = owners.length == 1
                ? owners.first
                : fallbackAccountId;
            if (accountId != null) {
              await db.update(
                'attachments',
                {'account_id': accountId},
                where: 'id = ?',
                whereArgs: [attachment['id']],
              );
            }
          }
        }
        if (oldVersion < 8) {
          await db.execute('''
            CREATE TABLE medical_time (
              date TEXT NOT NULL,
              account_id INTEGER NOT NULL,
              minutes INTEGER NOT NULL,
              PRIMARY KEY (date, account_id)
            )
          ''');
        }
        if (oldVersion < 9) {
          await db.execute('''
            CREATE TABLE account_days (
              date TEXT NOT NULL,
              account_id INTEGER NOT NULL,
              kind TEXT NOT NULL DEFAULT 'work',
              note TEXT NOT NULL DEFAULT '',
              target_override INTEGER,
              PRIMARY KEY (date, account_id)
            )
          ''');
          final accounts = await db.query(
            'accounts',
            columns: ['id', 'name'],
            orderBy: 'id',
          );
          final settings = await db.query(
            'settings',
            columns: ['active_account_id', 'date_overrides'],
            where: 'id = 1',
            limit: 1,
          );
          final activeId = settings.isEmpty
              ? null
              : settings.first['active_account_id'] as int?;
          final legacyAccount = accounts.where(
            (account) => (account['name'] as String).toLowerCase() == 'trabajo',
          );
          final legacyAccountId = legacyAccount.isNotEmpty
              ? legacyAccount.first['id'] as int
              : activeId ??
                    (accounts.isEmpty ? null : accounts.first['id'] as int);
          if (legacyAccountId != null) {
            final days = await db.query('days', orderBy: 'date');
            for (final day in days) {
              await db.insert('account_days', {
                'date': day['date'],
                'account_id': legacyAccountId,
                'kind': day['kind'] ?? 'work',
                'note': day['note'] ?? '',
              }, conflictAlgorithm: ConflictAlgorithm.replace);
            }
            final rawOverrides = settings.isEmpty
                ? ''
                : settings.first['date_overrides'] as String? ?? '';
            for (final entry in rawOverrides.split(';')) {
              final pair = entry.split('=');
              if (pair.length != 2) continue;
              final minutes = int.tryParse(pair[1]);
              if (minutes == null || minutes < 0 || minutes > 1440) continue;
              final current = await db.query(
                'account_days',
                where: 'date = ? AND account_id = ?',
                whereArgs: [pair[0], legacyAccountId],
                limit: 1,
              );
              if (current.isEmpty) {
                await db.insert('account_days', {
                  'date': pair[0],
                  'account_id': legacyAccountId,
                  'kind': 'work',
                  'note': '',
                  'target_override': minutes,
                });
              } else {
                await db.update(
                  'account_days',
                  {'target_override': minutes},
                  where: 'date = ? AND account_id = ?',
                  whereArgs: [pair[0], legacyAccountId],
                );
              }
            }
          }
          await db.update('settings', {'date_overrides': ''}, where: 'id = 1');
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

  Future<int> activeAccountId() async {
    final db = await database;
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'archived = 0',
      orderBy: 'id',
    );
    if (rows.isEmpty) {
      throw StateError('Debe quedar al menos una cuenta activa.');
    }
    final settings = await db.query(
      'settings',
      columns: ['active_account_id'],
      where: 'id = 1',
      limit: 1,
    );
    final selectedId = settings.isEmpty
        ? null
        : settings.first['active_account_id'] as int?;
    if (selectedId != null &&
        rows.any((account) => account['id'] == selectedId)) {
      return selectedId;
    }
    final fallbackId = rows.first['id'] as int;
    await db.update('settings', {
      'active_account_id': fallbackId,
    }, where: 'id = 1');
    return fallbackId;
  }

  Future<void> setActiveAccount(int accountId) async {
    final db = await database;
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: 'id = ? AND archived = 0',
      whereArgs: [accountId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('La cuenta seleccionada no está activa.');
    }
    final targets = await db.query(
      'account_targets',
      columns: ['daily_targets'],
      where: 'account_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    final changes = <String, Object?>{'active_account_id': accountId};
    if (targets.isNotEmpty) {
      changes['daily_targets'] = targets.first['daily_targets'];
    }
    await db.update('settings', changes, where: 'id = 1');
    _notifyChanged();
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
    await db.insert('account_targets', {
      'account_id': id,
      'daily_targets': '0,0,0,0,0,0,0',
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
    final activeId = await activeAccountId();
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
      if (archived == 1 && activeId == id) {
        final next = await db.query(
          'accounts',
          columns: ['id'],
          where: 'archived = 0',
          orderBy: 'id',
          limit: 1,
        );
        if (next.isNotEmpty) {
          await db.update('settings', {
            'active_account_id': next.first['id'],
          }, where: 'id = 1');
        }
      }
      _notifyChanged();
    }
  }

  Future<void> deleteAccount(int id) async {
    final db = await database;
    final activeId = await activeAccountId();
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
    final medicalRecords = await db.query(
      'medical_time',
      columns: ['date'],
      where: 'account_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (medicalRecords.isNotEmpty) {
      throw StateError(
        'La cuenta tiene registros médicos. Archívala si ya no la usas.',
      );
    }
    final attachments = await db.query(
      'attachments',
      columns: ['id'],
      where: 'account_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (attachments.isNotEmpty) {
      throw StateError('La cuenta tiene adjuntos. Archívala si ya no la usas.');
    }
    final accountDays = await db.query(
      'account_days',
      columns: ['date'],
      where: "account_id = ? AND (kind != 'work' OR note != '' OR target_override IS NOT NULL)",
      whereArgs: [id],
      limit: 1,
    );
    if (accountDays.isNotEmpty) {
      throw StateError(
        'La cuenta tiene estados, notas u objetivos por fecha. Archívala si ya no la usas.',
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
    if (activeId == id) {
      final next = await db.query(
        'accounts',
        columns: ['id'],
        where: 'archived = 0 AND id != ?',
        whereArgs: [id],
        orderBy: 'id',
        limit: 1,
      );
      if (next.isNotEmpty) {
        await db.update('settings', {
          'active_account_id': next.first['id'],
        }, where: 'id = 1');
      }
    }
    await db.delete(
      'account_targets',
      where: 'account_id = ?',
      whereArgs: [id],
    );
    await db.delete('account_days', where: 'account_id = ?', whereArgs: [id]);
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    _notifyChanged();
  }

  Future<List<WorkMovement>> allMovements() async {
    final db = await database;
    final rows = await db.query('movements', orderBy: 'date, start_minute');
    return rows.map(WorkMovement.fromMap).toList();
  }

  Future<Map<int, int>> workedMinutesByAccount() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT account_id,
        SUM(end_minute - start_minute
          + CASE WHEN crosses_midnight = 1 THEN 1440 ELSE 0 END
          - break_minutes) AS worked_minutes
      FROM movements
      GROUP BY account_id
    ''');
    return {
      for (final row in rows)
        row['account_id'] as int: (row['worked_minutes'] as num).toInt(),
    };
  }

  Future<Map<String, int>> medicalMinutesBetween(
    DateTime from,
    DateTime through, {
    int? accountId,
  }) async {
    final db = await database;
    final rows = accountId == null
        ? await db.rawQuery(
            'SELECT date, SUM(minutes) AS minutes FROM medical_time '
            'WHERE date BETWEEN ? AND ? GROUP BY date',
            [dateKey(from), dateKey(through)],
          )
        : await db.query(
            'medical_time',
            columns: ['date', 'minutes'],
            where: 'date BETWEEN ? AND ? AND account_id = ?',
            whereArgs: [dateKey(from), dateKey(through), accountId],
          );
    return {
      for (final row in rows) row['date'] as String: row['minutes'] as int,
    };
  }

  Future<void> saveMedicalMinutes({
    required DateTime date,
    required int accountId,
    required int minutes,
  }) async {
    if (minutes < 0 || minutes > 1440) {
      throw ArgumentError('El tiempo médico debe estar entre 0 y 24 horas.');
    }
    final db = await database;
    final account = await db.query(
      'accounts',
      columns: ['id'],
      where: 'id = ? AND archived = 0',
      whereArgs: [accountId],
      limit: 1,
    );
    if (account.isEmpty) {
      throw StateError('La cuenta seleccionada ya no está activa.');
    }
    final key = dateKey(date);
    if (minutes == 0) {
      await db.delete(
        'medical_time',
        where: 'date = ? AND account_id = ?',
        whereArgs: [key, accountId],
      );
    } else {
      await db.insert('medical_time', {
        'date': key,
        'account_id': accountId,
        'minutes': minutes,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    _notifyChanged();
  }

  Future<List<WorkMovement>> movementsBetween(
    DateTime from,
    DateTime through, {
    int? accountId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'movements',
      where: accountId == null
          ? 'date BETWEEN ? AND ?'
          : 'date BETWEEN ? AND ? AND account_id = ?',
      whereArgs: accountId == null
          ? [dateKey(from), dateKey(through)]
          : [dateKey(from), dateKey(through), accountId],
      orderBy: 'date, start_minute',
    );
    return rows.map(WorkMovement.fromMap).toList();
  }

  Future<Map<String, DayKind>> dayKindsBetween(
    DateTime from,
    DateTime through, {
    required int accountId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'account_days',
      columns: ['date', 'kind'],
      where: 'date BETWEEN ? AND ? AND account_id = ?',
      whereArgs: [dateKey(from), dateKey(through), accountId],
    );
    return {
      for (final row in rows)
        row['date'] as String: DayKindLabel.parse(row['kind'] as String?),
    };
  }

  Future<void> saveDayNote(
    DateTime date,
    String note, {
    required int accountId,
  }) async {
    final db = await database;
    final key = dateKey(date);
    final current = await db.query(
      'account_days',
      where: 'date = ? AND account_id = ?',
      whereArgs: [key, accountId],
      limit: 1,
    );
    await db.insert('account_days', {
      'date': key,
      'account_id': accountId,
      'kind': current.isEmpty ? 'work' : current.first['kind'] ?? 'work',
      'note': note.trim(),
      'target_override': current.isEmpty
          ? null
          : current.first['target_override'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyChanged();
  }

  Future<List<Map<String, Object?>>> attachmentsForDate(
    DateTime date, {
    required int accountId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'attachments',
      where: 'date = ? AND account_id = ?',
      whereArgs: [dateKey(date), accountId],
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
    DateTime through, {
    int? accountId,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT date, COUNT(*) AS count FROM attachments WHERE date BETWEEN ? AND ? '
      '${accountId == null ? '' : 'AND account_id = ? '}GROUP BY date',
      accountId == null
          ? [dateKey(from), dateKey(through)]
          : [dateKey(from), dateKey(through), accountId],
    );
    return {for (final row in rows) row['date'] as String: row['count'] as int};
  }

  Future<Map<String, String>> dayNotesBetween(
    DateTime from,
    DateTime through, {
    required int accountId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'account_days',
      columns: ['date', 'note'],
      where: 'date BETWEEN ? AND ? AND account_id = ?',
      whereArgs: [dateKey(from), dateKey(through), accountId],
    );
    return {
      for (final row in rows)
        if ((row['note'] as String? ?? '').isNotEmpty)
          row['date'] as String: row['note'] as String,
    };
  }

  Future<int> addAttachment({
    required DateTime date,
    required int accountId,
    required String name,
    required String mime,
    required Stream<List<int>> bytes,
  }) async {
    final db = await database;
    final id = await db.insert('attachments', {
      'date': dateKey(date),
      'account_id': accountId,
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
    Map<String, List<int>> accountTargets = const {},
    List<Map<String, Object?>> medicalTime = const [],
    String? activeAccountId,
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
        await transaction.delete('account_days');
        await transaction.delete('medical_time');
        await transaction.delete('account_targets');
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
        final legacyAccountKey =
            accounts
                .where(
                  (account) =>
                      (account['name'] as String).toLowerCase() == 'trabajo',
                )
                .map((account) => account['id'].toString())
                .firstOrNull ??
            activeAccountId ??
            accountIds.keys.first;
        final legacyAccountId =
            accountIds[legacyAccountKey] ?? accountIds.values.first;
        for (final entry in accountIds.entries) {
          final accountSchedule =
              accountTargets[entry.key] ??
              (entry.key == accountIds.keys.first
                  ? targets
                  : const <int>[0, 0, 0, 0, 0, 0, 0]);
          await transaction.insert('account_targets', {
            'account_id': entry.value,
            'daily_targets': accountSchedule.join(','),
          });
        }
        for (final entry in medicalTime) {
          final accountId = accountIds[entry['accountId']?.toString()];
          if (accountId == null) {
            throw StateError(
              'Un registro médico hace referencia a una cuenta inexistente.',
            );
          }
          await transaction.insert('medical_time', {
            'date': entry['date'],
            'account_id': accountId,
            'minutes': entry['minutes'],
          });
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
          final accountId =
              accountIds[day['accountId']?.toString()] ?? legacyAccountId;
          final date = day['date'] as String;
          final kind = day['kind'] ?? 'work';
          final note = day['note'] ?? '';
          final targetOverride = day['targetOverride'];
          await transaction.insert('account_days', {
            'date': date,
            'account_id': accountId,
            'kind': kind,
            'note': note,
            'target_override': targetOverride,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await transaction.insert('days', {
            'date': date,
            'kind': kind,
            'note': note,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final entry in overrides.entries) {
          final current = await transaction.query(
            'account_days',
            where: 'date = ? AND account_id = ?',
            whereArgs: [entry.key, legacyAccountId],
            limit: 1,
          );
          await transaction.insert('account_days', {
            'date': entry.key,
            'account_id': legacyAccountId,
            'kind': current.isEmpty ? 'work' : current.first['kind'] ?? 'work',
            'note': current.isEmpty ? '' : current.first['note'] ?? '',
            'target_override': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final staged in stagedAttachments) {
          final attachment = staged.row;
          final date = attachment['date'] as String;
          final accountId =
              accountIds[attachment['accountId']?.toString()] ??
              accountIds.values.first;
          await transaction.insert('days', {
            'date': date,
            'kind': 'work',
            'note': '',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          await transaction.insert('attachments', {
            'date': date,
            'account_id': accountId,
            'name': staged.file.name,
            'mime': staged.file.mime,
            'size': staged.file.size,
            'created_at': attachment['createdAt'] ?? 0,
            'data': <int>[],
            'file_path': staged.file.filePath,
            'thumbnail_path': staged.file.thumbnailPath,
          });
        }

        await transaction.insert('settings', {
          'id': 1,
          'daily_targets': targets.join(','),
          'date_overrides': '',
          'week_start': weekStart,
          'active_account_id':
              accountIds[activeAccountId] ?? accountIds.values.first,
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

  Future<List<int>> dailyTargets({int? accountId}) async {
    final db = await database;
    final selectedId = accountId ?? await activeAccountId();
    final accountRows = await db.query(
      'account_targets',
      columns: ['daily_targets'],
      where: 'account_id = ?',
      whereArgs: [selectedId],
      limit: 1,
    );
    final legacyRows = accountRows.isEmpty
        ? await db.query(
            'settings',
            columns: ['daily_targets'],
            where: 'id = 1',
            limit: 1,
          )
        : accountRows;
    if (legacyRows.isEmpty) return [480, 480, 480, 480, 480, 0, 0];
    return (legacyRows.first['daily_targets'] as String)
        .split(',')
        .map(int.parse)
        .toList();
  }

  Future<Map<int, List<int>>> allAccountTargets({
    bool activeOnly = false,
  }) async {
    final db = await database;
    final accounts = await db.query(
      'accounts',
      columns: ['id'],
      where: activeOnly ? 'archived = 0' : null,
      orderBy: 'id',
    );
    final rows = await db.query('account_targets');
    final targetsById = {
      for (final row in rows)
        row['account_id'] as int: (row['daily_targets'] as String)
            .split(',')
            .map(int.parse)
            .toList(),
    };
    final legacy = await db.query(
      'settings',
      columns: ['daily_targets'],
      where: 'id = 1',
      limit: 1,
    );
    final fallback = legacy.isEmpty
        ? <int>[480, 480, 480, 480, 480, 0, 0]
        : (legacy.first['daily_targets'] as String)
              .split(',')
              .map(int.parse)
              .toList();
    return {
      for (var index = 0; index < accounts.length; index++)
        accounts[index]['id'] as int:
            targetsById[accounts[index]['id']] ??
            (index == 0 ? fallback : <int>[0, 0, 0, 0, 0, 0, 0]),
    };
  }

  Future<void> saveDailyTargets(List<int> targets, {int? accountId}) async {
    if (targets.length != 7 ||
        targets.any((minutes) => minutes < 0 || minutes > 1440)) {
      throw ArgumentError('Cada objetivo debe estar entre 0 y 24 horas.');
    }
    final db = await database;
    final selectedId = accountId ?? await activeAccountId();
    final account = await db.query(
      'accounts',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [selectedId],
      limit: 1,
    );
    if (account.isEmpty) throw StateError('La cuenta ya no existe.');
    final encoded = targets.join(',');
    await db.insert('account_targets', {
      'account_id': selectedId,
      'daily_targets': encoded,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (selectedId == await activeAccountId()) {
      await db.update('settings', {'daily_targets': encoded}, where: 'id = 1');
    }
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

  Future<Map<String, int>> dateOverrides({required int accountId}) async {
    final db = await database;
    final rows = await db.query(
      'account_days',
      columns: ['date', 'target_override'],
      where: 'account_id = ? AND target_override IS NOT NULL',
      whereArgs: [accountId],
    );
    return {
      for (final row in rows)
        row['date'] as String: row['target_override'] as int,
    };
  }

  Future<void> saveDateOverride(
    DateTime date,
    int? minutes, {
    required int accountId,
  }) async {
    if (minutes != null && (minutes < 0 || minutes > 1440)) {
      throw ArgumentError('El objetivo debe estar entre 0 y 24 horas.');
    }
    final db = await database;
    final key = dateKey(date);
    final current = await db.query(
      'account_days',
      where: 'date = ? AND account_id = ?',
      whereArgs: [key, accountId],
      limit: 1,
    );
    if (minutes == null && current.isEmpty) return;
    await db.insert('account_days', {
      'date': key,
      'account_id': accountId,
      'kind': current.isEmpty ? 'work' : current.first['kind'] ?? 'work',
      'note': current.isEmpty ? '' : current.first['note'] ?? '',
      'target_override': minutes,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> saveDayKind(
    DateTime date,
    DayKind kind, {
    required int accountId,
  }) async {
    final db = await database;
    final key = dateKey(date);
    final current = await db.query(
      'account_days',
      where: 'date = ? AND account_id = ?',
      whereArgs: [key, accountId],
      limit: 1,
    );
    await db.insert('account_days', {
      'date': key,
      'account_id': accountId,
      'kind': kind.name,
      'note': current.isEmpty ? '' : current.first['note'] ?? '',
      'target_override': current.isEmpty
          ? null
          : current.first['target_override'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyChanged();
  }
}
