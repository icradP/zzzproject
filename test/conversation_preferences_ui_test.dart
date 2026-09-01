import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/widgets/conversation_list_view.dart';

void main() {
  testWidgets('conversation menu toggles mute and pin state', (tester) async {
    tester.view
      ..physicalSize = const Size(420, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = MockImRepository();

    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ConversationListView(
              selectedConversationId: null,
              onConversationSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Belle'));
    await tester.pumpAndSettle();
    expect(find.text('Unpin'), findsOneWidget);
    expect(find.text('Mute notifications'), findsOneWidget);

    await tester.tap(find.text('Mute notifications'));
    await tester.pumpAndSettle();
    expect((await repository.getConversation('dm_belle_me'))!.isMuted, isTrue);
    expect(find.byIcon(Icons.notifications_off_outlined), findsWidgets);

    await tester.longPress(find.text('Belle'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(
      (await repository.getConversation('dm_belle_me'))!.isPinned,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
}
