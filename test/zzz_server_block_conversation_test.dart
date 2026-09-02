import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test(
    'blocking a user removes their direct conversation and messages',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var blocked = false;
      Map<String, dynamic>? blockRequest;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final request = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = request['action'];
          if (action == 'set_user_blocked') {
            blocked = true;
            blockRequest = request;
          }
          final data = switch (action) {
            'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
            'get_friends' when blocked => <Object?>[],
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
                'last_timestamp': 100,
              },
            ],
            'get_messages' => [
              {
                'message_id': 'msg_1',
                'conversation_id': 'private_me_bob',
                'sender': {'user_id': 'bob', 'nickname': 'Bob'},
                'message': [
                  {
                    'type': 'text',
                    'data': {'text': 'Old message'},
                  },
                ],
                'timestamp': 100,
              },
            ],
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
      expect(await source.watchConversations().first, hasLength(1));
      expect(await source.watchMessages('private_me_bob').first, hasLength(1));
      final conversationsCleared = source.watchConversations().firstWhere(
        (conversations) => conversations.isEmpty,
      );
      final messagesCleared = source
          .watchMessages('private_me_bob')
          .firstWhere((messages) => messages.isEmpty);

      await source.setUserBlocked(userId: 'bob', blocked: true);

      expect(await conversationsCleared, isEmpty);
      expect(await messagesCleared, isEmpty);
      expect(blockRequest?['params'], {'user_id': 'bob', 'blocked': true});
    },
  );
}
