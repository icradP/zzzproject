import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local preferences that control message presentation without changing
/// delivery or read-receipt behavior.
class ImMessageDisplayConfig {
  ImMessageDisplayConfig._();

  static const _showMessageStatusKey = 'zzz_im_show_message_status';
  static final ValueNotifier<bool> _showMessageStatus = ValueNotifier(false);

  static ValueListenable<bool> get showMessageStatus => _showMessageStatus;

  static bool get showsMessageStatus => _showMessageStatus.value;

  static Future<bool> load() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getBool(_showMessageStatusKey) ?? false;
    _showMessageStatus.value = value;
    return value;
  }

  static Future<void> setShowMessageStatus(bool value) async {
    _showMessageStatus.value = value;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_showMessageStatusKey, value);
  }
}
