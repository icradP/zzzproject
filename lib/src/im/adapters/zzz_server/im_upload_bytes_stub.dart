import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/im_models.dart';

Future<Uint8List> readUploadBytes(ImMediaUpload upload) async {
  final bytes = upload.bytes;
  if (bytes != null) return bytes;
  final path = upload.filePath;
  if (path != null) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme) {
      final response = await http.get(uri);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.bodyBytes;
      }
    }
  }
  throw StateError('No readable file data was provided.');
}
