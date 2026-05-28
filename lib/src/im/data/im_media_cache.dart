import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:onebot_flutter/onebot_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'im_storage_config.dart';

/// Downloads and caches OneBot media files (images, voice, video, files).
///
/// Uses the OneBot [get_image] / [get_record] / [get_video] APIs to retrieve
/// media, then copies the result into the app's local cache directory.
///
/// ```dart
/// final cache = ImMediaCache(client: oneBotClient);
/// final path = await cache.downloadImage(fileId: 'abc123.jpg');
/// ```
class ImMediaCache {
  ImMediaCache({
    required this.client,
    this.maxCacheBytes = 200 * 1024 * 1024,
    this.storageConfig,
  });

  final OneBotClient client;

  /// Soft cap on the cache directory total size (200 MiB default).
  final int maxCacheBytes;

  /// Custom storage paths. Falls back to app documents when `null`.
  final ImStorageConfig? storageConfig;

  Future<Directory> get _cacheDir async {
    if (storageConfig != null) {
      return storageConfig!.resolveMediaCacheDir();
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/onebot_media_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Resolves a [CachedMedia] for an image segment.
  ///
  /// If the file is already cached the in-memory mapping (or file existence
  /// check) returns it immediately. Otherwise the file is fetched via
  /// [OneBotClient.getImage].
  Future<CachedMedia> downloadImage({
    required String fileId,
    String? url,
  }) async {
    return _downloadWithApi(
      fileId: fileId,
      url: url,
      api: () => client.getImage(file: fileId),
    );
  }

  /// Resolves a [CachedMedia] for a voice / record segment.
  Future<CachedMedia> downloadRecord({
    required String fileId,
    String? url,
    String outFormat = 'mp3',
  }) async {
    return _downloadWithApi(
      fileId: fileId,
      url: url,
      api: () => client.getRecord(file: fileId, outFormat: outFormat),
    );
  }

  /// Generic file download — useful for segments whose `file` field points
  /// to a URL that can be fetched directly without the OneBot API.
  Future<CachedMedia> downloadFile({
    required String fileId,
    String? url,
  }) async {
    return _downloadWithApi(
      fileId: fileId,
      url: url,
      api: () async => OneBotFileResult(
        file: url ?? fileId, // caller should provide a resolvable URL
      ),
    );
  }

  /// Delete all cached files.
  Future<void> clear() async {
    final dir = await _cacheDir;
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Total size of the cache directory in bytes.
  Future<int> totalSize() async {
    final dir = await _cacheDir;
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Evicts oldest files until total cache size is under [maxCacheBytes].
  Future<void> prune() async {
    final dir = await _cacheDir;
    if (!await dir.exists()) return;

    final files = <_FileEntry>[];
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        final stat = await entity.stat();
        total += stat.size;
        files.add(_FileEntry(
          entity.path,
          stat.size,
          stat.modified,
        ));
      }
    }
    if (total <= maxCacheBytes) return;

    files.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in files) {
      if (total <= maxCacheBytes) break;
      total -= entry.size;
      File(entry.path).delete();
    }
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  final _cacheIndex = <String, String>{}; // id → local path

  Future<CachedMedia> _downloadWithApi({
    required String fileId,
    String? url,
    required Future<OneBotFileResult> Function() api,
  }) async {
    // Check in-memory index.
    final cached = _cacheIndex[fileId];
    if (cached != null) {
      final f = File(cached);
      if (await f.exists()) {
        return CachedMedia(
          localPath: cached,
          mime: _mimeFromPath(cached),
        );
      }
      _cacheIndex.remove(fileId);
    }

    // Check by file name on disk.
    final dir = await _cacheDir;
    final existing = File('${dir.path}/${_safeName(fileId)}');
    if (await existing.exists()) {
      _cacheIndex[fileId] = existing.path;
      return CachedMedia(
        localPath: existing.path,
        mime: _mimeFromPath(existing.path),
      );
    }

    final targetPath = '${dir.path}/${_safeName(fileId)}';

    try {
      if (url != null && url.isNotEmpty) {
        final uri = Uri.tryParse(url);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          final response = await HttpClient().getUrl(uri);
          final resp = await response.close();
          final bytes = await resp.fold<List<int>>(
            [],
            (prev, chunk) => prev..addAll(chunk),
          );
          await File(targetPath).writeAsBytes(bytes);
          _cacheIndex[fileId] = targetPath;
          await _maybePrune();
          return CachedMedia(
            localPath: targetPath,
            mime: _mimeFromPath(targetPath),
            size: bytes.length,
          );
        }
      }

      // Fallback to OneBot API.
      final result = await api();
      if (result.file.isNotEmpty) {
        final src = File(result.file);
        if (await src.exists()) {
          await src.copy(targetPath);
          _cacheIndex[fileId] = targetPath;
          await _maybePrune();
          return CachedMedia(
            localPath: targetPath,
            mime: _mimeFromPath(targetPath),
            size: await File(targetPath).length(),
          );
        }
      }
    } catch (_) {}

    // Return a best-effort media entry pointing to the remote URL.
    return CachedMedia(localPath: null, url: url);
  }

  Future<void> _maybePrune() async {
    if (Random().nextInt(10) == 0) await prune();
  }

  static String _safeName(String raw) {
    return raw.replaceAll(RegExp(r'[^\w.]'), '_');
  }

  static String? _mimeFromPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      case 'flac':
        return 'audio/flac';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'pdf':
        return 'application/pdf';
      case 'silk':
        return 'audio/silk';
      case 'amr':
        return 'audio/amr';
      default:
        return null;
    }
  }
}

/// Result returned by [ImMediaCache] methods.
@immutable
class CachedMedia {
  const CachedMedia({this.localPath, this.url, this.mime, this.size});

  /// Absolute path to the downloaded file (null when download failed).
  final String? localPath;

  /// Original remote URL (when available).
  final String? url;

  /// Inferred MIME type.
  final String? mime;

  /// File size in bytes (when known).
  final int? size;

  bool get isAvailable => localPath != null && File(localPath!).existsSync();
}

class _FileEntry {
  const _FileEntry(this.path, this.size, this.modified);
  final String path;
  final int size;
  final DateTime modified;
}
