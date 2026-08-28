import 'dart:async';

import 'package:flutter/foundation.dart';

import '../adapters/im_message_source.dart';
import '../adapters/zzz_server/zzz_server_source.dart';
import 'im_push_bridge.dart';

enum ImPushPermission { unsupported, defaultState, denied, enabled }

abstract class ImPushManager extends ChangeNotifier {
  bool get isSupported;
  bool get isBusy;
  ImPushPermission get permission;
  String? get error;

  Future<void> start();
  Future<void> enable();
  Future<void> disable();
}

class NoOpImPushManager extends ImPushManager {
  @override
  bool get isSupported => false;

  @override
  bool get isBusy => false;

  @override
  ImPushPermission get permission => ImPushPermission.unsupported;

  @override
  String? get error => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

class ZzzServerPushManager extends ImPushManager {
  ZzzServerPushManager({
    required this.source,
    ImPushBridge bridge = const ImPushBridge(),
  }) : _bridge = bridge;

  final ZzzServerSource source;
  final ImPushBridge _bridge;
  StreamSubscription<ConnectionStatus>? _connectionSubscription;
  bool _busy = false;
  String? _error;
  late ImPushPermission _permission = _readPermission();

  @override
  bool get isSupported => _bridge.isSupported;

  @override
  bool get isBusy => _busy;

  @override
  ImPushPermission get permission => _permission;

  @override
  String? get error => _error;

  @override
  Future<void> start() async {
    await _connectionSubscription?.cancel();
    _connectionSubscription = source.connectionStatus.listen((status) {
      if (status == ConnectionStatus.connected) {
        unawaited(_syncExisting());
      }
    });
    notifyListeners();
  }

  @override
  Future<void> enable() async {
    if (!isSupported || _busy) return;
    _setBusy(true);
    try {
      final publicKey = await source.getPushPublicKey();
      if (publicKey == null || publicKey.isEmpty) {
        throw StateError('Web Push is not configured on the server.');
      }
      final subscription = await _bridge.subscribe(publicKey);
      if (subscription == null) {
        throw StateError('Notification permission was not granted.');
      }
      await source.registerPushSubscription(subscription);
      _permission = ImPushPermission.enabled;
      _error = null;
    } catch (error) {
      _permission = _readPermission();
      _error = '$error';
    } finally {
      _setBusy(false);
    }
  }

  @override
  Future<void> disable() async {
    if (!isSupported || _busy) return;
    _setBusy(true);
    try {
      final subscription = await _bridge.currentSubscription();
      final endpoint = subscription?['endpoint'] as String?;
      if (endpoint != null) await source.unregisterPushSubscription(endpoint);
      await _bridge.unsubscribe();
      _permission = ImPushPermission.defaultState;
      _error = null;
    } catch (error) {
      _error = '$error';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _syncExisting() async {
    if (!isSupported) return;
    try {
      final subscription = await _bridge.currentSubscription();
      if (subscription == null) return;
      await source.registerPushSubscription(subscription);
      _permission = ImPushPermission.enabled;
      _error = null;
      notifyListeners();
    } catch (error) {
      _error = '$error';
      notifyListeners();
    }
  }

  ImPushPermission _readPermission() => switch (_bridge.permission) {
    'granted' => ImPushPermission.defaultState,
    'denied' => ImPushPermission.denied,
    'default' => ImPushPermission.defaultState,
    _ => ImPushPermission.unsupported,
  };

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_connectionSubscription?.cancel());
    super.dispose();
  }
}
