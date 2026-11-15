import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/work_time.dart';
import 'app_database.dart';
import 'attachment_store.dart';

const _magicV2 = 'MHBK2';
const _format = 'mis-horas-backup';
const _version = 2;
const _chunkSize = 4 * 1024 * 1024;
const _iterations = 600000;
const _maxChunkCount = 1 << 20;
const _maxMetadataSize = 128 * 1024 * 1024;
final _jsonEncoder = JsonUtf8Encoder();

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

int _readU32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);

Uint8List _secureRandom(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List _iv(Uint8List prefix, int index) =>
    Uint8List.fromList([...prefix, ..._u32(index)]);

Uint8List _aad(String magic, int index, int count) =>
    utf8.encode('$magic|$index|$count');

String _b64(List<int> bytes) => base64Encode(bytes);

Uint8List _fromB64(Object? value, String field) {
  if (value is! String) throw FormatException('Falta el dato cifrado: $field.');
  try {
    return Uint8List.fromList(base64Decode(value));
  } catch (_) {
    throw const FormatException('La cabecera cifrada está dañada.');
  }
}

class _FilePart {
  const _FilePart({required this.path, required this.length, this.bytes});

  final String? path;
  final int length;
  final List<int>? bytes;

  Stream<List<int>> open() =>
      path != null ? File(path!).openRead() : Stream.value(bytes!);
}

/// Streaming, encrypted backup format for the native Android/iOS apps.
class MobileBackupService {
  MobileBackupService._();

  static final instance = MobileBackupService._();
  final _cipher = AesGcm.with256bits();
  final _database = AppDatabase.instance;

  /// Writes the backup directly to a private temporary file. Attachment
  /// contents are read and encrypted one bounded block at a time.
  Future<File> createBackupFile(String password) async {
    _validatePassword(password);
    final snapshot = await _snapshot();
    final metadataBytes = _jsonEncoder.convert(snapshot.metadata);
    final prefix = Uint8List.fromList([
      ..._u32(metadataBytes.length),
      ...metadataBytes,
    ]);
    final plainSize =
        prefix.length +
        snapshot.parts.fold<int>(0, (sum, part) => sum + part.length);
    final chunkCount = max(1, (plainSize + _chunkSize - 1) ~/ _chunkSize);
    if (chunkCount > _maxChunkCount) {
      throw StateError('La copia supera el tamaño máximo admitido.');
    }

    final salt = _secureRandom(16);
    final ivPrefix = _secureRandom(8);
    final key = await _deriveKey(password, salt);
    final createdAt = snapshot.metadata['createdAt'];
    final header = _jsonEncoder.convert({
      'format': _format,
      'version': _version,
      'createdAt': createdAt,
      'kdf': {
        'name': 'PBKDF2',
        'hash': 'SHA-256',
        'iterations': _iterations,
        'salt': _b64(salt),
      },
      'cipher': {
        'name': 'AES-GCM',
        'ivPrefix': _b64(ivPrefix),
        'chunkSize': _chunkSize,
        'chunkCount': chunkCount,
        'plainSize': plainSize,
      },
    });
    final directory = await getTemporaryDirectory();
    final output = File(
      p.join(
        directory.path,
        'mis-horas-${DateTime.now().microsecondsSinceEpoch}.mhbackup',
      ),
    );
    final sink = output.openWrite();
    try {
      sink
        ..add(utf8.encode(_magicV2))
        ..add(_u32(header.length))
        ..add(header);
      var index = 0;
      await for (final chunk in _plainChunks(prefix, snapshot.parts)) {
        final box = await _cipher.encrypt(
          chunk,
          secretKey: key,
          nonce: _iv(ivPrefix, index),
          aad: _aad(_magicV2, index, chunkCount),
        );
        sink
          ..add(_u32(box.cipherText.length + box.mac.bytes.length))
          ..add(box.cipherText)
          ..add(box.mac.bytes);
        index++;
      }
      await sink.flush();
      await sink.close();
      if (index != chunkCount || await output.length() == 0) {
        throw StateError('No se pudo completar la copia cifrada.');
      }
    } catch (_) {
      await sink.close();
      await output.delete();
      rethrow;
    }
    return output;
  }

  Future<({Map<String, Object?> metadata, List<_FilePart> parts})>
  _snapshot() async {
    final db = await _database.database;
    final results = await Future.wait<List<Map<String, Object?>>>([
      db.query('accounts', orderBy: 'id'),
      db.query('movements', orderBy: 'date, start_minute'),
      db.query('days', orderBy: 'date'),
      db.query('settings', where: 'id = 1', limit: 1),
      db.query('attachments', orderBy: 'created_at'),
    ]);
    final accountRows = results[0];
    final movementRows = results[1];
    final dayRows = results[2];
    final settings = results[3].isEmpty ? null : results[3].first;
    final attachmentRows = results[4];
    final accountIds = <int, String>{
      for (final row in accountRows)
        row['id'] as int: 'mobile-account-${row['id']}',
    };
    final accounts = accountRows
        .map(
          (row) => {
            'id': accountIds[row['id'] as int],
            'name': row['name'],
            'color':
                '#${((row['color'] as int) & 0x00ffffff).toRadixString(16).padLeft(6, '0')}',
            'archived': row['archived'] ?? 0,
            'createdAt': 0,
            'updatedAt': 0,
          },
        )
        .toList();
    final movements = movementRows
        .map(
          (row) => {
            'id': 'mobile-movement-${row['id']}',
            'accountId': accountIds[row['account_id'] as int],
            'date': row['date'],
            'startMin': row['start_minute'],
            'endMin': row['end_minute'],
            'breakMin': row['break_minutes'],
            'crossesMidnight': row['crosses_midnight'],
            'createdAt': 0,
            'updatedAt': 0,
          },
        )
        .toList();
    final days = dayRows
        .map(
          (row) => {
            'date': row['date'],
            'kind': row['kind'],
            'note': row['note'],
            'attachmentCount': 0,
            'updatedAt': 0,
          },
        )
        .toList();
    final store = await AttachmentStore.open();
    final parts = <_FilePart>[];
    final attachments = <Map<String, Object?>>[];
    var offset = 0;
    for (final row in attachmentRows) {
      final path = row['file_path'] as String?;
      final legacyBytes = (row['data'] as List?)?.cast<int>();
      final part = path != null
          ? _FilePart(
              path: store.resolve(path),
              length: await File(store.resolve(path)).length(),
            )
          : _FilePart(
              path: null,
              bytes: legacyBytes,
              length: legacyBytes?.length ?? 0,
            );
      if (part.length <= 0) {
        throw StateError('No se encuentra el adjunto ${row['name']}.');
      }
      attachments.add({
        'id': 'mobile-attachment-${row['id']}',
        'date': row['date'],
        'name': row['name'],
        'mime': row['mime'],
        'size': part.length,
        'createdAt': row['created_at'],
        'offset': offset,
        'length': part.length,
        'thumbOffset': null,
        'thumbLength': null,
      });
      parts.add(part);
      offset += part.length;
    }
    final counts = <String, int>{};
    for (final attachment in attachments) {
      final date = attachment['date'] as String;
      counts[date] = (counts[date] ?? 0) + 1;
    }
    for (final day in days) {
      day['attachmentCount'] = counts[day['date']] ?? 0;
    }
    final targets =
        (settings?['daily_targets'] as String? ?? '480,480,480,480,480,0,0')
            .split(',')
            .map(int.parse)
            .toList();
    final overrides = <String, int>{};
    for (final entry in (settings?['date_overrides'] as String? ?? '').split(
      ';',
    )) {
      final pair = entry.split('=');
      if (pair.length == 2) {
        final value = int.tryParse(pair[1]);
        if (value != null) overrides[pair[0]] = value;
      }
    }
    final createdAt = DateTime.now().toUtc().toIso8601String();
    return (
      parts: parts,
      metadata: {
        'format': _format,
        'version': _version,
        'createdAt': createdAt,
        'appVersion': '1.0.0',
        'accounts': accounts,
        'movements': movements,
        'days': days,
        'settings': {
          'id': 'app',
          'weekStart': settings?['week_start'] ?? 1,
          'dailyTargets': targets,
          'dateOverrides': overrides,
          'updatedAt': 0,
        },
        'attachments': attachments,
      },
    );
  }

  Stream<List<int>> _plainChunks(
    List<int> prefix,
    List<_FilePart> parts,
  ) async* {
    var buffer = Uint8List(_chunkSize);
    var used = 0;
    await for (final data in _plaintextPieces(prefix, parts)) {
      var offset = 0;
      while (offset < data.length) {
        final amount = min(_chunkSize - used, data.length - offset);
        buffer.setRange(used, used + amount, data, offset);
        used += amount;
        offset += amount;
        if (used == _chunkSize) {
          yield buffer;
          buffer = Uint8List(_chunkSize);
          used = 0;
        }
      }
    }
    if (used > 0) yield Uint8List.sublistView(buffer, 0, used);
  }

  Stream<List<int>> _plaintextPieces(
    List<int> prefix,
    List<_FilePart> parts,
  ) async* {
    yield prefix;
    for (final part in parts) {
      yield* part.open();
    }
  }

  Future<void> restoreFromFile(File source, String password) async {
    if (password.isEmpty) {
      throw ArgumentError('Introduce la contraseña de la copia.');
    }
    if (!await source.exists() || await source.length() < 9) {
      throw const FormatException('El archivo de copia no es válido.');
    }
    final input = await source.open();
    var inputClosed = false;
    try {
      final magicBytes = await _readExact(input, 5);
      final magic = utf8.decode(magicBytes, allowMalformed: true);
      if (magic != _magicV2) {
        throw const FormatException(
          'Formato de copia no compatible. Solo se admiten copias MHBK2.',
        );
      }
      final headerLength = _readU32(await _readExact(input, 4), 0);
      if (headerLength == 0 || headerLength > 1024 * 1024) {
        throw const FormatException('La cabecera de la copia está dañada.');
      }
      final header = jsonDecode(
        utf8.decode(await _readExact(input, headerLength)),
      );
      if (header is! Map<String, dynamic> ||
          header['format'] != _format ||
          header['version'] != _version) {
        throw const FormatException('La versión de la copia no es compatible.');
      }
      final kdf = header['kdf'];
      final cipher = header['cipher'];
      if (kdf is! Map<String, dynamic> ||
          cipher is! Map<String, dynamic> ||
          kdf['name'] != 'PBKDF2' ||
          kdf['hash'] != 'SHA-256' ||
          cipher['name'] != 'AES-GCM') {
        throw const FormatException('El cifrado de la copia no es válido.');
      }
      final iterations = (kdf['iterations'] as num?)?.toInt() ?? 0;
      final chunkSize = (cipher['chunkSize'] as num?)?.toInt() ?? 0;
      final chunkCount = (cipher['chunkCount'] as num?)?.toInt() ?? 0;
      final plainSize = (cipher['plainSize'] as num?)?.toInt() ?? -1;
      if (iterations < 1000 ||
          iterations > 2000000 ||
          chunkSize != _chunkSize ||
          chunkCount < 1 ||
          chunkCount > _maxChunkCount ||
          plainSize < 4 ||
          chunkCount != max(1, (plainSize + chunkSize - 1) ~/ chunkSize)) {
        throw const FormatException('La estructura de bloques no es válida.');
      }
      final salt = _fromB64(kdf['salt'], 'salt');
      final ivPrefix = _fromB64(cipher['ivPrefix'], 'ivPrefix');
      if (salt.length != 16 || ivPrefix.length != 8) {
        throw const FormatException('La cabecera cifrada está dañada.');
      }
      final key = await _deriveKey(password, salt, iterations: iterations);
      final temp = File(
        p.join(
          (await getTemporaryDirectory()).path,
          'restore-${DateTime.now().microsecondsSinceEpoch}.plain',
        ),
      );
      final sink = temp.openWrite();
      try {
        for (var index = 0; index < chunkCount; index++) {
          final encryptedLength = _readU32(await _readExact(input, 4), 0);
          final expectedPlainLength = min(
            chunkSize,
            plainSize - index * chunkSize,
          );
          if (encryptedLength != expectedPlainLength + 16) {
            throw const FormatException('Un bloque de la copia no es válido.');
          }
          final encrypted = await _readExact(input, encryptedLength);
          try {
            final plain = await _cipher.decrypt(
              SecretBox(
                encrypted.sublist(0, encrypted.length - 16),
                nonce: _iv(ivPrefix, index),
                mac: Mac(encrypted.sublist(encrypted.length - 16)),
              ),
              secretKey: key,
              aad: _aad(_magicV2, index, chunkCount),
            );
            sink.add(plain);
          } on SecretBoxAuthenticationError {
            throw const FormatException(
              'Contraseña incorrecta o copia alterada.',
            );
          }
        }
        await sink.flush();
        await sink.close();
        if (await input.position() != await source.length()) {
          throw const FormatException('La copia contiene datos sobrantes.');
        }
        if (await temp.length() != plainSize) {
          throw const FormatException(
            'El contenido descifrado está incompleto.',
          );
        }
        await _restorePlainFile(temp);
      } catch (_) {
        await sink.close();
        rethrow;
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } finally {
      if (!inputClosed) await input.close();
    }
  }

  Future<void> _restorePlainFile(File plaintextFile) async {
    final handle = await plaintextFile.open();
    try {
      final plainSize = await handle.length();
      if (plainSize < 4) {
        throw const FormatException('La copia está incompleta.');
      }
      final metadataLength = _readU32(await _readExact(handle, 4), 0);
      if (metadataLength == 0 ||
          metadataLength > _maxMetadataSize ||
          4 + metadataLength > plainSize) {
        throw const FormatException(
          'Los metadatos de la copia no son válidos.',
        );
      }
      final rawMetadata = jsonDecode(
        utf8.decode(await _readExact(handle, metadataLength)),
      );
      if (rawMetadata is! Map<String, dynamic> ||
          rawMetadata['format'] != _format ||
          rawMetadata['version'] != _version ||
          rawMetadata['accounts'] is! List ||
          rawMetadata['movements'] is! List ||
          rawMetadata['days'] is! List ||
          rawMetadata['attachments'] is! List ||
          rawMetadata['settings'] is! Map<String, dynamic>) {
        throw const FormatException(
          'Los datos de la copia no tienen un formato válido.',
        );
      }
      final accounts = (rawMetadata['accounts'] as List)
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      final movements = (rawMetadata['movements'] as List)
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      final days = (rawMetadata['days'] as List)
          .whereType<Map>()
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      _validateRecords(accounts, movements, days);
      for (final account in accounts) {
        final color = account['color'] as String;
        account['color'] =
            0xff000000 | int.parse(color.substring(1), radix: 16);
      }

      final dataStart = 4 + metadataLength;
      final attachments = <Map<String, Object?>>[];
      final ranges = <(int, int)>[];
      for (final raw in rawMetadata['attachments'] as List) {
        if (raw is! Map) {
          throw const FormatException(
            'La copia contiene un adjunto no válido.',
          );
        }
        final item = Map<String, Object?>.from(raw);
        final offset = (item['offset'] as num?)?.toInt() ?? -1;
        final length = (item['length'] as num?)?.toInt() ?? 0;
        final date = item['date'];
        if (!_validDate(date) ||
            item['name'] is! String ||
            item['mime'] is! String ||
            offset < 0 ||
            length <= 0 ||
            dataStart + offset + length > plainSize) {
          throw const FormatException(
            'La copia contiene un adjunto no válido.',
          );
        }
        ranges.add((offset, offset + length));
        attachments.add({
          'date': date,
          'name': item['name'],
          'mime': item['mime'],
          'size': length,
          'createdAt': item['createdAt'] ?? 0,
          'sourcePath': plaintextFile.path,
          'sourceOffset': dataStart + offset,
          'sourceLength': length,
        });
      }
      ranges.sort((a, b) => a.$1.compareTo(b.$1));
      var expectedOffset = 0;
      for (final range in ranges) {
        if (range.$1 != expectedOffset) {
          throw const FormatException(
            'El bloque de archivos de la copia está dañado.',
          );
        }
        expectedOffset = range.$2;
      }
      if (dataStart + expectedOffset != plainSize) {
        throw const FormatException('El tamaño de los adjuntos no coincide.');
      }

      final settings = rawMetadata['settings'] as Map<String, dynamic>;
      final rawTargets = settings['dailyTargets'];
      if (rawTargets is! List ||
          rawTargets.length != 7 ||
          rawTargets.any(
            (value) => value is! num || value < 0 || value > 1440,
          )) {
        throw const FormatException(
          'Los objetivos de la copia no son válidos.',
        );
      }
      final overrides = <String, int>{};
      final rawOverrides = settings['dateOverrides'];
      if (rawOverrides is Map) {
        for (final entry in rawOverrides.entries) {
          final value = entry.value;
          if (_validDate(entry.key) &&
              value is num &&
              value >= 0 &&
              value <= 1440) {
            overrides[entry.key.toString()] = value.toInt();
          }
        }
      }
      final weekStart = (settings['weekStart'] as num?)?.toInt() ?? 1;
      if (weekStart < 1 || weekStart > 7) {
        throw const FormatException('El inicio de semana no es válido.');
      }
      await _database.restoreBackupData(
        accounts: accounts,
        movements: movements,
        days: days,
        attachments: attachments,
        targets: rawTargets.map((value) => (value as num).toInt()).toList(),
        overrides: overrides,
        weekStart: weekStart,
      );
    } finally {
      await handle.close();
    }
  }

  void _validateRecords(
    List<Map<String, Object?>> accounts,
    List<Map<String, Object?>> movements,
    List<Map<String, Object?>> days,
  ) {
    final ids = <String>{};
    for (final account in accounts) {
      final id = account['id']?.toString();
      final name = account['name'];
      if (id == null ||
          name is! String ||
          name.trim().isEmpty ||
          !ids.add(id)) {
        throw const FormatException('La copia contiene una cuenta no válida.');
      }
      final color = account['color'];
      if (color is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
        throw const FormatException('La copia contiene un color no válido.');
      }
    }
    if (accounts.isNotEmpty &&
        accounts.every((account) => account['archived'] == 1)) {
      accounts.first['archived'] = 0;
    }
    for (final movement in movements) {
      if (movement['accountId'] == null ||
          !ids.contains(movement['accountId'].toString()) ||
          !_validDate(movement['date']) ||
          !_validMinute(movement['startMin']) ||
          !_validMinute(movement['endMin']) ||
          !_validNonnegativeInt(movement['breakMin'])) {
        throw const FormatException('La copia contiene un tramo no válido.');
      }
    }
    for (final day in days) {
      if (!_validDate(day['date'])) {
        throw const FormatException('La copia contiene una fecha no válida.');
      }
    }
  }

  Future<SecretKey> _deriveKey(
    String password,
    List<int> salt, {
    int iterations = _iterations,
  }) => Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  void _validatePassword(String password) {
    if (password.length < 8) {
      throw ArgumentError('La contraseña debe tener al menos 8 caracteres.');
    }
  }

  bool _validDate(Object? value) {
    if (value is! String) return false;
    final date = DateTime.tryParse(value);
    return date != null &&
        dateKey(date) == value &&
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
  }

  bool _validMinute(Object? value) =>
      value is num && value == value.round() && value >= 0 && value <= 1439;

  bool _validNonnegativeInt(Object? value) =>
      value is num && value == value.round() && value >= 0;
}

Future<Uint8List> _readExact(RandomAccessFile file, int length) async {
  final bytes = await file.read(length);
  if (bytes.length != length) {
    throw const FormatException('La copia está incompleta o dañada.');
  }
  return bytes;
}
