import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/pages/im_home_page.dart';
import 'package:zzzproject/src/im/widgets/conversation_list_view.dart';

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

  testWidgets('compact home switches sections with bottom navigation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..physicalSize = const Size(390, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: const MaterialApp(home: ImHomePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final navigation = find.byKey(
      const ValueKey('mobile-bottom-navigation'),
    );
    expect(navigation, findsOneWidget);
    expect(find.byType(ConversationListView), findsOneWidget);

    await tester.tap(
      find.descendant(of: navigation, matching: find.text('Contacts')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('mobile-contacts')), findsOneWidget);
    expect(find.text('Contacts'), findsWidgets);

    await tester.tap(
      find.descendant(of: navigation, matching: find.text('Settings')),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 2);
    expect(find.text('IM Settings'), findsOneWidget);

    await tester.tap(
      find.descendant(of: navigation, matching: find.text('Conversations')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ConversationListView), findsOneWidget);
    expect(tester.takeException(), isNull);
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
