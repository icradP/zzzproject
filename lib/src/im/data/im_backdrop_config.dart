import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persisted backdrop scrolling text lines for the ZERO ZONE background.
class ImBackdropConfig {
  ImBackdropConfig({List<String>? lines})
      : lines = lines ?? ['ZERO ZONE', 'ZENLESS', 'ZONE ZERO'];

  final List<String> lines;

  static const _key = 'im_backdrop_lines';

  static ImBackdropConfig instance = ImBackdropConfig();

  Future<void> save() async {
    instance = this;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(lines));
  }

  static Future<ImBackdropConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return instance = ImBackdropConfig();
    try {
      final list = (jsonDecode(raw) as List<dynamic>).cast<String>();
      return instance = ImBackdropConfig(lines: list);
    } catch (_) {
      return instance = ImBackdropConfig();
    }
  }

  ImBackdropConfig copyWith({List<String>? lines}) {
    return ImBackdropConfig(lines: lines ?? this.lines);
  }
}
