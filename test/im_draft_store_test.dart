import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/src/im/data/im_draft_store.dart';
import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('drafts persist independently per account and conversation', () async {
    await ImDraftStore.save(
      ownerId: 'alice',
      conversationId: 'group_team',
      text: 'Alice draft',
    );
    await ImDraftStore.save(
      ownerId: 'bob',
      conversationId: 'group_team',
      text: 'Bob draft',
    );

    expect(
      await ImDraftStore.load(ownerId: 'alice', conversationId: 'group_team'),
      'Alice draft',
    );
    expect(
      await ImDraftStore.load(ownerId: 'bob', conversationId: 'group_team'),
      'Bob draft',
    );

    await ImDraftStore.save(
      ownerId: 'alice',
      conversationId: 'group_team',
      text: '   ',
    );
    expect(
      await ImDraftStore.load(ownerId: 'alice', conversationId: 'group_team'),
      isEmpty,
    );
  });

  testWidgets('chat composer restores and clears its saved draft', (
    tester,
  ) async {
    const conversationId = 'dm_belle_me';
    await ImDraftStore.save(
      ownerId: 'me',
      conversationId: conversationId,
      text: 'Continue this later',
    );
    final repository = MockImRepository();
    final conversation = (await repository.getConversation(conversationId))!;

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
            body: ImChatRoomView(
              conversation: conversation,
              messages: const <ImMessage>[],
              onSend: (_) async {},
              resolveUserName: (id) async => id,
              resolveUserAvatar:
                  (_) async => const AssetImage('assets/characters/Wise.png'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller?.text, 'Continue this later');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      await ImDraftStore.load(ownerId: 'me', conversationId: conversationId),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
