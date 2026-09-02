import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';
import 'package:zzzproject/src/im/data/im_web_plugin_setup.dart';

void main() {
  test('PWA registers browser voice and location implementations', () async {
    if (!kIsWeb) return;

    registerImWebPlugins();
    expect(await Geolocator.isLocationServiceEnabled(), isTrue);

    final recorder = AudioRecorder();
    addTearDown(recorder.dispose);
    expect(await recorder.isEncoderSupported(AudioEncoder.opus), isA<bool>());
  });
}
