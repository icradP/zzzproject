import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/contacts_panel.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';

void main() {
  testWidgets('creates a group with selected contacts', (tester) async {
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    ImConversation? selectedConversation;
    await tester.pumpWidget(
      ImScope(
        repository: MockImRepository(),
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(
            body: ContactsPanel(
              onConversationSelected:
                  (conversation) => selectedConversation = conversation,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('群聊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create group'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('create-group-panel')), findsOneWidget);
    expect(find.byType(ZzzModalPanel), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    final nameInput = find.descendant(
      of: find.byKey(const ValueKey('create-group-name')),
      matching: find.byType(TextField),
    );
    await tester.enterText(nameInput, 'Weekend plans');
    await tester.tap(find.byKey(const ValueKey('create-group-member-belle')));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    final memberSearch = find.descendant(
      of: find.byKey(const ValueKey('create-group-member-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(memberSearch, 'missing contact');
    await tester.pumpAndSettle();
    expect(find.text('No matching contacts'), findsOneWidget);
    await tester.enterText(memberSearch, '');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(selectedConversation?.title, 'Weekend plans');
    expect(selectedConversation?.participantIds, containsAll(['me', 'belle']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('group panel fits a compact mobile viewport', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 568)
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
        child: MaterialApp(
          home: Scaffold(body: ContactsPanel(onConversationSelected: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('群聊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Create group'));
    await tester.pumpAndSettle();

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('create-group-panel')),
    );
    expect(panelRect.left, greaterThanOrEqualTo(0));
    expect(panelRect.right, lessThanOrEqualTo(320));
    expect(panelRect.top, greaterThanOrEqualTo(0));
    expect(panelRect.bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });
}
