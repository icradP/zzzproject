import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test(
    'profile events invalidate direct conversation avatar snapshots',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final data = switch (requestJson['action']) {
            'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
            'get_friends' => [
              {
                'user_id': 'bob',
                'nickname': 'Bob',
                'avatar_url': '/files/bob-avatar',
                'relationship': 'friend',
              },
            ],
            'get_friend_requests' => <Object?>[],
            'get_conversations' => [
              {
                'conversation_id': 'private_me_bob',
                'type': 'private',
                'title': 'Old Bob',
                'participants': ['me', 'bob'],
                'avatar_url': '/files/old-bob-avatar',
              },
            ],
            'get_messages' => <Object?>[],
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
      final initial = await source.getConversation('private_me_bob');
      expect(initial?.title, 'Bob');
      expect(initial?.avatarAssetPath, contains('/files/bob-avatar'));

      final refreshed = source.watchConversations().firstWhere(
        (conversations) =>
            conversations.single.avatarAssetPath?.contains('profile_v=42') ??
            false,
      );
      sockets.single.add(
        jsonEncode({
          'post_type': 'notice',
          'notice_type': 'profile_update',
          'user_id': 'bob',
          'nickname': 'Bob Updated',
          'avatar_url': '/files/bob-avatar',
          'profile_version': 42,
        }),
      );

      final conversation = (await refreshed).single;
      expect(conversation.title, 'Bob Updated');
      expect(conversation.avatarAssetPath, contains('profile_v=42'));
      expect((await source.getUser('bob'))?.displayName, 'Bob Updated');

      final afterMessage = source.watchConversations().firstWhere(
        (conversations) => conversations.single.subtitle == 'Still fresh',
      );
      sockets.single.add(
        jsonEncode({
          'post_type': 'message',
          'message_type': 'private',
          'message_id': 'message-1',
          'conversation_id': 'private_me_bob',
          'sender': {
            'user_id': 'bob',
            'nickname': 'Bob Updated',
            'avatar_url': '/files/bob-avatar',
          },
          'message': [
            {
              'type': 'text',
              'data': {'text': 'Still fresh'},
            },
          ],
          'timestamp': 43,
        }),
      );
      expect(
        (await afterMessage).single.avatarAssetPath,
        contains('profile_v=42'),
      );
    },
  );
}
