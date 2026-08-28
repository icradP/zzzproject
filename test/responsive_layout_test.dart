import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/src/app/zzz_app.dart';
import 'package:zzzproject/src/assets/app_assets.dart';
import 'package:zzzproject/src/demo/chat_simulator_demo_page.dart';
import 'package:zzzproject/src/models/chat_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scenarios = <_ViewportScenario>[
    _ViewportScenario('iPhone SE', Size(375, 667)),
    _ViewportScenario('iPhone 15 Pro Max', Size(430, 932)),
    _ViewportScenario('iPad portrait', Size(768, 1024)),
    _ViewportScenario('iPad landscape', Size(1024, 768)),
    _ViewportScenario('desktop web', Size(1440, 900)),
  ];

  for (final scenario in scenarios) {
    testWidgets(
      'IM home adapts without layout exceptions on ${scenario.name}',
      (tester) async {
        await _setViewport(tester, scenario.size);
        SharedPreferences.setMockInitialValues({});

        await tester.pumpWidget(const ZzzApp());
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        _expectNoFlutterException(tester);

        expect(find.text('Messages'), findsOneWidget);
        expect(find.text('Belle'), findsWidgets);

        await _openAndCloseSettings(tester);
        _expectNoFlutterException(tester);
      },
    );
  }

  for (final scenario in scenarios) {
    testWidgets('character picker adapts on ${scenario.name}', (tester) async {
      await _setViewport(tester, scenario.size);

      await tester.pumpWidget(
        MaterialApp(
          home: CharacterPickerDialog(
            characters: _sampleCharacters,
            sideLabel: 'left',
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      _expectNoFlutterException(tester);

      expect(find.textContaining('Choose a Character'), findsOneWidget);
      expect(find.text('Search by name or category...'), findsOneWidget);
    });
  }
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;

  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _openAndCloseSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings'));
  await _pumpFrames(tester);

  expect(find.text('IM Settings'), findsOneWidget);
  await tester.tap(find.byTooltip('Back'));
  await _pumpFrames(tester);

  expect(find.text('Messages'), findsOneWidget);
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _expectNoFlutterException(WidgetTester tester) {
  final exception = tester.takeException();
  expect(exception, isNull);
}

class _ViewportScenario {
  const _ViewportScenario(this.name, this.size);

  final String name;
  final Size size;
}

final _sampleCharacters = <ChatCharacter>[
  ChatCharacter(
    name: 'Wise',
    assetPath: AppAssets.characterWise,
    category: 'Phaethon',
  ),
  ChatCharacter(
    name: 'Belle',
    assetPath: AppAssets.characterBelle,
    category: 'Phaethon',
  ),
  ChatCharacter(
    name: 'Anby Demara',
    assetPath: AppAssets.character('AnbyDemara.png'),
    category: 'Cunning Hares',
  ),
  ChatCharacter(
    name: 'Nicole Demara',
    assetPath: AppAssets.character('NicoleDemara.png'),
    category: 'Cunning Hares',
  ),
  ChatCharacter(
    name: 'Fairy',
    assetPath: AppAssets.character('temp/Fairy.png'),
    category: 'System',
  ),
];
