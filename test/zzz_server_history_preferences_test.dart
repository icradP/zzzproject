import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('ZZZ source paginates older history and saves preferences', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    Map<String, dynamic>? preferenceRequest;
    Map<String, dynamic>? historyRequest;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        final action = requestJson['action'];
        final params = Map<String, dynamic>.from(
          requestJson['params'] as Map? ?? const {},
        );
        if (action == 'set_conversation_preferences') {
          preferenceRequest = requestJson;
        }
        if (action == 'get_messages' && params['before_message_id'] != null) {
          historyRequest = requestJson;
        }
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
              'is_pinned': false,
              'is_muted': false,
              'last_timestamp': 100,
            },
          ],
          'get_messages' when params['before_message_id'] != null => [
            _messageJson(1),
            _messageJson(2),
          ],
          'get_messages' => [
            for (var index = 51; index <= 100; index++) _messageJson(index),
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
    expect(await source.watchMessages('private_me_bob').first, hasLength(50));
    final updated = source
        .watchMessages('private_me_bob')
        .firstWhere((messages) => messages.length == 52);
    expect(await source.loadOlderMessages('private_me_bob'), isFalse);
    expect(await updated, hasLength(52));
    expect(
      (historyRequest!['params'] as Map<String, dynamic>),
      containsPair('before_message_id', 'message-51'),
    );

    await source.setConversationPreferences(
      conversationId: 'private_me_bob',
      isPinned: true,
      notificationLevel: ImConversationNotificationLevel.muted,
    );
    final conversation = (await source.watchConversations().first).single;
    expect(conversation.isPinned, isTrue);
    expect(conversation.isMuted, isTrue);
    expect(preferenceRequest!['params'], containsPair('is_muted', true));
    expect(
      preferenceRequest!['params'],
      containsPair('notification_level', 'muted'),
    );
  });
}

Map<String, Object?> _messageJson(int index) => {
  'message_id': 'message-$index',
  'conversation_id': 'private_me_bob',
  'sender': {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
  'message': [
    {
      'type': 'text',
      'data': {'text': 'Message $index'},
    },
  ],
  'timestamp': index,
  'status': 'sent',
  'read_count': 0,
  'recipient_count': 1,
};
