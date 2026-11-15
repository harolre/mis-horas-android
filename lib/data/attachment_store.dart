import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

class StoredAttachment {
  const StoredAttachment({
    required this.name,
    required this.mime,
    required this.size,
    required this.filePath,
    required this.thumbnailPath,
  });

  final String name;
  final String mime;
  final int size;
  final String filePath;
  final String? thumbnailPath;
}

/// Stores attachment content as app-private files; SQLite only stores metadata.
class AttachmentStore {
  AttachmentStore._(this.root);

  final Directory root;

  static Future<AttachmentStore> open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'mis_horas'));
    await Directory(p.join(root.path, 'attachments')).create(recursive: true);
    await Directory(p.join(root.path, 'staging')).create(recursive: true);
    return AttachmentStore._(root);
  }

  String resolve(String relativePath) {
    final normalized = p.normalize(relativePath);
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('..${p.separator}')) {
      throw ArgumentError('La ruta del adjunto no es válida.');
    }
    return p.join(root.path, normalized);
  }

  Future<StoredAttachment> importStream({
    required String id,
    required String name,
    required String mime,
    required Stream<List<int>> bytes,
    bool compressImage = true,
  }) async {
    final staging = Directory(p.join(root.path, 'staging', 'attachment-$id'));
    await staging.create(recursive: true);
    final source = File(p.join(staging.path, 'source'));
    try {
      final sink = source.openWrite();
      await sink.addStream(bytes);
      await sink.close();
      if (await source.length() == 0) {
        throw const FormatException('El archivo está vacío.');
      }
      return await _storePrepared(
        id: id,
        source: source,
        staging: staging,
        name: name,
        mime: mime,
        compressImage: compressImage,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<StoredAttachment> importBytes({
    required String id,
    required String name,
    required String mime,
    required List<int> bytes,
    bool compressImage = false,
  }) async {
    final staging = Directory(p.join(root.path, 'staging', 'attachment-$id'));
    await staging.create(recursive: true);
    final source = File(p.join(staging.path, 'source'));
    try {
      await source.writeAsBytes(bytes, flush: true);
      return await _storePrepared(
        id: id,
        source: source,
        staging: staging,
        name: name,
        mime: mime,
        compressImage: compressImage,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<StoredAttachment> _storePrepared({
    required String id,
    required File source,
    required Directory staging,
    required String name,
    required String mime,
    required bool compressImage,
  }) async {
    var storedFile = source;
    var storedName = name;
    var storedMime = mime;
    final isImage = mime.startsWith('image/');
    final extension = _extensionFor(mime, name);

    if (isImage && compressImage) {
      final compressedExtension = mime == 'image/png' ? '.png' : '.jpg';
      final compressedPath = p.join(
        staging.path,
        'optimized$compressedExtension',
      );
      try {
        final output = await FlutterImageCompress.compressAndGetFile(
          source.path,
          compressedPath,
          minWidth: 2560,
          minHeight: 2560,
          quality: 88,
          autoCorrectionAngle: true,
          format: mime == 'image/png'
              ? CompressFormat.png
              : CompressFormat.jpeg,
          keepExif: false,
        );
        if (output != null) {
          final compressedFile = File(output.path);
          if (await compressedFile.exists() &&
              await compressedFile.length() < await source.length()) {
            storedFile = compressedFile;
            if (mime != 'image/png') {
              storedMime = 'image/jpeg';
              storedName = p.setExtension(name, '.jpg');
            }
          }
        }
      } catch (_) {
        // Compression is best-effort: keep the picked file if a decoder or
        // encoder on this device does not support its format.
      }
    }

    final finalRelative = p.join(
      'attachments',
      '$id${storedFile == source ? extension : _extensionFor(storedMime, storedName)}',
    );
    final finalFile = File(resolve(finalRelative));
    await finalFile.parent.create(recursive: true);
    await storedFile.copy(finalFile.path);

    String? thumbnailRelative;
    if (isImage) {
      thumbnailRelative = await _createImageThumbnail(
        id: id,
        source: finalFile,
        staging: staging,
      );
    } else if (mime == 'application/pdf') {
      thumbnailRelative = await _createPdfThumbnail(
        id: id,
        source: finalFile,
        staging: staging,
      );
    }

    final size = await finalFile.length();
    if (await staging.exists()) await staging.delete(recursive: true);
    return StoredAttachment(
      name: storedName,
      mime: storedMime,
      size: size,
      filePath: finalRelative,
      thumbnailPath: thumbnailRelative,
    );
  }

  Future<String?> _createImageThumbnail({
    required String id,
    required File source,
    required Directory staging,
  }) async {
    final temporary = File(p.join(staging.path, 'thumbnail.jpg'));
    try {
      final output = await FlutterImageCompress.compressAndGetFile(
        source.path,
        temporary.path,
        minWidth: 400,
        minHeight: 400,
        quality: 76,
        autoCorrectionAngle: true,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (output == null || !await File(output.path).exists()) return null;
      return await _persistThumbnail(id, File(output.path));
    } catch (_) {
      return null;
    }
  }

  Future<String?> _createPdfThumbnail({
    required String id,
    required File source,
    required Directory staging,
  }) async {
    PdfDocument? document;
    PdfPage? page;
    try {
      document = await PdfDocument.openFile(source.path);
      if (document.pagesCount == 0) return null;
      page = await document.getPage(1);
      final ratio = page.width / page.height;
      final width = ratio >= 1 ? 400.0 : 400.0 * ratio;
      final height = ratio >= 1 ? 400.0 / ratio : 400.0;
      final image = await page.render(
        width: width,
        height: height,
        format: PdfPageImageFormat.jpeg,
        quality: 76,
        backgroundColor: '#FFFFFF',
      );
      if (image == null) return null;
      final temporary = File(p.join(staging.path, 'thumbnail.jpg'));
      await temporary.writeAsBytes(image.bytes, flush: true);
      return await _persistThumbnail(id, temporary);
    } catch (_) {
      // A password-protected or unsupported PDF is still stored unchanged.
      return null;
    } finally {
      if (page != null && !page.isClosed) await page.close();
      if (document != null && !document.isClosed) await document.close();
    }
  }

  Future<String> _persistThumbnail(String id, File source) async {
    const relative = 'attachments';
    final path = p.join(relative, '$id.thumb.jpg');
    final target = File(resolve(path));
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    return path;
  }

  Future<void> delete(String? filePath, String? thumbnailPath) async {
    for (final path in [filePath, thumbnailPath]) {
      if (path == null || path.isEmpty) continue;
      final file = File(resolve(path));
      if (await file.exists()) await file.delete();
    }
  }

  String _extensionFor(String mime, String name) {
    final known = switch (mime) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/heic' => '.heic',
      'image/heif' => '.heif',
      'application/pdf' => '.pdf',
      _ => p.extension(name).isEmpty ? '.bin' : p.extension(name),
    };
    return known;
  }
}
