import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Supported IM platforms.
enum ImPlatform { mock, nonebot, zzzServer }

/// WebSocket connection mode.
///
/// Mirrors OneBot's concept: forward = client connects to server,
/// reverse = server connects to client.
enum WsMode { forward, reverse }

class ImConnectionConfig {
  const ImConnectionConfig({
    this.platform = ImPlatform.mock,
    this.httpEndpoint,
    this.wsEndpoint,
    this.wsMode = WsMode.forward,
    this.accessToken,
    this.selfId = '',
    this.serverUrl,
    this.extra = const {},
  });

  final ImPlatform platform;
  final String? httpEndpoint;
  final String? wsEndpoint;
  final WsMode wsMode;
  final String? accessToken;
  final String selfId;

  /// Server URL for zzzServer platform.
  final String? serverUrl;

  /// Platform-specific extra configuration.
  final Map<String, dynamic> extra;

  static const _key = 'im_connection_config';

  ImConnectionConfig copyWith({
    ImPlatform? platform,
    String? httpEndpoint,
    String? wsEndpoint,
    WsMode? wsMode,
    String? accessToken,
    String? selfId,
    String? serverUrl,
    Map<String, dynamic>? extra,
    bool clearHttpEndpoint = false,
    bool clearWsEndpoint = false,
    bool clearAccessToken = false,
    bool clearServerUrl = false,
  }) {
    return ImConnectionConfig(
      platform: platform ?? this.platform,
      httpEndpoint:
          clearHttpEndpoint ? null : (httpEndpoint ?? this.httpEndpoint),
      wsEndpoint: clearWsEndpoint ? null : (wsEndpoint ?? this.wsEndpoint),
      wsMode: wsMode ?? this.wsMode,
      accessToken: clearAccessToken ? null : (accessToken ?? this.accessToken),
      selfId: selfId ?? this.selfId,
      serverUrl: clearServerUrl ? null : (serverUrl ?? this.serverUrl),
      extra: extra ?? this.extra,
    );
  }

  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'httpEndpoint': httpEndpoint,
    'wsEndpoint': wsEndpoint,
    'wsMode': wsMode.name,
    'accessToken': accessToken,
    'selfId': selfId,
    'serverUrl': serverUrl,
    'extra': extra,
  };

  factory ImConnectionConfig.fromJson(Map<String, dynamic> json) {
    return ImConnectionConfig(
      platform: ImPlatform.values.firstWhere(
        (p) => p.name == json['platform'],
        orElse: () => ImPlatform.mock,
      ),
      httpEndpoint: json['httpEndpoint'] as String?,
      wsEndpoint: json['wsEndpoint'] as String?,
      wsMode: _parseWsMode(json['wsMode'] as String?),
      accessToken: json['accessToken'] as String?,
      selfId: json['selfId'] as String? ?? '',
      serverUrl: json['serverUrl'] as String?,
      extra:
          json['extra'] != null
              ? Map<String, dynamic>.from(json['extra'] as Map)
              : const {},
    );
  }

  static WsMode _parseWsMode(String? name) {
    if (name == null) return WsMode.forward;
    return WsMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => WsMode.forward,
    );
  }

  bool get isNoneBot => platform == ImPlatform.nonebot;
  bool get isZzzServer => platform == ImPlatform.zzzServer;

  /// Persist to SharedPreferences.
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  /// Load from SharedPreferences, returning `null` when nothing is saved.
  static Future<ImConnectionConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return ImConnectionConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Load saved config or return the default (mock).
  static Future<ImConnectionConfig> loadOrDefault() async {
    return await load() ?? const ImConnectionConfig();
  }
}

/// A locally managed connection to one IM source.
///
/// Profiles deliberately live in the client. The ZZZ server only sees its own
/// connection and remains unaware of NoneBot or any future platform adapters.
class ImConnectionProfile {
  const ImConnectionProfile({
    required this.id,
    required this.name,
    required this.config,
    this.enabled = true,
  });

  final String id;
  final String name;
  final ImConnectionConfig config;
  final bool enabled;

  ImConnectionProfile copyWith({
    String? id,
    String? name,
    ImConnectionConfig? config,
    bool? enabled,
  }) {
    return ImConnectionProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      config: config ?? this.config,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'config': config.toJson(),
  };

