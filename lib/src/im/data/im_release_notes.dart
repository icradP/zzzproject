import 'package:shared_preferences/shared_preferences.dart';

part 'im_release_notes.g.dart';

class ImReleaseNote {
  const ImReleaseNote({
    required this.version,
    required this.title,
    required this.items,
    String? id,
  }) : id = id ?? version;

  final String id;
  final String version;
  final String title;
  final List<String> items;
}

/// Versioned product updates shown on first launch and from Settings.
abstract final class ImReleaseNotes {
  static const currentVersion = _currentVersion;
  static const currentId = _currentId;
  static const releases = _releases;
  static const _dismissedVersionKey = 'im.release_notes.dismissed_version';

  static String get displayVersion =>
      currentId == currentVersion ? currentVersion : currentId;

  static ImReleaseNote get current =>
      releases.firstWhere((release) => release.id == currentId);

  static Future<bool> shouldShowCurrent() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_dismissedVersionKey) != currentId;
  }

  static Future<void> dismissCurrent() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_dismissedVersionKey, currentId);
  }
}
