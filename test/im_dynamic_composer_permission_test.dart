import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';

void main() {
  testWidgets('custom bubble composer action follows the caller permission', (
    tester,
  ) async {
    final repository = MockImRepository();
    addTearDown(repository.dispose);

    Widget buildChat({required bool canCreateDynamic}) {
      return ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: MaterialApp(
          home: Scaffold(
            body: ImChatRoomView(
              conversation: const ImConversation(
                id: 'group-permission-test',
                type: ImConversationType.group,
                title: 'Permission test',
                participantIds: ['me', 'member'],
              ),
              messages: const [],
              onSend: (_) async {},
              resolveUserName: (userId) async => userId,
              resolveUserAvatar:
                  (_) async =>
                      const AssetImage('assets/images/characters/Wise.png'),
              onCreateDynamic: canCreateDynamic ? (_) async {} : null,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChat(canCreateDynamic: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('create-dynamic-content')), findsNothing);

    await tester.pumpWidget(buildChat(canCreateDynamic: true));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('create-dynamic-content')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
