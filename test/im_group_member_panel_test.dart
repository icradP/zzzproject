import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_member_grid.dart';

void main() {
  testWidgets('group members expand below the chat header', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final participantIds = List.generate(40, (index) => 'member-$index');
    String? tappedMemberId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImChatRoomView(
            conversation: ImConversation(
              id: 'group-layout-test',
              type: ImConversationType.group,
              title: 'Layout test',
              participantIds: participantIds,
            ),
            messages: const [],
            onSend: (_) async {},
            resolveUserName: (userId) async => userId,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
            onMemberTap: (userId) => tappedMemberId = userId,
          ),
        ),
      ),
    );

    expect(find.byType(ImMemberGrid), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('group-member-reveal'))).height,
      0,
    );

    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();

    final memberPanel = tester.getRect(find.byType(ImMemberGrid));
    final emptyMessage = tester.getRect(
      find.text('Say hello to start the chat.'),
    );
    expect(memberPanel.top, lessThan(emptyMessage.top));
    expect(memberPanel.height, lessThanOrEqualTo(220));
    await tester.tap(find.byKey(const ValueKey('group-member-member-0')));
    expect(tappedMemberId, 'member-0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('group composer completes members and emits a native mention', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(390, 720)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    ImComposedText? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImChatRoomView(
            conversation: const ImConversation(
              id: 'group-mentions',
              type: ImConversationType.group,
              title: 'Mentions',
              participantIds: ['me', 'user-bob', 'user-alice'],
            ),
            messages: const [],
            onSend: (_) async {},
            onSendComposed: (message) async => sent = message,
            resolveUserName:
                (userId) async => switch (userId) {
                  'user-bob' => 'Bob',
                  'user-alice' => 'Alice',
                  _ => 'Me',
                },
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final composer = find.byType(TextField).last;
    await tester.enterText(composer, '@bo');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('mention-suggestions')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mention-candidate-user-bob')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mention-candidate-user-alice')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('mention-candidate-user-bob')));
    await tester.pump();
    final field = tester.widget<TextField>(composer);
    await tester.enterText(composer, '${field.controller!.text}hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(sent?.plainText, '@Bob hello');
    expect(sent?.parts.length, 2);
    expect(sent?.parts.first.mentionedUserId, 'user-bob');
    expect(sent?.parts.last.text, ' hello');
    expect(tester.takeException(), isNull);
  });
}
