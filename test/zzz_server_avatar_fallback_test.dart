import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test(
    'ZZZ server applies varied fallback avatars to empty profiles',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'];
          final data = switch (action) {
            'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
            'get_users' => [
              {'user_id': 'smoke-alice', 'nickname': 'Alice', 'avatar_url': ''},
              {'user_id': 'smoke-bob', 'nickname': 'Bob', 'avatar_url': ''},
            ],
            'get_conversations' => [
              {
                'conversation_id': 'dm_me_smoke-alice',
                'type': 'private',
                'title': 'Alice',
                'participants': ['me', 'smoke-alice'],
                'avatar_url': '',
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
        avatarResolver: AppAssets.fallbackAvatarForId,
      );
      addTearDown(() async {
        source.disconnect();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });

      await source.connect();
      final alice = await source.getUser('smoke-alice');
      final bob = await source.getUser('smoke-bob');
      final conversation = await source.getConversation('dm_me_smoke-alice');

      expect(
        alice?.avatarAssetPath,
        AppAssets.fallbackAvatarForId('smoke-alice'),
      );
      expect(bob?.avatarAssetPath, AppAssets.fallbackAvatarForId('smoke-bob'));
      expect(alice?.avatarAssetPath, isNot(bob?.avatarAssetPath));
      expect(conversation?.avatarAssetPath, alice?.avatarAssetPath);
    },
  );
}
