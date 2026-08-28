import 'dart:typed_data';

import '../../models/im_models.dart';

Future<Uint8List> readUploadBytes(ImMediaUpload upload) async {
  final bytes = upload.bytes;
  if (bytes != null) return bytes;
  throw StateError('No readable file data was provided.');
}
