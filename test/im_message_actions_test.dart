import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/widgets/zzz_widgets.dart';

void main() {
  testWidgets('message menu copies, replies, and confirms recall', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 700)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final original = ImMessage(
      id: 'message-1',
      conversationId: 'private-me-bob',
      senderId: 'me',
      text: 'Original message',
      sentAt: DateTime.now(),
      isMine: true,
      status: ImMessageStatus.sent,
    );
    String? replyText;
    ImMessage? replyTarget;
    ImMessage? recalled;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ImChatRoomView(
            conversation: const ImConversation(
              id: 'private-me-bob',
              type: ImConversationType.direct,
              title: 'Bob',
              participantIds: ['me', 'bob'],
            ),
            messages: [original],
            onSend: (_) async {},
            onReply: (text, message) async {
              replyText = text;
              replyTarget = message;
            },
            onRecall: (message) async => recalled = message,
            resolveUserName: (userId) async => userId,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Recall'), findsOneWidget);

    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copiedText, 'Original message');

    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-composer-bar')), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'My reply');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(replyText, 'My reply');
    expect(replyTarget?.id, original.id);
    expect(find.byKey(const ValueKey('reply-composer-bar')), findsNothing);

    await tester.longPress(find.text('Original message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();
    expect(find.byType(ZzzModalPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('recall-message-panel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirm-recall-message')));
    await tester.pumpAndSettle();
    expect(recalled?.id, original.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('message actions fit a 220px chat surface', (tester) async {
    tester.view
      ..physicalSize = const Size(220, 560)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final message = ImMessage(
      id: 'narrow-message',
      conversationId: 'private-me-bob',
      senderId: 'me',
      text: 'A long message that still needs to fit on a narrow screen',
      sentAt: DateTime.now(),
      isMine: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ImChatRoomView(
            conversation: const ImConversation(
              id: 'private-me-bob',
              type: ImConversationType.direct,
              title: 'Bob',
              participantIds: ['me', 'bob'],
            ),
            messages: [message],
            onSend: (_) async {},
            onReply: (_, __) async {},
            onRecall: (_) async {},
            resolveUserName: (userId) async => userId,
            resolveUserAvatar:
                (_) async => const AssetImage(AppAssets.characterWise),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text(message.text));
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
