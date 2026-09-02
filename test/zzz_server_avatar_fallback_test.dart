import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test(
    'ZZZ server applies varied fallback identities to smoke profiles',
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
            'get_friends' => [
              {
                'user_id': 'smoke-alice',
                'nickname': 'smoke-alice',
                'avatar_url': '',
              },
              {
                'user_id': 'smoke-bob',
                'nickname': 'smoke-bob',
                'avatar_url': '',
              },
            ],
            'search_users' => [
              {
                'user_id': 'smoke-stranger',
                'nickname': 'Stranger',
                'avatar_url': '',
              },
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
        displayNameResolver: AppAssets.displayNameForAccount,
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
      expect(alice?.displayName, 'Alice Zhou');
      expect(bob?.displayName, 'Bo Chen');
      expect(conversation?.avatarAssetPath, alice?.avatarAssetPath);

      final searchResults = await source.searchUsers('stranger');
      expect(searchResults.single.id, 'smoke-stranger');
      final contactIds = (await source.getUsers()).map((user) => user.id);
      expect(contactIds, containsAll(<String>['smoke-alice', 'smoke-bob']));
      expect(contactIds, isNot(contains('smoke-stranger')));
    },
  );

  test('ZZZ groups without uploaded images keep a composite avatar', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        final action = requestJson['action'];
        final group = {
          'group_id': 'group_team',
          'name': 'Team',
          'avatar_url': '',
          'participants': ['me', 'alice', 'bob'],
        };
        final data = switch (action) {
          'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
          'get_friends' => <Object?>[],
          'get_friend_requests' => <Object?>[],
          'get_conversations' => [
            {
              'conversation_id': 'group_team',
              'type': 'group',
              'title': 'Team',
              'participants': ['me', 'alice', 'bob'],
              'avatar_url': '',
            },
          ],
          'get_group_list' => [group],
          'create_group' => group,
          'get_group_info' => {
            ...group,
            'members': [
              for (final id in ['me', 'alice', 'bob'])
                {
                  'user_id': id,
                  'nickname': id,
                  'avatar_url': '',
                  'role': id == 'me' ? 'owner' : 'member',
                },
            ],
          },
          'get_group_announcements' => <Object?>[],
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
    expect(
      (await source.getConversation('group_team'))?.avatarAssetPath,
      isNull,
    );
    expect((await source.getGroupList()).single.avatarAssetPath, isNull);
    expect(
      (await source.getGroupDetails('group_team')).conversation.avatarAssetPath,
      isNull,
    );
    expect(
      (await source.createGroup(
        name: 'Team',
        memberIds: const ['alice', 'bob'],
      )).avatarAssetPath,
      isNull,
    );
  });
}
