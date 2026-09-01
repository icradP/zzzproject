import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onebot_flutter/onebot_flutter.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_message_bubble.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_voice_recorder_panel.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_attach_radial_menu.dart';

void main() {
  const conversation = ImConversation(
    id: 'private-me-bob',
    type: ImConversationType.direct,
    title: 'Bob',
    participantIds: ['me', 'bob'],
  );

  testWidgets('link and location segments render structured cards', (
    tester,
  ) async {
    final messages = [
      ImMessage(
        id: 'link-1',
        conversationId: conversation.id,
        senderId: 'me',
        text: 'example.test',
        sentAt: DateTime(2026),
        kind: ImMessageKind.share,
        isMine: true,
        segments: [
          OneBotMessageSegment(
            type: 'share',
            data: const {
              'url': 'https://example.test/docs',
              'title': 'Documentation',
            },
          ),
        ],
      ),
      ImMessage(
        id: 'location-1',
        conversationId: conversation.id,
        senderId: 'bob',
        text: 'People\'s Square',
        sentAt: DateTime(2026),
        kind: ImMessageKind.location,
        segments: [
          OneBotMessageSegment(
            type: 'location',
            data: const {
              'name': "People's Square",
              'lat': 31.2304,
              'lon': 121.4737,
            },
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Column(
            children: [
              for (final message in messages)
                ImMessageBubble(
                  message: message,
                  senderName: message.senderId,
                  avatar: const AssetImage(AppAssets.characterWise),
                  showSenderName: false,
                ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('message-link-card')), findsOneWidget);
    expect(find.text('Documentation'), findsOneWidget);
    expect(find.text('example.test'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-location-card')), findsOneWidget);
    expect(find.text("People's Square"), findsOneWidget);
    expect(find.text('31.23040, 121.47370'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('location panel supports name-only sharing', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    ImLocationShare? shared;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ImChatRoomView(
            conversation: conversation,
            messages: const [],
            onSend: (_) async {},
            onLocation: (location) async => shared = location,
            resolveUserName: (id) async => id,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ImCircleButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('location-share-panel')), findsOneWidget);

    final nameField = find.descendant(
      of: find.byKey(const ValueKey('location-name-field')),
      matching: find.byType(TextField),
    );
    await tester.enterText(nameField, 'Home');
    await tester.tap(find.byKey(const ValueKey('send-shared-location')));
    await tester.pumpAndSettle();

    expect(shared?.name, 'Home');
    expect(shared?.hasCoordinates, isFalse);
    expect(find.byKey(const ValueKey('location-share-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('message menu selects a combined forward and exposes poke', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 760)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final first = ImMessage(
      id: 'first',
      conversationId: conversation.id,
      senderId: 'bob',
      text: 'First message',
      sentAt: DateTime(2026),
    );
    final second = ImMessage(
      id: 'second',
      conversationId: conversation.id,
      senderId: 'me',
      text: 'Second message',
      sentAt: DateTime(2026, 1, 1, 0, 1),
      isMine: true,
    );
    List<ImMessage>? forwarded;
    String? pokeTarget;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ImChatRoomView(
            conversation: conversation,
            messages: [first, second],
            onSend: (_) async {},
            onForward: (messages) async => forwarded = messages,
            onPoke: (target) async => pokeTarget = target,
            resolveUserName: (id) async => id,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('First message'));
    await tester.pumpAndSettle();
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('Poke'), findsOneWidget);
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('forward-message-panel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('forward-choice-second')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('confirm-forward-selection')));
    await tester.pumpAndSettle();
    expect(forwarded?.map((message) => message.id), ['first', 'second']);

    await tester.longPress(find.text('First message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Poke'));
    await tester.pumpAndSettle();
    expect(pokeTarget, 'bob');
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice recorder advertises enforced limits before permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: const ImVoiceRecorderPanel()),
    );
    expect(find.byKey(const ValueKey('voice-recorder-panel')), findsOneWidget);
    expect(find.text('Up to 2 minutes / 10 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('start-voice-recording')), findsOneWidget);
  });
}
