import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Togglable animation effects for the IM UI.
///
/// Use [ImAnimationConfig.instance] to read current settings from anywhere.
/// Call [save] to persist changes.
class ImAnimationConfig {
  ImAnimationConfig({
    this.conversationListSlide = true,
    this.chatPanelSlide = true,
    this.backgroundMotion = true,
    this.panelEntrance = true,
  });

  /// Shared instance updated on load / save. Widgets read directly.
  static ImAnimationConfig instance = ImAnimationConfig();

  /// Slide animation when conversations reorder in the list.
  final bool conversationListSlide;

  /// Slide animation when switching between chat panels.
  final bool chatPanelSlide;

  /// Animated background motion (ZERO ZONE backdrop).
  final bool backgroundMotion;

  /// Entrance fade/slide on panels and dialogs.
  final bool panelEntrance;

  static const _key = 'im_animation_config';

  // -- Persistence ---------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'conversationListSlide': conversationListSlide,
    'chatPanelSlide': chatPanelSlide,
    'backgroundMotion': backgroundMotion,
    'panelEntrance': panelEntrance,
  };

  factory ImAnimationConfig.fromJson(Map<String, dynamic> json) {
    return ImAnimationConfig(
      conversationListSlide:
          (json['conversationListSlide'] as bool?) ?? true,
      chatPanelSlide: (json['chatPanelSlide'] as bool?) ?? true,
      backgroundMotion: (json['backgroundMotion'] as bool?) ?? true,
      panelEntrance: (json['panelEntrance'] as bool?) ?? true,
    );
  }

  ImAnimationConfig copyWith({
    bool? conversationListSlide,
    bool? chatPanelSlide,
    bool? backgroundMotion,
    bool? panelEntrance,
  }) {
    return ImAnimationConfig(
      conversationListSlide:
          conversationListSlide ?? this.conversationListSlide,
      chatPanelSlide: chatPanelSlide ?? this.chatPanelSlide,
      backgroundMotion: backgroundMotion ?? this.backgroundMotion,
      panelEntrance: panelEntrance ?? this.panelEntrance,
    );
  }

  Future<void> save() async {
    instance = this;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  static Future<ImAnimationConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return instance = ImAnimationConfig();
    try {
      return instance = ImAnimationConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return instance = ImAnimationConfig();
    }
  }
}
