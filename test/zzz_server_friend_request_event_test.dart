import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test('friend request events refresh the live request stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    var pending = false;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        final data = switch (requestJson['action']) {
          'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
          'get_friends' || 'get_conversations' => <Object?>[],
          'get_friend_requests' when pending => [
            {
              'flag': 'request-1',
              'from_user': {
                'user_id': 'bob',
                'nickname': 'Bob',
                'avatar_url': '',
              },
              'to_user': {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
              'comment': 'Hello',
              'status': 'pending',
              'created_at': 42,
            },
          ],
          'get_friend_requests' => <Object?>[],
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

    String? notificationTitle;
    String? notificationBody;
    final source = ZzzServerSource(
      config: ZzzServerConfig(
        serverUrl: 'ws://127.0.0.1:${server.port}',
        selfId: 'me',
      ),
      allowReconnect: false,
      onNotification: (title, body) {
        notificationTitle = title;
        notificationBody = body;
      },
    );
    addTearDown(() async {
      source.disconnect();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });

    await source.connect();
    final requests = source
        .watchFriendRequests()
        .firstWhere((items) => items.isNotEmpty)
        .timeout(const Duration(seconds: 2));
    pending = true;
    sockets.single.add(
      jsonEncode({
        'post_type': 'request',
        'request_type': 'friend',
        'user_id': 'bob',
        'comment': 'Hello',
        'flag': 'request-1',
      }),
    );

    expect((await requests).single.id, 'request-1');
    expect(notificationTitle, 'New friend request');
    expect(notificationBody, contains('Hello'));
  });
}
