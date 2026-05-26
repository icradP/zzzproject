import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/main.dart';
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
    testWidgets('adapts without layout exceptions on ${scenario.name}', (
      tester,
    ) async {
      await _setViewport(tester, scenario.size);
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const MyApp());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      _expectNoFlutterException(tester);

      expect(find.text('Knock Knock'), findsOneWidget);
      expect(find.text('Start a conversation!'), findsOneWidget);

      await _openAndCloseSettings(tester);
      _expectNoFlutterException(tester);
    });
  }

  for (final scenario in scenarios) {
    testWidgets('character picker adapts on ${scenario.name}', (tester) async {
      await _setViewport(tester, scenario.size);

      await tester.pumpWidget(
        const MaterialApp(
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
  final settingsButton = find.text('Settings');
  await tester.ensureVisible(settingsButton);
  await tester.tap(settingsButton);
  await tester.pump(const Duration(milliseconds: 300));

  expect(find.text('Flashing colors'), findsOneWidget);
  await tester.tap(find.widgetWithText(FilledButton, 'Done'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
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

const _sampleCharacters = <ChatCharacter>[
  ChatCharacter(
    name: 'Wise',
    assetPath: 'assets/characters/Wise.png',
    category: 'Phaethon',
  ),
  ChatCharacter(
    name: 'Belle',
    assetPath: 'assets/characters/Belle.png',
    category: 'Phaethon',
  ),
  ChatCharacter(
    name: 'Anby Demara',
    assetPath: 'assets/characters/AnbyDemara.png',
    category: 'Cunning Hares',
  ),
  ChatCharacter(
    name: 'Nicole Demara',
    assetPath: 'assets/characters/NicoleDemara.png',
    category: 'Cunning Hares',
  ),
  ChatCharacter(
    name: 'Fairy',
    assetPath: 'assets/characters/temp/Fairy.png',
    category: 'System',
  ),
];
