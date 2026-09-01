import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test(
    'ZZZ server source preserves replies and applies recall notices',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      Map<String, dynamic>? sentMessageRequest;
      Map<String, dynamic>? recallRequest;
      Map<String, dynamic>? reactionRequest;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'];
          if (action == 'send_message') sentMessageRequest = requestJson;
          if (action == 'recall_message') recallRequest = requestJson;
          if (action == 'react_message') reactionRequest = requestJson;
          final data = switch (action) {
            'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
            'get_friends' => [
              {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
            ],
            'get_conversations' => [
              {
                'conversation_id': 'private_me_bob',
                'type': 'private',
                'title': 'Bob',
                'participants': ['me', 'bob'],
                'unread_count': 0,
                'last_timestamp': 200,
              },
            ],
            'get_messages' => [
              _messageJson(id: 'message-1', text: 'Original', timestamp: 100),
              _messageJson(
                id: 'message-2',
                text: 'Reply body',
                timestamp: 200,
                replyTo: 'message-1',
              ),
            ],
            'send_message' => {'message_id': 'message-3'},
            'react_message' => {
              'message_id': 'message-1',
              'emoji_id': '76',
              'reactions': [
                {'emoji_id': '76', 'count': 1},
              ],
              'my_reactions': ['76'],
            },
            _ => <String, Object?>{},
          };
          socket.add(
            jsonEncode({
              'status': 'ok',
              'retcode': 0,
              'data': data,
              'echo': requestJson['echo'],
            }),
          );
        });
      });

      final source = ZzzServerSource(
        config: ZzzServerConfig(
          serverUrl: 'ws://127.0.0.1:${server.port}',
          selfId: 'me',
        ),
        allowReconnect: false,
      );
      addTearDown(() async {
        source.disconnect();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });

      await source.connect();
      final initial = await source.watchMessages('private_me_bob').first;
      expect(initial, hasLength(2));
      expect(initial.last.replyToMessageId, 'message-1');
      expect(initial.last.text, 'Reply body');
      expect(initial.last.segments?.first.type, 'reply');

      final sent = await source.sendTextMessage(
        conversationId: 'private_me_bob',
        text: 'Another reply',
        replyToMessageId: 'message-2',
      );
      expect(sent.replyToMessageId, 'message-2');
      final sentSegments =
          (sentMessageRequest!['params'] as Map<String, dynamic>)['message']
              as List<dynamic>;
      expect(sentSegments.first['type'], 'reply');
      expect(sentSegments.first['data']['id'], 'message-2');

      const sticker = ImStickerReference(
        packId: 'zzz-core',
        assetId: 'corin-01',
        version: 1,
      );
      final sentSticker = await source.sendStickerMessage(
        conversationId: 'private_me_bob',
        sticker: sticker,
      );
      final stickerSegments =
          (sentMessageRequest!['params'] as Map<String, dynamic>)['message']
              as List<dynamic>;
      expect(stickerSegments.single['type'], 'sticker');
      expect(stickerSegments.single['data'], sticker.toSegmentData());
      expect(sentSticker.kind, ImMessageKind.face);
      expect(sentSticker.segments?.single.type, 'sticker');
      expect(sentSticker.text, '[表情]');

      final recalledFuture = source
          .watchMessages('private_me_bob')
          .skip(1)
          .firstWhere(
            (messages) => messages.any(
              (message) => message.id == 'message-2' && message.recalled,
            ),
          )
          .timeout(const Duration(seconds: 2));
      sockets.single.add(
        jsonEncode({
          'post_type': 'notice',
          'notice_type': 'friend_recall',
          'conversation_id': 'private_me_bob',
          'message_id': 'message-2',
          'user_id': 'bob',
          'operator_id': 'bob',
        }),
      );
      final recalled = await recalledFuture;
      expect(
        recalled.singleWhere((message) => message.id == 'message-2').recalled,
        isTrue,
      );

      await source.recallMessage(
        conversationId: 'private_me_bob',
        messageId: 'message-3',
      );
      expect(
        (recallRequest!['params'] as Map<String, dynamic>)['message_id'],
        'message-3',
      );

      final reactions = await source.reactToMessage(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        emojiId: '76',
      );
      expect(reactions.single.emojiId, '76');
      expect(reactions.single.count, 1);
      expect(reactions.single.reactedByMe, isTrue);
      expect(
        (reactionRequest!['params'] as Map<String, dynamic>)['emoji_id'],
        '76',
      );
    },
  );

  test('ZZZ server source sends structured M4 request payloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final requests = <Map<String, dynamic>>[];
    var sentMessageId = 0;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(requestJson);
        final action = requestJson['action'];
        final data = switch (action) {
          'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
          'get_friends' => [
            {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
          ],
          'get_friend_requests' => <Object?>[],
          'get_conversations' => [
            {
              'conversation_id': 'private_me_bob',
              'type': 'private',
              'title': 'Bob',
              'participants': ['me', 'bob'],
              'unread_count': 0,
              'last_timestamp': 200,
            },
          ],
          'get_messages' => <Object?>[],
          'create_forward' => {'forward_id': 'forward-1'},
          'send_message' => {'message_id': 'sent-${++sentMessageId}'},
          _ => <String, Object?>{},
        };
        socket.add(
          jsonEncode({
            'status': 'ok',
            'retcode': 0,
            'data': data,
            'echo': requestJson['echo'],
          }),
        );
      });
    });

    final source = ZzzServerSource(
      config: ZzzServerConfig(
        serverUrl: 'ws://127.0.0.1:${server.port}',
        selfId: 'me',
      ),
      allowReconnect: false,
    );
    addTearDown(() async {
      source.disconnect();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });

    await source.connect();
    requests.clear();

    await source.sendLinkMessage(
      conversationId: 'private_me_bob',
      link: ImLinkShare(
        url: Uri.parse('https://example.test/docs'),
        title: 'Documentation',
      ),
    );
    await source.sendLocationMessage(
      conversationId: 'private_me_bob',
      location: const ImLocationShare(
        name: 'People\'s Square',
        latitude: 31.2304,
        longitude: 121.4737,
      ),
    );
    await source.sendPoke(
      conversationId: 'private_me_bob',
      targetUserId: 'bob',
    );
    await source.forwardMessages(
      conversationId: 'private_me_bob',
      messages: [
        ImMessage(
          id: 'source-message-1',
          conversationId: 'private_me_bob',
          senderId: 'bob',
          text: 'Snapshot me',
          sentAt: DateTime(2026),
        ),
      ],
    );

    final sendRequests =
        requests
            .where((request) => request['action'] == 'send_message')
            .toList();
    expect(sendRequests, hasLength(4));
    expect(_sentSegments(sendRequests[0]), [
      {
        'type': 'share',
        'data': {'url': 'https://example.test/docs', 'title': 'Documentation'},
      },
    ]);
    expect(_sentSegments(sendRequests[1]), [
      {
        'type': 'location',
        'data': {'name': 'People\'s Square', 'lat': 31.2304, 'lon': 121.4737},
      },
    ]);
    expect(_sentSegments(sendRequests[2]), [
      {
        'type': 'poke',
        'data': {'target_id': 'bob'},
      },
    ]);
    expect(_sentSegments(sendRequests[3]), [
      {
        'type': 'forward',
        'data': {'id': 'forward-1', 'count': 1},
      },
    ]);

    final createForward = requests.singleWhere(
      (request) => request['action'] == 'create_forward',
    );
    expect(createForward['params'], {
      'conversation_id': 'private_me_bob',
      'message_ids': ['source-message-1'],
    });
  });
}

List<dynamic> _sentSegments(Map<String, dynamic> request) {
  final params = request['params'] as Map<String, dynamic>;
  return params['message'] as List<dynamic>;
}

Map<String, Object?> _messageJson({
  required String id,
  required String text,
  required int timestamp,
  String? replyTo,
}) {
  return {
    'message_id': id,
    'conversation_id': 'private_me_bob',
    'sender': {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
    'message': [
      if (replyTo != null)
        {
          'type': 'reply',
          'data': {'id': replyTo},
        },
      {
        'type': 'text',
        'data': {'text': text},
      },
    ],
    'timestamp': timestamp,
    'status': 'sent',
    'read_count': 0,
    'recipient_count': 1,
  };
}
