import 'dart:convert';

import 'im_push_bridge_stub.dart'
    if (dart.library.js_interop) 'im_push_bridge_web.dart'
    as platform;

class ImPushBridge {
  const ImPushBridge();

  bool get isSupported => platform.isPushSupported();

  String get permission => platform.pushPermission();

  Future<Map<String, dynamic>?> currentSubscription() async {
    return _decode(await platform.currentPushSubscription());
  }

  Future<Map<String, dynamic>?> subscribe(String publicKey) async {
    return _decode(await platform.subscribeToPush(publicKey));
  }

  Future<void> unsubscribe() => platform.unsubscribeFromPush();

  Map<String, dynamic>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }
}
