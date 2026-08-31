import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/nonebot/nonebot_models.dart';
import 'package:zzzproject/src/im/adapters/nonebot/nonebot_source.dart';
import 'package:zzzproject/src/im/data/im_storage_config.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('NoneBot maps numeric member IDs and routes kicks', () async {
    final temp = await Directory.systemTemp.createTemp('zzz-nonebot-group-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final actions = <Map<String, dynamic>>[];
    var members = <Map<String, Object?>>[
      {
        'group_id': 9001,
        'user_id': 10001,
        'nickname': 'Owner',
        'card': 'Owner card',
        'role': 'owner',
        'join_time': 1700000000,
      },
      {
        'group_id': 9001,
        'user_id': 10002,
        'nickname': 'Admin',
        'role': 'admin',
        'join_time': 1700000001,
      },
      {
        'group_id': 9001,
        'user_id': 10003,
        'nickname': 'Member',
        'role': 'member',
        'join_time': 1700000002,
      },
    ];
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
        if (action == 'set_group_kick') {
          members =
              members
                  .where(
                    (member) =>
                        '${member['user_id']}' != '${params['user_id']}',
                  )
                  .toList();
        }
        final data = switch (action) {
          'get_login_info' => {'user_id': 10001, 'nickname': 'Owner'},
          'get_friend_list' => <Object?>[],
          'get_group_list' => [
            {
              'group_id': 9001,
              'group_name': 'Numeric group',
              'member_count': members.length,
              'max_member_count': 200,
            },
          ],
          'get_group_member_list' => members,
          _ => null,
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

    final source = NoneBotSource.connected(
      config: OneBotConfig(
        selfId: '10001',
        wsEndpoint: 'ws://127.0.0.1:${server.port}',
      ),
    );
    source.storageConfig = ImStorageConfig(basePath: temp.path);
    addTearDown(() async {
      source.disconnect();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    await source.connect();
    final group = (await source.getGroupList()).single;
    expect(group.id, 'group_9001');
    final details = await source.getGroupDetails(group.id);
    expect(details.currentUserId, '10001');
    expect(details.currentMember?.role, ImGroupRole.owner);
    expect(details.supportsInvites, isFalse);
    expect(details.supportsMemberRemoval, isTrue);
    expect(details.canLeave, isFalse);
    expect(details.members.map((member) => member.user.id), [
      '10001',
      '10002',
      '10003',
    ]);
    expect(details.members[1].role, ImGroupRole.admin);
    expect(details.members[2].role, ImGroupRole.member);

    await source.removeGroupMember(groupId: group.id, userId: '10003');
    final kick = actions.lastWhere(
      (request) => request['action'] == 'set_group_kick',
    );
    expect((kick['params'] as Map<String, dynamic>)['group_id'], '9001');
    expect((kick['params'] as Map<String, dynamic>)['user_id'], '10003');
    expect(
      (await source.getGroupDetails(
        group.id,
      )).members.map((member) => member.user.id),
      isNot(contains('10003')),
    );
  });
}
