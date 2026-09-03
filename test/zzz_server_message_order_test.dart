import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test(
    'server millisecond timestamps keep a Fairy reply after the prompt',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final sentPayloads = <Map<String, dynamic>>[];
      var sendCount = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final request = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = request['action'];
          if (action == 'send_message') {
            sendCount++;
            sentPayloads.add(
              Map<String, dynamic>.from(request['params'] as Map),
            );
          }
          final data = switch (action) {
            'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
            'get_friends' => [
              {'user_id': 'fairy', 'nickname': 'Fairy', 'avatar_url': ''},
            ],
            'get_friend_requests' || 'get_messages' => <Object?>[],
            'get_conversations' => [
              {
                'conversation_id': 'private_me_fairy',
                'type': 'private',
                'title': 'Fairy',
                'participants': ['me', 'fairy'],
              },
            ],
            'ensure_conversation' => <String, Object?>{},
            'send_message' => {
              'message_id': 'msg_100',
              'timestamp_ms': 2000100,
            },
            _ => <String, Object?>{},
          };
          socket.add(
            jsonEncode({
              'status': 'ok',
              'retcode': 0,
              'data': data,
              'echo': request['echo'],
            }),
          );
          if (action == 'send_message' && sendCount == 1) {
            Timer(const Duration(milliseconds: 10), () {
              socket.add(
                jsonEncode({
                  'post_type': 'message',
                  'message_type': 'private',
                  'message_id': 'msg_101',
                  'conversation_id': 'private_me_fairy',
                  'sender': {'user_id': 'fairy', 'nickname': 'Fairy'},
                  'message': [
                    {
                      'type': 'text',
                      'data': {'text': 'Reply'},
                    },
                  ],
                  'timestamp': 2000,
                  'timestamp_ms': 2000200,
                }),
              );
            });
          }
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
      final ordered = source
          .watchMessages('private_me_fairy')
          .firstWhere((messages) => messages.length == 2)
          .timeout(const Duration(seconds: 2));
      final sent = await source.sendTextMessage(
        conversationId: 'private_me_fairy',
        text: 'Prompt',
      );

      expect(sent.sentAt.millisecondsSinceEpoch, 2000100);
      expect((await ordered).map((message) => message.id), [
        'msg_100',
        'msg_101',
      ]);

      await source.sendComposedTextMessage(
        conversationId: 'private_me_fairy',
        message: const ImComposedText([
          ImComposedTextPart.mention(userId: 'fairy', label: '@Fairy'),
          ImComposedTextPart.text(' hello'),
        ]),
      );
      expect(sentPayloads.last['message'], [
        {
          'type': 'at',
          'data': {'qq': 'fairy'},
        },
        {
          'type': 'text',
          'data': {'text': ' hello'},
        },
      ]);
    },
  );
}
