import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/src/app/zzz_app.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';

class _TrackingNsfwChecker implements ImNsfwChecker {
  var initializeCalls = 0;

  @override
  bool get isAvailable => false;

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<bool?> check(String imagePath) async => false;

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ZZZ chat shell renders', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ZzzApp());
    await tester.pump();
  });

  testWidgets('does not create the NSFW model while detection is disabled', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var createCalls = 0;

    await tester.pumpWidget(
      ZzzApp(
        nsfwCheckerFactory: () {
          createCalls++;
          return _TrackingNsfwChecker();
        },
      ),
    );
    await _pumpRepositoryInitialization(tester);

    expect(createCalls, 0);
  });

  testWidgets('initializes the NSFW model when detection is enabled', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'im_nsfw_config': jsonEncode({'enabled': true}),
    });
    final checker = _TrackingNsfwChecker();
    var createCalls = 0;

    await tester.pumpWidget(
      ZzzApp(
        nsfwCheckerFactory: () {
          createCalls++;
          return checker;
        },
      ),
    );
    await _pumpRepositoryInitialization(tester);

    expect(createCalls, 1);
    expect(checker.initializeCalls, 1);
  });
}

Future<void> _pumpRepositoryInitialization(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
