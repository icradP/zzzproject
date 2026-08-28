import 'dart:io';
import 'dart:typed_data';

import '../../models/im_models.dart';

Future<Uint8List> readUploadBytes(ImMediaUpload upload) async {
  final bytes = upload.bytes;
  if (bytes != null) return bytes;
  final path = upload.filePath;
  if (path == null) throw StateError('No readable file data was provided.');
  return File(path).readAsBytes();
}
