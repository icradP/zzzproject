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

    await tester.enterText(find.byType(TextField).last, 'Weekend plans');
    await tester.tap(find.text('Belle').last);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(selectedConversation?.title, 'Weekend plans');
    expect(selectedConversation?.participantIds, containsAll(['me', 'belle']));
    expect(tester.takeException(), isNull);
  });
}
