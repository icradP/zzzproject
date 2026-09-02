import 'dart:js_interop';
import 'dart:typed_data';

import '../../models/im_models.dart';

@JS('fetch')
external JSPromise<JSObject> _fetch(JSString url);

extension type _WebResponse(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

Future<Uint8List> readUploadBytes(ImMediaUpload upload) async {
  final bytes = upload.bytes;
  if (bytes != null) return bytes;
  final path = upload.filePath;
  if (path == null || path.isEmpty) {
    throw StateError('No readable file data was provided.');
  }
  try {
    final response = _WebResponse(await _fetch(path.toJS).toDart);
    if (!response.ok) throw StateError('Unable to read the selected file.');
    final buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (error) {
    throw StateError('Unable to read browser media data: $error');
  }
}
