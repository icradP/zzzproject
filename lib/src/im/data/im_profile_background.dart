import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

const imProfileBackgroundMaxInputBytes = 20 * 1024 * 1024;

class ImPreparedProfileBackground {
  const ImPreparedProfileBackground({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
}

/// Prepares a profile-card background entirely on the client before upload.
Future<ImPreparedProfileBackground> prepareImProfileBackground(
  Uint8List bytes,
) async {
  if (bytes.isEmpty) throw StateError('Card background cannot be empty.');
  if (bytes.length > imProfileBackgroundMaxInputBytes) {
    throw StateError('Card backgrounds must be 20 MB or smaller.');
  }
  return compute(_prepareProfileBackground, bytes);
}

ImPreparedProfileBackground _prepareProfileBackground(Uint8List bytes) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(bytes);
  } catch (_) {
    throw StateError('The selected card background is not a valid image.');
  }
  if (decoded == null) {
    throw StateError('The selected card background is not a valid image.');
  }
  if (decoded.hasAnimation) {
    final format = _animatedFormat(bytes);
    if (format == null) {
      throw StateError('This animated image format is not supported.');
    }
    return ImPreparedProfileBackground(
      bytes: bytes,
      fileName: 'card-background.${format.extension}',
      mimeType: format.mimeType,
    );
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
  return ImPreparedProfileBackground(
    bytes: Uint8List.fromList(image.encodeJpg(resized, quality: 82)),
    fileName: 'card-background.jpg',
    mimeType: 'image/jpeg',
  );
}

_AnimatedImageFormat? _animatedFormat(Uint8List bytes) {
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return _AnimatedImageFormat.gif;
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return _AnimatedImageFormat.webp;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return _AnimatedImageFormat.png;
  }
  return null;
}

enum _AnimatedImageFormat {
  gif('gif', 'image/gif'),
  webp('webp', 'image/webp'),
  png('png', 'image/png');

  const _AnimatedImageFormat(this.extension, this.mimeType);

  final String extension;
  final String mimeType;
}
