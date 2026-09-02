import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:zzzproject/src/im/adapters/zzz_server/zzz_server_source.dart';
import 'package:zzzproject/src/im/models/im_models.dart';

void main() {
  test('profile background defaults to ZZZ server media upload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final requests = <Map<String, dynamic>>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final requestJson = jsonDecode(raw as String) as Map<String, dynamic>;
        requests.add(requestJson);
        final action = requestJson['action'];
        final params = requestJson['params'] as Map? ?? const {};
        final data = switch (action) {
          'auth' => {'user_id': 'me', 'nickname': 'Me'},
          'get_friends' => <Object?>[],
          'get_friend_requests' => <Object?>[],
          'get_conversations' => <Object?>[],
          'upload_file' => {'url': '/files/profile-background.jpg'},
          'update_profile' => {
            'user_id': 'me',
            'nickname': 'Me',
            'card_background_url': params['card_background_url'],
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
    requests.clear();

    final background = image.Image(width: 16, height: 10);
    image.fill(background, color: image.ColorRgb8(12, 34, 56));
    await source.updateProfile(
      cardBackground: ImMediaUpload(
        kind: ImMessageKind.image,
        fileName: 'background.png',
        bytes: Uint8List.fromList(image.encodePng(background)),
        mimeType: 'image/png',
      ),
    );

    expect(requests.map((request) => request['action']), [
      'upload_file',
      'update_profile',
    ]);
    final update = requests.last['params'] as Map;
    final backgroundUrl = Uri.parse(update['card_background_url'] as String);
    expect(backgroundUrl.scheme, 'http');
    expect(backgroundUrl.host, '127.0.0.1');
    expect(backgroundUrl.port, server.port);
    expect(backgroundUrl.path, '/files/profile-background.jpg');
  });
}
