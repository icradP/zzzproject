import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zzzproject/src/app/zzz_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('image hosting settings expand on a narrow viewport', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..physicalSize = const Size(375, 667)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const ZzzApp());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byTooltip('Settings'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('IM Settings'), findsOneWidget);
    await tester.ensureVisible(find.text('Image hosting'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Image hosting'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('Use custom hosting for images'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Use custom hosting for images'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('image-host-endpoint')), findsOneWidget);
    expect(find.byKey(const Key('image-host-token')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
