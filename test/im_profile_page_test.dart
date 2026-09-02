import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/im/data/im_interaction_handler.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker.dart';
import 'package:zzzproject/src/im/data/im_nsfw_checker_stub.dart';
import 'package:zzzproject/src/im/data/im_push_manager.dart';
import 'package:zzzproject/src/im/data/mock_im_repository.dart';
import 'package:zzzproject/src/im/im_scope.dart';
import 'package:zzzproject/src/im/pages/im_profile_page.dart';

void main() {
  testWidgets('selects and saves a built-in avatar', (tester) async {
    tester.view
      ..physicalSize = const Size(375, 812)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = MockImRepository();
    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: const MaterialApp(home: ImProfilePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('avatar-option-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('avatar-option-0')));
    await tester.pump();
    await tester.ensureVisible(find.text('Save profile'));
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();

    final user = await repository.getCurrentUser();
    expect(user.avatarAssetPath, AppAssets.avatarPool.first);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a color picker and saves a solid card background', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(375, 812)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = MockImRepository();
    await tester.pumpWidget(
      ImScope(
        repository: repository,
        interactions: const NoOpImInteractionHandler(),
        nsfwChecker: StubNsfwChecker(),
        nsfwStateCache: NsfwStateCache(),
        pushManager: NoOpImPushManager(),
        onConnectionsChanged: () async {},
        child: const MaterialApp(home: ImProfilePage()),
      ),
    );
    await tester.pumpAndSettle();

    final pickerButton = find.byKey(
      const ValueKey('card-background-color-picker'),
    );
    await tester.ensureVisible(pickerButton);
    await tester.tap(pickerButton);
    await tester.pumpAndSettle();

    final pickerFinder = find.byKey(const ValueKey('background-color-picker'));
    expect(pickerFinder, findsOneWidget);
    final picker = tester.widget<ColorPicker>(pickerFinder);
    picker.onColorChanged(const Color(0xFF12AB34));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('apply-background-color')));
    await tester.pumpAndSettle();

    expect(find.text('#12AB34'), findsOneWidget);
    await tester.ensureVisible(find.text('Save profile'));
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();

    expect((await repository.getCurrentUser()).cardBackgroundColor, '#12AB34');
    expect(tester.takeException(), isNull);
  });
}
