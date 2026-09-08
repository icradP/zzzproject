import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/dynamic/models/im_dynamic_models.dart';
import 'package:zzzproject/src/im/dynamic/runtime/im_dynamic_capabilities.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test(
    'ZZZ server source preserves replies and applies recall notices',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      Map<String, dynamic>? sentMessageRequest;
      Map<String, dynamic>? recallRequest;
      Map<String, dynamic>? reactionRequest;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'];
          if (action == 'send_message') sentMessageRequest = requestJson;
          if (action == 'recall_message') recallRequest = requestJson;
          if (action == 'react_message') reactionRequest = requestJson;
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
              _messageJson(id: 'message-1', text: 'Original', timestamp: 100),
              _messageJson(
                id: 'message-2',
                text: 'Reply body',
                timestamp: 200,
                replyTo: 'message-1',
              ),
            ],
            'send_message' => {'message_id': 'message-3'},
            'react_message' => {
              'message_id': 'message-1',
              'emoji_id': '76',
              'reactions': [
                {'emoji_id': '76', 'count': 1},
              ],
              'my_reactions': ['76'],
            },
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
      expect(initial.last.replyToMessageId, 'message-1');
      expect(initial.last.text, 'Reply body');
      expect(initial.last.segments?.first.type, 'reply');

      final sent = await source.sendTextMessage(
        conversationId: 'private_me_bob',
        text: 'Another reply',
        replyToMessageId: 'message-2',
      );
      expect(sent.replyToMessageId, 'message-2');
      final sentSegments =
          (sentMessageRequest!['params'] as Map<String, dynamic>)['message']
              as List<dynamic>;
      expect(sentSegments.first['type'], 'reply');
      expect(sentSegments.first['data']['id'], 'message-2');

      const sticker = ImStickerReference(
        packId: 'zzz-core',
        assetId: 'corin-01',
        version: 1,
      );
      final sentSticker = await source.sendStickerMessage(
        conversationId: 'private_me_bob',
        sticker: sticker,
      );
      final stickerSegments =
          (sentMessageRequest!['params'] as Map<String, dynamic>)['message']
              as List<dynamic>;
      expect(stickerSegments.single['type'], 'sticker');
      expect(stickerSegments.single['data'], sticker.toSegmentData());
      expect(sentSticker.kind, ImMessageKind.face);
      expect(sentSticker.segments?.single.type, 'sticker');
      expect(sentSticker.text, '[表情]');

      final recalledFuture = source
          .watchMessages('private_me_bob')
          .skip(1)
          .firstWhere(
            (messages) => messages.any(
              (message) => message.id == 'message-2' && message.recalled,
            ),
          )
          .timeout(const Duration(seconds: 2));
      sockets.single.add(
        jsonEncode({
          'post_type': 'notice',
          'notice_type': 'friend_recall',
          'conversation_id': 'private_me_bob',
          'message_id': 'message-2',
          'user_id': 'bob',
          'operator_id': 'bob',
        }),
      );
      final recalled = await recalledFuture;
      expect(
        recalled.singleWhere((message) => message.id == 'message-2').recalled,
        isTrue,
      );

      await source.recallMessage(
        conversationId: 'private_me_bob',
        messageId: 'message-3',
      );
      expect(
        (recallRequest!['params'] as Map<String, dynamic>)['message_id'],
        'message-3',
      );

      final reactions = await source.reactToMessage(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        emojiId: '76',
      );
      expect(reactions.single.emojiId, '76');
      expect(reactions.single.count, 1);
      expect(reactions.single.reactedByMe, isTrue);
      expect(
        (reactionRequest!['params'] as Map<String, dynamic>)['emoji_id'],
        '76',
      );
    },
  );

  test('ZZZ server source sends structured M4 request payloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final requests = <Map<String, dynamic>>[];
    var sentMessageId = 0;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(requestJson);
        final action = requestJson['action'];
        final data = switch (action) {
          'auth' => {'user_id': 'me', 'nickname': 'Me', 'avatar_url': ''},
          'get_friends' => [
            {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
          ],
          'get_friend_requests' => <Object?>[],
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
          'get_messages' => <Object?>[],
          'create_forward' => {'forward_id': 'forward-1'},
          'get_forward_msg' => [
            {
              'message_id': 'forward-message-1',
              'sender': {'user_id': 'bob-uuid', 'nickname': 'Bob Nick'},
              'message': [
                {
                  'type': 'text',
                  'data': {'text': 'Forwarded text'},
                },
              ],
              'timestamp': 200,
            },
          ],
          'send_message' => {'message_id': 'sent-${++sentMessageId}'},
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
    requests.clear();

    await source.sendLinkMessage(
      conversationId: 'private_me_bob',
      link: ImLinkShare(
        url: Uri.parse('https://example.test/docs'),
        title: 'Documentation',
      ),
    );
    await source.sendLocationMessage(
      conversationId: 'private_me_bob',
      location: const ImLocationShare(
        name: 'People\'s Square',
        latitude: 31.2304,
        longitude: 121.4737,
      ),
    );
    await source.sendPoke(
      conversationId: 'private_me_bob',
      targetUserId: 'bob',
    );
    await source.forwardMessages(
      conversationId: 'private_me_bob',
      messages: [
        ImMessage(
          id: 'source-message-1',
          conversationId: 'private_me_bob',
          senderId: 'bob',
          text: 'Snapshot me',
          sentAt: DateTime(2026),
        ),
      ],
    );
    final forward = await source.getForwardMessages('forward-1');
    expect(forward.messages.single.senderDisplayName, 'Bob Nick');

    final sendRequests =
        requests
            .where((request) => request['action'] == 'send_message')
            .toList();
    expect(sendRequests, hasLength(4));
    expect(_sentSegments(sendRequests[0]), [
      {
        'type': 'share',
        'data': {'url': 'https://example.test/docs', 'title': 'Documentation'},
      },
    ]);
    expect(_sentSegments(sendRequests[1]), [
      {
        'type': 'location',
        'data': {'name': 'People\'s Square', 'lat': 31.2304, 'lon': 121.4737},
      },
    ]);
    expect(_sentSegments(sendRequests[2]), [
      {
        'type': 'poke',
        'data': {'target_id': 'bob'},
      },
    ]);
    expect(_sentSegments(sendRequests[3]), [
      {
        'type': 'forward',
        'data': {'id': 'forward-1', 'count': 1},
      },
    ]);

    final createForward = requests.singleWhere(
      (request) => request['action'] == 'create_forward',
    );
    expect(createForward['params'], {
      'conversation_id': 'private_me_bob',
      'message_ids': ['source-message-1'],
    });
  });

  test(
    'ZZZ server source sends validated text with multiple dynamic contents',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final sendRequests = <Map<String, dynamic>>[];
      Map<String, dynamic>? authRequest;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'];
          if (action == 'auth') authRequest = requestJson;
          if (action == 'send_message') sendRequests.add(requestJson);
          final data = switch (action) {
            'auth' => {
              'user_id': 'me',
              'nickname': 'Me',
              'avatar_url': '',
              'server_capabilities': {
                'protocol_version': '1.0',
                'dynamic_content': {
                  'schema_versions': ['1.0'],
                  'component_version': '1.0',
                  'components': <String>[],
                  'events': true,
                  'node_id_patch': true,
                },
              },
              'negotiated_capabilities':
                  ImDynamicProtocolCapabilities.current.toJson(),
            },
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
            'get_messages' => <Object?>[],
            'send_message' => {
              'message_id': 'dynamic-message-1',
              'timestamp_ms': 200,
            },
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
      final advertised =
          (authRequest!['params'] as Map<String, dynamic>)['capabilities']
              as Map<String, dynamic>;
      expect(advertised['protocol_version'], '1.0');
      expect(
        (advertised['dynamic_content']
            as Map<String, dynamic>)['component_version'],
        '1.0',
      );
      expect(source.serverDynamicCapabilities?.schemaVersions, ['1.0']);
      expect(source.negotiatedDynamicCapabilities?.supportsEvents, isTrue);
      final sent = await source.sendDynamicContents(
        conversationId: 'private_me_bob',
        text: 'Diagnosis ready',
        contents: [
          _dynamicContent('diagnosis-1', 'Network status'),
          _dynamicContent('actions-1', 'Available actions'),
        ],
        clientMessageId: 'dynamic-client-1',
      );

      expect(sent.id, 'dynamic-message-1');
      expect(sendRequests, hasLength(1));
      final params = sendRequests.single['params'] as Map<String, dynamic>;
      expect(params['client_message_id'], 'dynamic-client-1');
      expect(params['message'], [
        {
          'type': 'text',
          'data': {'text': 'Diagnosis ready'},
        },
        {
          'type': 'dynamic_content',
          'data': {
            'id': 'diagnosis-1',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'root-diagnosis-1',
              'type': 'text',
              'props': {'text': 'Network status'},
            },
          },
        },
        {
          'type': 'dynamic_content',
          'data': {
            'id': 'actions-1',
            'version': '1.0',
            'source': 'ai',
            'tree': {
              'id': 'root-actions-1',
              'type': 'text',
              'props': {'text': 'Available actions'},
            },
          },
        },
      ]);

      expect(
        () => source.sendDynamicContent(
          conversationId: 'private_me_bob',
          content: _dynamicContent('', 'Invalid'),
        ),
        throwsArgumentError,
      );
      expect(
        () => source.sendDynamicContents(
          conversationId: 'private_me_bob',
          contents: [
            _dynamicContent('duplicate', 'First'),
            _dynamicContent('duplicate', 'Second'),
          ],
        ),
        throwsArgumentError,
      );
      expect(sendRequests, hasLength(1));
    },
  );

  test(
    'ZZZ server source sends and receives transient dynamic events',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      Map<String, dynamic>? dynamicEventRequest;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          if (requestJson['action'] == 'send_message') {
            final params = requestJson['params'] as Map<String, dynamic>;
            final message = params['message'] as List<dynamic>;
            if (message.single['type'] == 'dynamic_event') {
              dynamicEventRequest = requestJson;
            }
          }
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
            'get_messages' => <Object?>[],
            'send_message' => {'message_id': 'dynamic-event-ack'},
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
      final incoming = source.dynamicEvents.first.timeout(
        const Duration(seconds: 2),
      );
      final event = const ImDynamicEvent(
        messageId: 'message-1',
        contentId: 'event-card-1',
        nodeId: 'retry',
        event: 'click',
        action: 'retry',
        payload: {'source': 'test'},
      );
      await source.sendDynamicEvent(
        conversationId: 'private_me_bob',
        event: event,
      );
      final sentSegments =
          ((dynamicEventRequest!['params'] as Map<String, dynamic>)['message']
              as List<dynamic>);
      expect(sentSegments, [
        {
          'type': 'dynamic_event',
          'data': {
            'message_id': 'message-1',
            'content_id': 'event-card-1',
            'node_id': 'retry',
            'event': 'click',
            'action': 'retry',
            'payload': {'source': 'test'},
          },
        },
      ]);

      sockets.single.add(
        jsonEncode({
          'post_type': 'message',
          'message_type': 'private',
          'message_id': 'message-1',
          'conversation_id': 'private_me_bob',
          'sender': {'user_id': 'bob', 'nickname': 'Bob'},
          'message': sentSegments,
          'timestamp_ms': 1700000000000,
        }),
      );
      final envelope = await incoming;
      expect(envelope.conversationId, 'private_me_bob');
      expect(envelope.senderId, 'bob');
      expect(envelope.event.nodeId, 'retry');
      expect(envelope.event.action, 'retry');
    },
  );

  test(
    'ZZZ server source reuses dynamic update client IDs for retries',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final sendRequests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'];
          if (action == 'send_message') sendRequests.add(requestJson);
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
              {
                'message_id': 'message-1',
                'conversation_id': 'private_me_bob',
                'sender': {'user_id': 'bob', 'nickname': 'Bob'},
                'message': [
                  {
                    'type': 'dynamic_content',
                    'data': {
                      'id': 'card-1',
                      'version': '1.0',
                      'source': 'ai',
                      'tree': {
                        'id': 'root',
                        'type': 'column',
                        'children': [
                          {
                            'id': 'status',
                            'type': 'status',
                            'props': {'text': 'Checking'},
                          },
                        ],
                      },
                    },
                  },
                ],
                'timestamp_ms': 100,
              },
            ],
            'send_message' => {'message_id': 'message-1', 'timestamp_ms': 200},
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
      await source.watchMessages('private_me_bob').first;
      final updates = <ImDynamicUpdateEnvelope>[];
      final updateSubscription = source.dynamicUpdates.listen(updates.add);
      final messageSnapshots = <List<ImMessage>>[];
      final messageSubscription = source
          .watchMessages('private_me_bob')
          .listen(messageSnapshots.add);
      addTearDown(updateSubscription.cancel);
      addTearDown(messageSubscription.cancel);
      await Future<void>.delayed(Duration.zero);
      messageSnapshots.clear();
      const patch = ImDynamicPatch(
        operation: ImDynamicPatchOperation.update,
        nodeId: 'status',
        props: {'text': 'Complete'},
      );
      final updated = await source.sendDynamicUpdate(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        contentId: 'card-1',
        patches: [patch],
        clientMessageId: 'zzzterm-update-1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(updates, hasLength(1));
      expect(updates.single.conversationId, 'private_me_bob');
      expect(updates.single.update.messageId, 'message-1');
      expect(messageSnapshots, isEmpty);
      final updatedContent = ImDynamicContent.fromSegmentData(
        updated.segments!.single.data,
      );
      expect(updatedContent.tree.findById('status')?.props['text'], 'Complete');

      final sentParams = sendRequests.single['params'] as Map<String, dynamic>;
      sockets.single.add(
        jsonEncode({
          'post_type': 'message',
          'message_type': 'private',
          'message_id': 'message-1',
          'conversation_id': 'private_me_bob',
          'sender': {'user_id': 'me', 'nickname': 'Me'},
          'message': sentParams['message'],
          'timestamp_ms': 200,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(updates, hasLength(1));
      expect(messageSnapshots, isEmpty);

      await source.sendDynamicUpdate(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        contentId: 'card-1',
        patches: [patch],
        clientMessageId: 'zzzterm-update-1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(updates, hasLength(1));
      expect(messageSnapshots, isEmpty);
      expect(sendRequests, hasLength(2));
      for (final request in sendRequests) {
        final params = request['params'] as Map<String, dynamic>;
        expect(params['client_message_id'], 'zzzterm-update-1');
        expect((params['message'] as List).single['type'], 'dynamic_update');
      }

      messageSnapshots.clear();
      final replacement = _dynamicContent('card-1', 'Replaced');
      await source.replaceDynamicContent(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        contentId: 'card-1',
        content: replacement,
        clientMessageId: 'zzzterm-replace-1',
      );
      messageSnapshots.clear();
      final replaceRequest = sendRequests.last;
      final replaceParams = replaceRequest['params'] as Map<String, dynamic>;
      expect(replaceParams['client_message_id'], 'zzzterm-replace-1');
      expect(
        (replaceParams['message'] as List).single['type'],
        'dynamic_replace',
      );
      sockets.single.add(
        jsonEncode({
          'post_type': 'message',
          'message_type': 'private',
          'message_id': 'message-1',
          'conversation_id': 'private_me_bob',
          'sender': {'user_id': 'bob', 'nickname': 'Bob'},
          'message': replaceParams['message'],
          'timestamp_ms': 300,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(messageSnapshots, isNotEmpty);
      expect(
        ImDynamicContent.fromSegmentData(
          messageSnapshots.last.single.segments!.single.data,
        ).tree.props['text'],
        'Replaced',
      );

      messageSnapshots.clear();
      await source.removeDynamicContent(
        conversationId: 'private_me_bob',
        messageId: 'message-1',
        contentId: 'card-1',
        clientMessageId: 'zzzterm-remove-1',
      );
      messageSnapshots.clear();
      final removeRequest = sendRequests.last;
      final removeParams = removeRequest['params'] as Map<String, dynamic>;
      expect(removeParams['client_message_id'], 'zzzterm-remove-1');
      expect(
        (removeParams['message'] as List).single['type'],
        'dynamic_remove',
      );
      sockets.single.add(
        jsonEncode({
          'post_type': 'message',
          'message_type': 'private',
          'message_id': 'message-1',
          'conversation_id': 'private_me_bob',
          'sender': {'user_id': 'bob', 'nickname': 'Bob'},
          'message': removeParams['message'],
          'timestamp_ms': 400,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(messageSnapshots, isNotEmpty);
      expect(messageSnapshots.last.single.segments, isEmpty);
    },
  );
}

ImDynamicContent _dynamicContent(String id, String text) => ImDynamicContent(
  id: id,
  version: '1.0',
  source: ImDynamicContentSource.ai,
  tree: ImDynamicNode(id: 'root-$id', type: 'text', props: {'text': text}),
);

List<dynamic> _sentSegments(Map<String, dynamic> request) {
  final params = request['params'] as Map<String, dynamic>;
  return params['message'] as List<dynamic>;
}

Map<String, Object?> _messageJson({
  required String id,
  required String text,
  required int timestamp,
  String? replyTo,
}) {
  return {
    'message_id': id,
    'conversation_id': 'private_me_bob',
    'sender': {'user_id': 'bob', 'nickname': 'Bob', 'avatar_url': ''},
    'message': [
      if (replyTo != null)
        {
          'type': 'reply',
          'data': {'id': replyTo},
        },
      {
        'type': 'text',
        'data': {'text': text},
      },
    ],
    'timestamp': timestamp,
    'status': 'sent',
    'read_count': 0,
    'recipient_count': 1,
  };
}
