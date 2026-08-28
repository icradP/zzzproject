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
      accessToken:
          clearAccessToken ? null : (accessToken ?? this.accessToken),
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
      extra: json['extra'] != null
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
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Load saved config or return the default (mock).
  static Future<ImConnectionConfig> loadOrDefault() async {
    return await load() ?? const ImConnectionConfig();
  }
}
