import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'im_storage_config.dart';

/// Generates QQ avatar URLs and caches them as local files.
class ImAvatarCache {
  ImAvatarCache({this.storageConfig});

  final ImStorageConfig? storageConfig;

  Future<Directory> get _cacheDir async {
    if (storageConfig != null) {
      return storageConfig!.resolveAvatarCacheDir();
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/avatars');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Returns the local path for [qq]'s avatar. Downloads if not cached.
  Future<String?> get(String qq) async {
    final dir = await _cacheDir;
    final file = File('${dir.path}/$qq.jpg');
    if (await file.exists()) return file.path;
    return _download(qq, file);
  }

  /// Returns the local path for [groupId]'s avatar. Downloads if not cached.
  Future<String?> getGroup(String groupId) async {
    final dir = await _cacheDir;
    final file = File('${dir.path}/group_$groupId.jpg');
    if (await file.exists()) return file.path;
    final url = groupAvatarUrl(groupId);
    try {
      final uri = Uri.parse(url);
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(
        [],
        (prev, chunk) => prev..addAll(chunk),
      );
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Pre-fetches avatars for multiple QQ numbers in the background.
  void prefetch(List<String> qqs) {
    for (final qq in qqs) {
      get(qq); // fire-and-forget
    }
  }

  /// Delete all cached avatars.
  Future<void> clear() async {
    final dir = await _cacheDir;
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // -----------------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------------

  static String avatarUrl(String qq, {int size = 100}) =>
      'https://q1.qlogo.cn/g?b=qq&nk=$qq&s=$size';

  static String groupAvatarUrl(String groupId, {int size = 0}) =>
      'https://p.qlogo.cn/gh/$groupId/$groupId/$size';

  Future<String?> _download(String qq, File target) async {
    final url = avatarUrl(qq);
    try {
      final uri = Uri.parse(url);
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = await response.fold<List<int>>(
        [],
        (prev, chunk) => prev..addAll(chunk),
      );
      await target.writeAsBytes(bytes);
      return target.path;
    } catch (_) {
      return null;
    }
  }
}