  factory ImConnectionProfile.fromJson(Map<String, dynamic> json) {
    return ImConnectionProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
      config: ImConnectionConfig.fromJson(
        Map<String, dynamic>.from(json['config'] as Map? ?? const {}),
      ),
    );
  }

  static ImConnectionProfile fromLegacy(ImConnectionConfig config) {
    return ImConnectionProfile(
      id: _newProfileId(config.platform),
      name: defaultName(config.platform),
      config: config,
    );
  }

  static String defaultName(ImPlatform platform) => switch (platform) {
    ImPlatform.mock => 'Demo',
    ImPlatform.nonebot => 'QQ / NoneBot',
    ImPlatform.zzzServer => 'ZZZ Server',
  };

  static String createId(ImPlatform platform) => _newProfileId(platform);

  static String _newProfileId(ImPlatform platform) {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '${platform.name}_$timestamp';
  }
}

/// Versioned collection of client-side connection profiles.
class ImConnectionProfiles {
  const ImConnectionProfiles({this.profiles = const [], this.primaryProfileId});

  final List<ImConnectionProfile> profiles;
  final String? primaryProfileId;

  static const _key = 'im_connection_profiles_v1';

  List<ImConnectionProfile> get enabledProfiles =>
      profiles.where((profile) => profile.enabled).toList(growable: false);

  ImConnectionProfile? get primaryProfile {
    for (final profile in profiles) {
      if (profile.id == primaryProfileId) return profile;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'primaryProfileId': primaryProfileId,
    'profiles': profiles.map((profile) => profile.toJson()).toList(),
  };

  factory ImConnectionProfiles.fromJson(Map<String, dynamic> json) {
    final profiles = (json['profiles'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (profile) =>
              ImConnectionProfile.fromJson(Map<String, dynamic>.from(profile)),
        )
        .where((profile) => profile.id.isNotEmpty)
        .toList(growable: false);
    return ImConnectionProfiles(
      profiles: profiles,
      primaryProfileId: json['primaryProfileId'] as String?,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  static Future<ImConnectionProfiles> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        return ImConnectionProfiles.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        // Fall through to the legacy migration below.
      }
    }

    final legacy = await ImConnectionConfig.load();
    if (legacy == null) return const ImConnectionProfiles();
    final profile = ImConnectionProfile.fromLegacy(legacy);
    final migrated = ImConnectionProfiles(
      profiles: [profile],
      primaryProfileId: profile.id,
    );
    await migrated.save();
    return migrated;
  }

  static Future<ImConnectionProfiles> replacePrimaryZzz(
    ImConnectionConfig config,
  ) async {
    final current = await load();
    final profiles = [...current.profiles];
    final existingIndex = profiles.indexWhere(
      (profile) => profile.config.platform == ImPlatform.zzzServer,
    );
    final profile = ImConnectionProfile(
      id:
          existingIndex >= 0
              ? profiles[existingIndex].id
              : ImConnectionProfile.createId(ImPlatform.zzzServer),
      name:
          existingIndex >= 0
              ? profiles[existingIndex].name
              : ImConnectionProfile.defaultName(ImPlatform.zzzServer),
      config: config,
    );
    if (existingIndex >= 0) {
      profiles[existingIndex] = profile;
    } else {
      profiles.insert(0, profile);
    }
    final updated = ImConnectionProfiles(
      profiles: profiles,
      primaryProfileId: profile.id,
    );
    await updated.save();
    return updated;
  }

  /// Removes the account session from the active ZZZ profile while retaining
  /// its hidden server endpoint and display name for the next sign-in.
  static Future<void> clearPrimaryZzzSession() async {
    final current = await load();
    var targetIndex = current.profiles.indexWhere(
      (profile) =>
          profile.id == current.primaryProfileId && profile.config.isZzzServer,
    );
    if (targetIndex < 0) {
      targetIndex = current.profiles.indexWhere(
        (profile) => profile.config.isZzzServer,
      );
    }
    if (targetIndex < 0) return;

    final profiles = [...current.profiles];
    final target = profiles[targetIndex];
    final extra = Map<String, dynamic>.from(target.config.extra)
      ..remove('authMode');
    profiles[targetIndex] = target.copyWith(
      config: target.config.copyWith(
        selfId: '',
        clearAccessToken: true,
        extra: extra,
      ),
    );
    await ImConnectionProfiles(
      profiles: profiles,
      primaryProfileId: current.primaryProfileId,
    ).save();
  }
}
