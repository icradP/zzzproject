import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted storage base directory for all IM data.
///
/// When [basePath] is `null`, falls back to the default app documents
/// directory (typically `C:\Users\...\AppData\...`).  A custom path
/// redirects media cache, avatars, and the SQLite database to
/// subdirectories under it:
///
/// ```
/// {basePath}/
///   onebot_media_cache/
///   avatars/
///   im_data/
///     im_{selfId}.db
/// ```
class ImStorageConfig {
  ImStorageConfig({this.basePath});

  final String? basePath;

  static const _key = 'im_storage_base_path';

  static const defaultBasePath = 'D:\\ZZZIM';

  // -----------------------------------------------------------------------
  // Resolved directories
  // -----------------------------------------------------------------------

  Future<Directory> resolveMediaCacheDir() => _resolve('onebot_media_cache');
  Future<Directory> resolveAvatarCacheDir() => _resolve('avatars');
  Future<Directory> resolveDatabaseDir() => _resolve('im_data');

  Future<Directory> _resolve(String subDir) async {
    final base = basePath ?? defaultBasePath;
    final d = Directory('$base/$subDir');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (basePath != null) {
      await prefs.setString(_key, basePath!);
    } else {
      await prefs.remove(_key);
    }
  }

  static Future<ImStorageConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return ImStorageConfig();
    return ImStorageConfig(basePath: raw);
  }

  ImStorageConfig copyWith({
    String? basePath,
    bool clearBasePath = false,
  }) {
    return ImStorageConfig(
      basePath: clearBasePath ? null : (basePath ?? this.basePath),
    );
  }

  // -----------------------------------------------------------------------
  // Migration
  // -----------------------------------------------------------------------

  /// Copies files from [oldBase] to [newBase].  Skips files that already
  /// exist in the destination.  Returns the total count of files copied.
  static Future<int> migrate(String oldBase, String newBase) async {
    var count = 0;
    for (final sub in ['onebot_media_cache', 'avatars', 'im_data']) {
      final src = Directory('$oldBase/$sub');
      final dst = Directory('$newBase/$sub');
      if (!await src.exists()) continue;
      if (!await dst.exists()) await dst.create(recursive: true);
      await for (final entity in src.list(recursive: true)) {
        if (entity is File) {
          final relative = entity.path.substring(src.path.length + 1);
          final target = File('${dst.path}/$relative');
          if (await target.exists()) continue;
          await target.parent.create(recursive: true);
          await entity.copy(target.path);
          count++;
        }
      }
    }
    return count;
  }
}
