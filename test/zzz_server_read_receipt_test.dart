import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('ZZZ server parses and applies message read receipts', () async {
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
            {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
          ],
          'get_conversations' => [
            {
              'conversation_id': 'private_me_bob',
              'type': 'private',
              'title': 'Bob',
              'participants': ['me', 'bob'],
              'unread_count': 0,
              'last_timestamp': 200,
            },
          ],
          'get_messages' => [
            _messageJson(
              id: 'message-1',
              text: 'already read',
              timestamp: 100,
              status: 'read',
              readCount: 1,
            ),
            _messageJson(
              id: 'message-2',
              text: 'waiting for receipt',
              timestamp: 200,
              status: 'sent',
              readCount: 0,
            ),
          ],
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
    final initial = await source.watchMessages('private_me_bob').first;
    expect(initial, hasLength(2));
    expect(initial.first.status, ImMessageStatus.read);
    expect(initial.first.readCount, 1);
    expect(initial.last.status, ImMessageStatus.sent);

    final updatedFuture = source
        .watchMessages('private_me_bob')
        .skip(1)
        .first
        .timeout(const Duration(seconds: 2));
    sockets.single.add(
      jsonEncode({
        'post_type': 'notice',
        'notice_type': 'message_read',
        'conversation_id': 'private_me_bob',
        'user_id': 'bob',
        'last_read_message_id': 'message-2',
        'read_at': 200,
      }),
    );

    final updated = await updatedFuture;
    expect(updated.map((message) => message.status), [
      ImMessageStatus.read,
      ImMessageStatus.read,
    ]);
    expect(updated.last.readCount, 1);
  });
}

Map<String, Object?> _messageJson({
  required String id,
  required String text,
  required int timestamp,
  required String status,
  required int readCount,
}) {
  return {
    'message_id': id,
    'conversation_id': 'private_me_bob',
    'sender': {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
    'message': [
      {
        'type': 'text',
        'data': {'text': text},
      },
    ],
    'timestamp': timestamp,
    'status': status,
    'read_count': readCount,
    'recipient_count': 1,
  };
}
