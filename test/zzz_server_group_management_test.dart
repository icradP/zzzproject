import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('ZZZ source parses roles and sends group management actions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final actions = <Map<String, dynamic>>[];
    var memberIDs = <String>['me', 'bob', 'carol'];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        actions.add(requestJson);
        final action = requestJson['action'];
        final params = Map<String, dynamic>.from(
          requestJson['params'] as Map? ?? const {},
        );
        if (action == 'group_invite') {
          memberIDs =
              {
                ...memberIDs,
                ...params['members'] as List,
              }.cast<String>().toList();
        }
        if (action == 'group_kick') {
          memberIDs.remove('${params['user_id']}');
        }
        final data = switch (action) {
          'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
          'get_friends' => [
            {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': '/files/bob'},
            {'user_id': 'carol', 'nickname': 'Carol', 'avatar_url': ''},
            {'user_id': 'dave', 'nickname': 'Dave', 'avatar_url': ''},
            {'user_id': 'eve', 'nickname': 'Eve', 'avatar_url': ''},
          ],
          'get_conversations' => [
            {
              'conversation_id': 'group_team',
              'type': 'group',
              'title': 'Team',
              'participants': memberIDs,
              'avatar_url': '/files/team',
            },
          ],
          'get_messages' => <Object?>[],
          'get_group_info' => {
            'group_id': 'group_team',
            'name': 'Team',
            'avatar_url': '/files/team',
            'owner_id': 'me',
            'member_count': memberIDs.length,
            'members': [
              for (final userID in memberIDs)
                {
                  'user_id': userID,
                  'nickname': userID[0].toUpperCase() + userID.substring(1),
                  'avatar_url': userID == 'bob' ? '/files/bob' : '',
                  'role':
                      userID == 'me'
                          ? 'owner'
                          : userID == 'bob'
                          ? 'admin'
                          : 'member',
                  'joined_at': 1700000000,
                },
            ],
          },
          'group_invite' => {'added_members': params['members']},
          'group_kick' => <String, Object?>{},
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
    final details = await source.getGroupDetails('group_team');
    expect(details.currentMember?.role, ImGroupRole.owner);
    expect(details.canInviteMembers, isTrue);
    expect(details.canLeave, isFalse);
    expect(
      details.members.singleWhere((member) => member.user.id == 'bob').role,
      ImGroupRole.admin,
    );
    expect(
      details.members
          .singleWhere((member) => member.user.id == 'bob')
          .user
          .avatarAssetPath,
      'http://127.0.0.1:${server.port}/files/bob',
    );
    expect(details.members.first.joinedAt, isNotNull);

    await source.inviteGroupMembers(
      groupId: 'group_team',
      userIds: const ['dave'],
    );
    expect(
      (actions.lastWhere(
            (request) => request['action'] == 'group_invite',
          )['params']
          as Map<String, dynamic>)['members'],
      ['dave'],
    );
    expect(
      (await source.getGroupDetails(
        'group_team',
      )).members.map((member) => member.user.id),
      contains('dave'),
    );

    await source.removeGroupMember(groupId: 'group_team', userId: 'carol');
    expect(
      (actions.lastWhere(
            (request) => request['action'] == 'group_kick',
          )['params']
          as Map<String, dynamic>)['user_id'],
      'carol',
    );
    expect(
      (await source.getGroupDetails(
        'group_team',
      )).members.map((member) => member.user.id),
      isNot(contains('carol')),
    );

    memberIDs = [...memberIDs, 'eve'];
    final updatedFuture = source
        .watchConversations()
        .firstWhere(
          (conversations) => conversations.any(
            (conversation) =>
                conversation.id == 'group_team' &&
                conversation.participantIds.contains('eve'),
          ),
        )
        .timeout(const Duration(seconds: 2));
    sockets.single.add(
      jsonEncode({
        'post_type': 'notice',
        'notice_type': 'group_increase',
        'group_id': 'group_team',
        'user_id': 'eve',
        'operator_id': 'me',
      }),
    );
    final conversations = await updatedFuture;
    expect(
      conversations
          .singleWhere((conversation) => conversation.id == 'group_team')
          .participantIds,
      contains('eve'),
    );
  });
}
