import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/pages/im_home_page.dart';

void main() {
  testWidgets('notification banner enables push from a user gesture', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final pushManager = _FakePushManager();

    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: pushManager,
        onConnectionsChanged: () async {},
        child: const MaterialApp(home: ImHomePage()),
      ),
    );
    await tester.pump();

    expect(find.text('Message notifications'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Turn on'));
    await tester.pump();

    expect(pushManager.enableCalls, 1);
    expect(find.text('Message notifications'), findsNothing);
    expect(find.text('Notifications enabled on this device.'), findsOneWidget);
  });
}

class _FakePushManager extends ImPushManager {
  ImPushPermission _permission = ImPushPermission.defaultState;
  int enableCalls = 0;

  @override
  bool get isSupported => true;

  @override
  bool get isBusy => false;

  @override
  ImPushPermission get permission => _permission;

  @override
  String? get error => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> enable() async {
    enableCalls++;
    _permission = ImPushPermission.enabled;
    notifyListeners();
  }

  @override
  Future<void> disable() async {}
}
