import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';
import 'package:zzzproject/src/im/adapters/nonebot/nonebot_mapper.dart';
import 'package:zzzproject/src/im/widgets/im_chat_room_view/im_message_bubble.dart';

void main() {
  test('dynamic content round-trips its schema and ignores unknown fields', () {
    final content = ImDynamicContent.fromJson({
      'type': 'dynamic_content',
      'id': 'diagnosis-1',
      'version': '1.0',
      'source': 'ai',
      'unknown': 'ignored',
      'tree': {
        'id': 'root',
        'type': 'column',
        'children': [
          {
            'id': 'title',
            'type': 'text',
            'props': {'text': 'Network check'},
          },
          {
            'id': 'retry',
            'type': 'button',
            'props': {'text': 'Retry'},
            'events': {
              'click': {'action': 'retry'},
            },
          },
        ],
      },
    });

    final decoded = ImDynamicContent.fromJson(content.toJson());
    expect(decoded.id, 'diagnosis-1');
    expect(decoded.source, ImDynamicContentSource.ai);
    expect(decoded.tree.findById('retry')?.events['click']?['action'], 'retry');
    expect(decoded.toJson()['unknown'], isNull);
  });

  test('segment envelope supports nested schema and transport metadata', () {
    final content = ImDynamicContent.fromSegmentData({
      'id': 'nested-1',
      'source': 'server',
      'schema': {
        'version': '1.1',
        'tree': {
          'id': 'root',
          'type': 'text',
          'props': {'text': 'Ready'},
        },
      },
    });
    expect(content.id, 'nested-1');
    expect(content.version, '1.1');
    expect(content.source, ImDynamicContentSource.server);
  });

  test(
    'dynamic content has an explicit message kind in both segment adapters',
    () {
      final segment = OneBotMessageSegment(
        type: 'dynamic_content',
        data: {
          'id': 'kind-1',
          'version': '1.0',
          'tree': {'id': 'root', 'type': 'text'},
        },
      );
      expect(oneBotSegmentToMessageKind(segment), ImMessageKind.dynamicContent);
    },
  );

  test(
    'validator rejects unsafe shape and reports unknown components as warnings',
    () {
      final content = ImDynamicContent(
        id: 'invalid',
        version: '1.0',
        source: ImDynamicContentSource.ai,
        tree: const ImDynamicNode(
          id: 'root',
          type: 'future_component',
          props: {'text': 'x'},
          children: [
            ImDynamicNode(id: 'duplicate', type: 'text'),
            ImDynamicNode(id: 'duplicate', type: 'text'),
          ],
        ),
      );
      final result = const ImDynamicSchemaValidator().validate(content);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((issue) => issue.message.contains('unique')),
        isTrue,
      );
      expect(
        result.warnings.any((issue) => issue.message.contains('unknown')),
        isTrue,
      );
    },
  );

  testWidgets(
    'dynamic button renders inside the shared message bubble and emits an event',
    (tester) async {
      ImDynamicEvent? event;
      final message = ImMessage(
        id: 'message-1',
        conversationId: 'conversation-1',
        senderId: 'fairy',
        text: 'Ready',
        sentAt: DateTime(2026),
        segments: [
          OneBotMessageSegment(
            type: 'dynamic_content',
            data: {
              'id': 'content-1',
              'version': '1.0',
              'source': 'ai',
              'tree': {
                'id': 'root',
                'type': 'column',
                'children': [
                  {
                    'id': 'title',
                    'type': 'text',
                    'props': {'text': 'Plan'},
                  },
                  {
                    'id': 'run',
                    'type': 'button',
                    'props': {'text': 'Run'},
                    'events': {
                      'click': {'action': 'run_plan'},
                    },
                  },
                ],
              },
            },
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImMessageBubble(
              message: message,
              senderName: 'Fairy',
              avatar: MemoryImage(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              ),
              showSenderName: false,
              onDynamicEvent: (value) => event = value,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Plan'), findsOneWidget);
      await tester.tap(find.text('Run'));
      expect(event?.messageId, 'message-1');
      expect(event?.contentId, 'content-1');
      expect(event?.nodeId, 'run');
      expect(event?.action, 'run_plan');
    },
  );
}
