import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zzzproject/src/im/data/im_image_hosting_config.dart';
import 'package:zzzproject/src/im/data/im_image_hosting_uploader.dart';

void main() {
  const config = ImImageHostingConfig(
    enabled: true,
    endpoint: 'https://images.example.test/upload',
    fileField: 'asset',
    authorizationHeader: 'X-API-Key',
    authorizationScheme: 'Token',
    responseUrlPath: 'result.0.url',
    token: 'secret',
  );

  test('uploads multipart image and parses configured JSON URL path', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'result': [
            {'url': 'https://cdn.example.test/image.png'},
          ],
        }),
        201,
        headers: {'content-type': 'application/json'},
      );
    });
    final uploader = ImImageHostingUploader(config: config, client: client);

    final result = await uploader.upload(
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      fileName: 'photo.png',
      mimeType: 'image/png',
    );

    expect(captured.method, 'POST');
    expect(captured.headers['X-API-Key'], 'Token secret');
    expect(
      captured.headers['content-type'],
      startsWith('multipart/form-data;'),
    );
    expect(result.url, 'https://cdn.example.test/image.png');
    expect(result.size, 4);
    expect(result.sha256, hasLength(64));
  });

  test('rejects non-HTTPS URL returned by image host', () async {
    final uploader = ImImageHostingUploader(
      config: config,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'result': [
              {'url': 'http://cdn.example.test/image.png'},
            ],
          }),
          200,
        ),
      ),
    );

    expect(
      uploader.upload(bytes: Uint8List.fromList([1]), fileName: 'photo.png'),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects oversized image host responses', () async {
    final uploader = ImImageHostingUploader(
      config: config,
      maxResponseBytes: 32,
      client: MockClient((_) async => http.Response('x' * 33, 200)),
    );

    expect(
      uploader.upload(bytes: Uint8List.fromList([1]), fileName: 'photo.png'),
      throwsA(isA<StateError>()),
    );
  });
}
