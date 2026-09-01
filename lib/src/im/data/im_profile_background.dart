import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

const imProfileBackgroundMaxInputBytes = 20 * 1024 * 1024;

class ImPreparedProfileBackground {
  const ImPreparedProfileBackground({required this.bytes});

  final Uint8List bytes;
  String get fileName => 'card-background.jpg';
  String get mimeType => 'image/jpeg';
}

/// Prepares a profile-card background entirely on the client before upload.
Future<ImPreparedProfileBackground> prepareImProfileBackground(
  Uint8List bytes,
) async {
  if (bytes.isEmpty) throw StateError('Card background cannot be empty.');
  if (bytes.length > imProfileBackgroundMaxInputBytes) {
    throw StateError('Card backgrounds must be 20 MB or smaller.');
  }
  final prepared = await compute(_prepareProfileBackground, bytes);
  return ImPreparedProfileBackground(bytes: prepared);
}

Uint8List _prepareProfileBackground(Uint8List bytes) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(bytes);
  } catch (_) {
    throw StateError('The selected card background is not a valid image.');
  }
  if (decoded == null) {
    throw StateError('The selected card background is not a valid image.');
  }
  final oriented = image.bakeOrientation(decoded);
  final scale = math.min(
    1.0,
    math.min(1600 / oriented.width, 900 / oriented.height),
  );
  final resized =
      scale < 1
          ? image.copyResize(
            oriented,
            width: math.max(1, (oriented.width * scale).round()),
            height: math.max(1, (oriented.height * scale).round()),
            interpolation: image.Interpolation.linear,
          )
          : oriented;
  return Uint8List.fromList(image.encodeJpg(resized, quality: 82));
}
