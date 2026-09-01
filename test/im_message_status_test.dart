import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/src/im/data/im_message_display_config.dart';
import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ImMessageDisplayConfig.load();
  });

  testWidgets('message delivery status is hidden by default', (tester) async {
    final cases = <ImMessageStatus, String>{
      ImMessageStatus.sending: '发送中',
      ImMessageStatus.sent: '已发送',
      ImMessageStatus.delivered: '已送达',
      ImMessageStatus.read: '已读',
      ImMessageStatus.failed: '发送失败',
    };

    for (final entry in cases.entries) {
      await _pumpBubble(tester, status: entry.key);
      expect(find.text(entry.value), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('own message bubbles expose enabled delivery status', (
    tester,
  ) async {
    final cases = <ImMessageStatus, String>{
      ImMessageStatus.sending: '发送中',
      ImMessageStatus.sent: '已发送',
      ImMessageStatus.delivered: '已送达',
      ImMessageStatus.read: '已读',
      ImMessageStatus.failed: '发送失败',
    };

    for (final entry in cases.entries) {
      await _pumpBubble(tester, status: entry.key, showMessageStatus: true);
      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('group read count fits a narrow chat surface', (tester) async {
    await _pumpBubble(
      tester,
      status: ImMessageStatus.read,
      readCount: 12,
      recipientCount: 128,
      width: 220,
      showMessageStatus: true,
    );

    expect(find.text('已读 12/128'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('message status preference defaults off and persists changes', () async {
    expect(ImMessageDisplayConfig.showsMessageStatus, isFalse);

    await ImMessageDisplayConfig.setShowMessageStatus(true);
    await ImMessageDisplayConfig.load();

    expect(ImMessageDisplayConfig.showsMessageStatus, isTrue);
  });

  testWidgets('open chat responds immediately to the display preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: ImChatRoomView(
            conversation: const ImConversation(
              id: 'conversation-1',
              type: ImConversationType.direct,
              title: 'Belle',
              participantIds: ['me', 'belle'],
            ),
            messages: [
              ImMessage(
                id: 'message-delivered',
                conversationId: 'conversation-1',
                senderId: 'me',
                text: 'Live preference sample',
                sentAt: DateTime(2026, 9, 1, 12, 30),
                status: ImMessageStatus.delivered,
                isMine: true,
              ),
            ],
            onSend: (_) async {},
            resolveUserName: (userId) async => userId,
            resolveUserAvatar:
                (_) async => const AssetImage('assets/characters/Wise.png'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('已送达'), findsNothing);

    await ImMessageDisplayConfig.setShowMessageStatus(true);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('已送达'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpBubble(
  WidgetTester tester, {
  required ImMessageStatus status,
  int readCount = 0,
  int recipientCount = 1,
  double width = 320,
  bool showMessageStatus = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ImMessageBubble(
              message: ImMessage(
                id: 'message-${status.name}',
                conversationId: 'conversation-1',
                senderId: 'me',
                text: 'Status sample message',
                sentAt: DateTime(2026, 9, 1, 12, 30),
                status: status,
                readCount: readCount,
                recipientCount: recipientCount,
                isMine: true,
              ),
              senderName: 'Me',
              avatar: const AssetImage('assets/characters/Wise.png'),
              showSenderName: false,
              showMessageStatus: showMessageStatus,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
