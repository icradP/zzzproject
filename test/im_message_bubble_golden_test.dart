import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/zzz_im_chat.dart';

void main() {
  testWidgets('legacy and dynamic bubbles keep a stable visual baseline', (
    tester,
  ) async {
    final repository = MockImRepository();
    final pushManager = NoOpImPushManager();
    addTearDown(repository.dispose);
    addTearDown(pushManager.dispose);

    tester.view
      ..physicalSize = const Size(640, 1200)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final avatar = MemoryImage(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    final localImage =
        '${Directory.current.path}/assets/icons/zzz_agent_profile_icon.png';
    final messages = [
      ImMessage(
        id: 'golden-text',
        conversationId: 'golden',
        senderId: 'alice',
        text: 'Hello from the current message runtime',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
      ),
      ImMessage(
        id: 'golden-image',
        conversationId: 'golden',
        senderId: 'alice',
        text: '[Image]',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.image,
        mediaPath: localImage,
      ),
      ImMessage(
        id: 'golden-video',
        conversationId: 'golden',
        senderId: 'alice',
        text: 'release.mp4',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.video,
        mediaPath: localImage,
        mediaSize: 2 * 1024 * 1024,
      ),
      ImMessage(
        id: 'golden-audio',
        conversationId: 'golden',
        senderId: 'alice',
        text: 'Voice message',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.record,
        mediaSize: 32 * 1024,
        mediaDuration: const Duration(seconds: 12),
      ),
      ImMessage(
        id: 'golden-file',
        conversationId: 'golden',
        senderId: 'alice',
        text: 'report.pdf',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.file,
        mediaSize: 480 * 1024,
      ),
      ImMessage(
        id: 'golden-share',
        conversationId: 'golden',
        senderId: 'alice',
        text: 'Shared link',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.share,
        segments: const [
          OneBotMessageSegment(
            type: 'share',
            data: {
              'url': 'https://icrad.ltd/docs',
              'title': 'ZZZ documentation',
            },
          ),
        ],
      ),
      ImMessage(
        id: 'golden-system',
        conversationId: 'golden',
        senderId: 'system',
        text: 'Alice joined the conversation',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        kind: ImMessageKind.system,
      ),
      ImMessage(
        id: 'golden-dynamic',
        conversationId: 'golden',
        senderId: 'fairy',
        text: 'Network diagnosis',
        sentAt: DateTime.utc(2026, 9, 8, 12, 0),
        segments: [
          OneBotMessageSegment(
            type: 'dynamic_content',
            data: {
              'id': 'golden-dynamic-card',
              'version': '1.0',
              'source': 'ai',
              'tree': {
                'id': 'root',
                'type': 'card',
                'children': [
                  {
                    'id': 'title',
                    'type': 'text',
                    'props': {'text': 'Network diagnosis'},
                  },
                  {
                    'id': 'state',
                    'type': 'status',
                    'props': {'text': 'Completed'},
                  },
                  {
                    'id': 'action',
                    'type': 'button',
                    'props': {'text': 'Run again'},
                    'events': {
                      'click': {'action': 'retry'},
                    },
                  },
                ],
              },
              'fallback': {'type': 'text', 'content': 'Network diagnosis'},
            },
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Color(0xFF101216),
          fontFamily: 'Arial',
        ),
        home: ImScope(
          repository: repository,
          interactions: const NoOpImInteractionHandler(),
          nsfwChecker: StubNsfwChecker(),
          nsfwStateCache: NsfwStateCache(),
          pushManager: pushManager,
          onConnectionsChanged: () async {},
          child: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('message-bubble-golden'),
              child: SizedBox(
                width: 640,
                height: 1200,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final message in messages) ...[
                        ImMessageBubble(
                          message: message,
                          senderName: message.senderId,
                          avatar: avatar,
                          showSenderName: false,
                          hideAvatar: true,
                          hideTimestamp: true,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('message-bubble-golden')),
      matchesGoldenFile('goldens/im_message_bubbles.png'),
    );
  });
}
