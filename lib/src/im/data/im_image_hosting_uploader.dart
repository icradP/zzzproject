import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'im_image_hosting_config.dart';

class ImHostedImage {
  const ImHostedImage({
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String url;
  final int size;
  final String sha256;
}

class ImImageHostingUploader {
  ImImageHostingUploader({
    required this.config,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final ImImageHostingConfig config;
  final Duration timeout;
  final int maxResponseBytes;
  final http.Client _client;
  final bool _ownsClient;

  Future<ImHostedImage> upload({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    final validationError = config.validationError();
    if (validationError != null) throw StateError(validationError);
    if (bytes.isEmpty) throw StateError('Cannot upload an empty image.');

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(config.endpoint.trim()),
    )..followRedirects = false;
    if (config.token.isNotEmpty) {
      request.headers[config.authorizationHeader.trim()] =
          config.authorizationValue;
    }
    MediaType? contentType;
    if (mimeType != null && mimeType.trim().isNotEmpty) {
      try {
        contentType = MediaType.parse(mimeType.trim());
      } on FormatException {
        // Leave the part as application/octet-stream for malformed MIME input.
      }
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        config.fileField.trim(),
        bytes,
        filename: fileName,
        contentType: contentType,
      ),
    );

    final response = await _client.send(request).timeout(timeout);
    final bodyBytes = await _readLimited(response.stream).timeout(timeout);
    final body = utf8.decode(bodyBytes, allowMalformed: false);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Image host returned HTTP ${response.statusCode}${_bodyHint(body)}',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw StateError('Image host returned invalid JSON.');
    }
    final value = _valueAtPath(decoded, config.responseUrlPath.trim());
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Image host response does not contain an image URL.');
    }
    final url = value.trim();
    final uri = Uri.tryParse(url);
    if (url.length > 2048 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw StateError('Image host must return a valid HTTPS URL.');
    }
    return ImHostedImage(
      url: url,
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  Future<Uint8List> _readLimited(Stream<List<int>> stream) async {
    final body = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > maxResponseBytes) {
        throw StateError('Image host response is too large.');
      }
      body.add(chunk);
    }
    return body.takeBytes();
  }

  Object? _valueAtPath(Object? root, String path) {
    Object? current = root;
    for (final component in path.split('.')) {
      if (component.isEmpty) return null;
      if (current is Map) {
        current = current[component];
        continue;
      }
      if (current is List) {
        final index = int.tryParse(component);
        if (index == null || index < 0 || index >= current.length) return null;
        current = current[index];
        continue;
      }
      return null;
    }
    return current;
  }

  String _bodyHint(String body) {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '.';
    final shortened =
        normalized.length <= 160
            ? normalized
            : '${normalized.substring(0, 160)}...';
    return ': $shortened';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
