import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';

void main() {
  test('ZZZ server applies realtime friend presence updates', () async {
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
              'avatar_url': '',
              'online': false,
              'relationship': 'friend',
            },
          ],
          'get_conversations' => <Object?>[],
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
    final initial = await source.watchUsers().first;
    expect(initial.single.id, 'bob');
    expect(initial.single.isOnline, isFalse);

    final online = source
        .watchUsers()
        .firstWhere((users) => users.single.isOnline)
        .timeout(const Duration(seconds: 2));
    sockets.single.add(
      jsonEncode({
        'post_type': 'notice',
        'notice_type': 'friend_presence',
        'user_id': 'bob',
        'online': true,
      }),
    );
    expect((await online).single.isOnline, isTrue);

    final offline = source
        .watchUsers()
        .firstWhere((users) => !users.single.isOnline)
        .timeout(const Duration(seconds: 2));
    sockets.single.add(
      jsonEncode({
        'post_type': 'notice',
        'notice_type': 'friend_presence',
        'user_id': 'bob',
        'online': false,
      }),
    );
    expect((await offline).single.isOnline, isFalse);
  });
}
