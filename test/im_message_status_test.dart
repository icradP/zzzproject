import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/models/im_models.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_message_bubble.dart';

void main() {
  testWidgets('own message bubbles expose delivery status', (tester) async {
    final cases = <ImMessageStatus, String>{
      ImMessageStatus.sending: '发送中',
      ImMessageStatus.sent: '已发送',
      ImMessageStatus.delivered: '已送达',
      ImMessageStatus.read: '已读',
      ImMessageStatus.failed: '发送失败',
    };

    for (final entry in cases.entries) {
      await _pumpBubble(tester, status: entry.key);
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
    );

    expect(find.text('已读 12/128'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpBubble(
  WidgetTester tester, {
  required ImMessageStatus status,
  int readCount = 0,
  int recipientCount = 1,
  double width = 320,
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
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
