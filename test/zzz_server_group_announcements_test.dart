import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test(
    'ZZZ source manages group announcement history and read state',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final actions = <String>[];
      final now = DateTime.utc(2026, 9, 1, 10);
      final announcements = <Map<String, Object?>>[
        _announcement('announcement_1', 'Initial notice', now, isPinned: true),
      ];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = '${requestJson['action']}';
          final params = Map<String, dynamic>.from(
            requestJson['params'] as Map? ?? const {},
          );
          actions.add(action);
          Object? data;
          switch (action) {
            case 'auth':
              data = {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''};
            case 'get_friends':
              data = <Object?>[];
            case 'get_conversations':
              data = [
                {
                  'conversation_id': 'group_team',
                  'type': 'group',
                  'title': 'Team',
                  'participants': ['me'],
                  'notification_level': 'normal',
                },
              ];
            case 'get_messages':
              data = <Object?>[];
            case 'get_group_info':
              data = {
                'group_id': 'group_team',
                'name': 'Team',
                'owner_id': 'me',
                'members': [
                  {'user_id': 'me', 'nickname': 'Me', 'role': 'owner'},
                ],
              };
            case 'get_group_announcements':
              data = announcements;
            case 'create_group_announcement':
              final created = _announcement(
                'announcement_2',
                '${params['content']}',
                now.add(const Duration(minutes: 1)),
                isPinned: params['is_pinned'] == true,
                isRead: true,
              );
              announcements.insert(0, created);
              data = created;
            case 'update_group_announcement':
              final index = announcements.indexWhere(
                (value) =>
                    value['announcement_id'] == params['announcement_id'],
              );
              announcements[index] = {
                ...announcements[index],
                'content': params['content'],
                'is_pinned': params['is_pinned'],
                'updated_at':
                    now.add(const Duration(minutes: 2)).toIso8601String(),
              };
              data = announcements[index];
            case 'mark_group_announcement_read':
              final index = announcements.indexWhere(
                (value) =>
                    value['announcement_id'] == params['announcement_id'],
              );
              announcements[index] = {...announcements[index], 'is_read': true};
              data = <String, Object?>{};
            case 'delete_group_announcement':
              announcements.removeWhere(
                (value) =>
                    value['announcement_id'] == params['announcement_id'],
              );
              data = <String, Object?>{};
            default:
              data = <String, Object?>{};
          }
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
      var details = await source.getGroupDetails('group_team');
      expect(details.announcements.single.content, 'Initial notice');
      expect(details.announcements.single.isPinned, isTrue);
      expect(details.announcements.single.isRead, isFalse);

      final created = await source.createGroupAnnouncement(
        groupId: 'group_team',
        content: 'Second notice',
        isPinned: false,
      );
      expect(created.id, 'announcement_2');
      final updated = await source.updateGroupAnnouncement(
        announcementId: created.id,
        content: 'Revised notice',
        isPinned: true,
      );
      expect(updated.content, 'Revised notice');
      expect(updated.isPinned, isTrue);
      await source.markGroupAnnouncementRead('announcement_1');
      details = await source.getGroupDetails('group_team');
      expect(
        details.announcements
            .singleWhere((value) => value.id == 'announcement_1')
            .isRead,
        isTrue,
      );
      await source.deleteGroupAnnouncement(created.id);
      expect(await source.getGroupAnnouncements('group_team'), hasLength(1));
      expect(
        actions,
        containsAll([
          'create_group_announcement',
          'update_group_announcement',
          'mark_group_announcement_read',
          'delete_group_announcement',
        ]),
      );
    },
  );
}

Map<String, Object?> _announcement(
  String id,
  String content,
  DateTime timestamp, {
  bool isPinned = false,
  bool isRead = false,
}) => {
  'announcement_id': id,
  'group_id': 'group_team',
  'content': content,
  'author_id': 'me',
  'is_pinned': isPinned,
  'is_read': isRead,
  'created_at': timestamp.toIso8601String(),
  'updated_at': timestamp.toIso8601String(),
};
