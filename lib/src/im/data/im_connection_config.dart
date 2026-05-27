import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../adapters/nonebot/nonebot_models.dart';

enum ImPlatform { mock, nonebot }

class ImConnectionConfig {
  const ImConnectionConfig({
    this.platform = ImPlatform.mock,
    this.httpEndpoint,
    this.wsEndpoint,
    this.wsMode = OneBotWsMode.forward,
    this.accessToken,
    this.selfId = '',
  });

  final ImPlatform platform;
  final String? httpEndpoint;
  final String? wsEndpoint;
  final OneBotWsMode wsMode;
  final String? accessToken;
  final String selfId;

  static const _key = 'im_connection_config';

  ImConnectionConfig copyWith({
    ImPlatform? platform,
    String? httpEndpoint,
    String? wsEndpoint,
    OneBotWsMode? wsMode,
    String? accessToken,
    String? selfId,
    bool clearHttpEndpoint = false,
    bool clearWsEndpoint = false,
    bool clearAccessToken = false,
  }) {
    return ImConnectionConfig(
      platform: platform ?? this.platform,
      httpEndpoint: clearHttpEndpoint ? null : (httpEndpoint ?? this.httpEndpoint),
      wsEndpoint: clearWsEndpoint ? null : (wsEndpoint ?? this.wsEndpoint),
      wsMode: wsMode ?? this.wsMode,
      accessToken: clearAccessToken ? null : (accessToken ?? this.accessToken),
      selfId: selfId ?? this.selfId,
    );
  }

  Map<String, dynamic> toJson() => {
    'platform': platform.name,
    'httpEndpoint': httpEndpoint,
    'wsEndpoint': wsEndpoint,
    'wsMode': wsMode.name,
    'accessToken': accessToken,
    'selfId': selfId,
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
    );
  }

  static OneBotWsMode _parseWsMode(String? name) {
    if (name == null) return OneBotWsMode.forward;
    return OneBotWsMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => OneBotWsMode.forward,
    );
  }

  bool get isNoneBot => platform == ImPlatform.nonebot;

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
      return ImConnectionConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Load saved config or return the default (mock).
  static Future<ImConnectionConfig> loadOrDefault() async {
    return await load() ?? const ImConnectionConfig();
  }
}
