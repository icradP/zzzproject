import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// User-adjustable NSFW detection settings.
///
/// Use [ImNsfwConfig.instance] to read current settings from anywhere.
/// Call [save] to persist changes.
class ImNsfwConfig {
  ImNsfwConfig({
    this.enabled = false,
    Map<int, double>? thresholds,
    this.persistReveal = false,
  }) : thresholds = thresholds ?? Map.of(_defaultThresholds);

  /// Shared instance, updated on load / save.
  static ImNsfwConfig instance = ImNsfwConfig();

  /// Master toggle — when false no NSFW detection runs at all.
  final bool enabled;

  /// Per-class threshold map.  Only keys present here are checked against
  /// the model output.  Values are in [0.0, 1.0].
  final Map<int, double> thresholds;

  /// When true, revealed images stay revealed across app restarts.
  /// When false, every new session re-runs detection.
  final bool persistReveal;

  // -- class labels & defaults ----------------------------------------------

  /// NudeNet 18 class labels (0-indexed).
  static const labels = [
    'FEMALE_GENITALIA_COVERED',
    'FACE_FEMALE',
    'BUTTOCKS_EXPOSED',
    'FEMALE_BREAST_EXPOSED',
    'FEMALE_GENITALIA_EXPOSED',
    'MALE_BREAST_EXPOSED',
    'ANUS_EXPOSED',
    'FEET_EXPOSED',
    'BELLY_COVERED',
    'FEET_COVERED',
    'ARMPITS_COVERED',
    'ARMPITS_EXPOSED',
    'FACE_MALE',
    'BELLY_EXPOSED',
    'MALE_GENITALIA_EXPOSED',
    'ANUS_COVERED',
    'FEMALE_BREAST_COVERED',
    'BUTTOCKS_COVERED',
  ];

  /// Default thresholds for classes typically considered NSFW.
  static const _defaultThresholds = {
    2: 0.2, // BUTTOCKS_EXPOSED
    3: 0.2, // FEMALE_BREAST_EXPOSED
    4: 0.2, // FEMALE_GENITALIA_EXPOSED
    5: 0.2, // MALE_BREAST_EXPOSED
    6: 0.2, // ANUS_EXPOSED
    14: 0.2, // MALE_GENITALIA_EXPOSED
  };

  // -- helpers -------------------------------------------------------------

  /// Whether [classIndex] should be checked at all.
  bool isClassEnabled(int classIndex) => thresholds.containsKey(classIndex);

  /// Confidence threshold for the given class, or 0.2 if not set.
  double thresholdFor(int classIndex) => thresholds[classIndex] ?? 0.2;

  /// Set a threshold for [classIndex].  Pass `null` to remove (disable).
  void setThreshold(int classIndex, double? value) {
    if (value == null) {
      thresholds.remove(classIndex);
    } else {
      thresholds[classIndex] = value.clamp(0.01, 0.99);
    }
  }

  // -- persistence ---------------------------------------------------------

  static const _key = 'im_nsfw_config';

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'thresholds':
            thresholds.map((k, v) => MapEntry(k.toString(), v)),
        'persistReveal': persistReveal,
      };

  factory ImNsfwConfig.fromJson(Map<String, dynamic> json) {
    final rawThresholds = json['thresholds'] as Map<String, dynamic>?;
    final thresholds = <int, double>{};
    if (rawThresholds != null) {
      for (final entry in rawThresholds.entries) {
        final k = int.tryParse(entry.key);
        final v = (entry.value as num?)?.toDouble();
        if (k != null && v != null) thresholds[k] = v;
      }
    }
    return ImNsfwConfig(
      enabled: (json['enabled'] as bool?) ?? false,
      thresholds: thresholds.isEmpty ? null : thresholds,
      persistReveal: (json['persistReveal'] as bool?) ?? false,
    );
  }

  ImNsfwConfig copyWith({
    bool? enabled,
    Map<int, double>? thresholds,
    bool? persistReveal,
  }) {
    return ImNsfwConfig(
      enabled: enabled ?? this.enabled,
      thresholds: thresholds ?? Map.of(this.thresholds),
      persistReveal: persistReveal ?? this.persistReveal,
    );
  }

  Future<void> save() async {
    instance = this;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  static Future<ImNsfwConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return instance = ImNsfwConfig();
    try {
      return instance = ImNsfwConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return instance = ImNsfwConfig();
    }
  }
}
