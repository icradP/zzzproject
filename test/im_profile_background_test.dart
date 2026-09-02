import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:zzzproject/src/im/data/im_profile_background.dart';

void main() {
  test('compresses profile backgrounds within 1600x900 as JPEG', () async {
    final source = image.Image(width: 2400, height: 1200);
    image.fill(source, color: image.ColorRgb8(28, 46, 64));

    final prepared = await prepareImProfileBackground(
      Uint8List.fromList(image.encodePng(source)),
    );
    final decoded = image.decodeJpg(prepared.bytes);

    expect(decoded, isNotNull);
    expect(decoded!.width, 1600);
    expect(decoded.height, 800);
    expect(prepared.fileName, 'card-background.jpg');
    expect(prepared.mimeType, 'image/jpeg');
  });

  test('preserves animated GIF frames and upload metadata', () async {
    final animation = image.Image(width: 12, height: 8)..frameDuration = 120;
    image.fill(animation, color: image.ColorRgb8(220, 30, 40));
    final secondFrame = image.Image(width: 12, height: 8)..frameDuration = 180;
    image.fill(secondFrame, color: image.ColorRgb8(30, 80, 220));
    animation.addFrame(secondFrame);
    final original = Uint8List.fromList(image.encodeGif(animation));

    final prepared = await prepareImProfileBackground(original);

    expect(prepared.bytes, orderedEquals(original));
    expect(prepared.fileName, 'card-background.gif');
    expect(prepared.mimeType, 'image/gif');
    expect(image.decodeGif(prepared.bytes)?.numFrames, 2);
  });

  test('rejects invalid profile background bytes', () {
    expect(
      prepareImProfileBackground(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<StateError>()),
    );
  });
}
