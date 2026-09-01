import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/data/im_image_hosting_config.dart';
import 'package:zzzproject/src/im/data/im_image_hosting_uploader.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test(
    'custom image hosting sends URL without uploading bytes to ZZZ',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final actions = <String>[];
      Map<String, dynamic>? sentMessage;
      Map<String, dynamic>? updatedProfile;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
          final action = requestJson['action'] as String;
          actions.add(action);
          if (action == 'send_message') sentMessage = requestJson;
          if (action == 'update_profile') updatedProfile = requestJson;
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
              },
            ],
            'get_messages' => <Object?>[],
            'send_message' => {'message_id': 'message-image'},
            'update_profile' => {
              'user_id': 'me',
              'nickname': 'Me',
              'avatar_url': '',
              'card_background_url':
                  (requestJson['params'] as Map)['card_background_url'],
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

      final uploader = ImImageHostingUploader(
        config: const ImImageHostingConfig(
          enabled: true,
          endpoint: 'https://images.example.test/upload',
          responseUrlPath: 'data.url',
        ),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {'url': 'https://cdn.example.test/photo.png'},
            }),
            200,
          ),
        ),
      );
      final source = ZzzServerSource(
        config: ZzzServerConfig(
          serverUrl: 'ws://127.0.0.1:${server.port}',
          selfId: 'me',
        ),
        imageHostingUploader: uploader,
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
      await source.sendMediaMessage(
        conversationId: 'private_me_bob',
        upload: ImMediaUpload(
          kind: ImMessageKind.image,
          fileName: 'photo.png',
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'image/png',
        ),
      );

      expect(actions, isNot(contains('upload_file')));
      final segments =
          (sentMessage!['params'] as Map<String, dynamic>)['message'] as List;
      final data = (segments.single as Map<String, dynamic>)['data'] as Map;
      expect(data['url'], 'https://cdn.example.test/photo.png');
      expect(data['file'], isNull);
      expect(data['sha256'], hasLength(64));

      final background = image.Image(width: 2400, height: 1200);
      image.fill(background, color: image.ColorRgb8(24, 32, 48));
      await source.updateProfile(
        cardBackground: ImMediaUpload(
          kind: ImMessageKind.image,
          fileName: 'background.png',
          bytes: Uint8List.fromList(image.encodePng(background)),
          mimeType: 'image/png',
        ),
      );

      expect(actions, isNot(contains('upload_file')));
      expect(
        (updatedProfile!['params'] as Map)['card_background_url'],
        'https://cdn.example.test/photo.png',
      );
    },
  );
}
