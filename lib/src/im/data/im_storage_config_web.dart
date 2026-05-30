import 'package:shared_preferences/shared_preferences.dart';

/// Web-safe stub for [ImStorageConfig].
///
/// On web, there is no local filesystem, so the `resolve*Dir()` methods are
/// omitted.  This stub provides the same persistence API (load / save /
/// copyWith / migrate) so that `zzz_app.dart` can reference the class on
/// both native and web.
class ImStorageConfig {
  ImStorageConfig({this.basePath});

  final String? basePath;

  static const _key = 'im_storage_base_path';

  static const defaultBasePath = '';

  // -----------------------------------------------------------------------
  // Persistence (SharedPreferences — web-compatible)
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
  // Migration (no-op on web)
  // -----------------------------------------------------------------------

  static Future<int> migrate(String oldBase, String newBase) async => 0;
}
