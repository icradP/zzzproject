import 'package:shared_preferences/shared_preferences.dart';

class ImReleaseNote {
  const ImReleaseNote({
    required this.version,
    required this.title,
    required this.items,
  });

  final String version;
  final String title;
  final List<String> items;
}

/// Versioned product updates shown on first launch and from Settings.
abstract final class ImReleaseNotes {
  static const currentVersion = '1.3.0';
  static const _dismissedVersionKey = 'im.release_notes.dismissed_version';

  static const releases = <ImReleaseNote>[
    ImReleaseNote(
      version: currentVersion,
      title: 'Group governance',
      items: [
        'Publish, edit, pin, read, and remove announcements from group history.',
        'Manage group owners and administrators with server-enforced permissions.',
        'Choose all messages, mentions and announcements, or muted notifications per conversation.',
      ],
    ),
    ImReleaseNote(
      version: '1.2.0',
      title: 'Everyday messaging',
      items: [
        'Record, preview, and send voice messages on Web and desktop.',
        'Share links and locations without server-side page or map fetching.',
        'Forward one or more messages and send rate-limited pokes.',
      ],
    ),
    ImReleaseNote(
      version: '1.1.0',
      title: 'Expression and clarity',
      items: [
        'Send built-in stickers without uploading the same image each time.',
        'See compact platform icons in conversations and contacts.',
        'Review version-by-version updates from Settings.',
      ],
    ),
    ImReleaseNote(
      version: '1.0.0',
      title: 'PWA and media foundation',
      items: [
        'Added measurable PWA loading stages and improved offline caching.',
        'Added client-managed image hosting and server-hosted thumbnails.',
        'Added accounts, avatars, friend requests, groups, and notifications.',
      ],
    ),
  ];

  static ImReleaseNote get current =>
      releases.firstWhere((release) => release.version == currentVersion);

  static Future<bool> shouldShowCurrent() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_dismissedVersionKey) != currentVersion;
  }

  static Future<void> dismissCurrent() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_dismissedVersionKey, currentVersion);
  }
}
