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

  test('rejects invalid profile background bytes', () {
    expect(
      prepareImProfileBackground(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<StateError>()),
    );
  });
}
