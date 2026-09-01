import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zzzproject/src/im/pages/im_web_setup_page.dart';

void main() {
  testWidgets('login page does not expose server connection settings', (
    tester,
  ) async {
    const serverUrl = 'wss://internal.example.com/ws';

    await tester.pumpWidget(
      MaterialApp(
        home: ImWebSetupPage(serverUrl: serverUrl, onConfigured: (_) async {}),
      ),
    );

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text(serverUrl), findsNothing);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('missing build-time server config shows a generic error', (
    tester,
  ) async {
    var configured = false;

    await tester.pumpWidget(
      MaterialApp(
        home: ImWebSetupPage(
          serverUrl: '',
          onConfigured: (_) async => configured = true,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'belle');
    await tester.enterText(find.byType(TextField).at(1), 'secret-token');
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.text('Service is temporarily unavailable.'), findsOneWidget);
    expect(configured, isFalse);
  });

  testWidgets('registration asks for an invitation code', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImWebSetupPage(
          serverUrl: 'wss://example.com/ws',
          onConfigured: (_) async {},
        ),
      ),
    );

    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Invitation code'), findsNothing);

    await tester.tap(find.text('New here? Create an account'));
    await tester.pump();

    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Invitation code'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('registration-avatar-preview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('registration-avatar-upload')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('registration-avatar-option-0')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('registration-avatar-option-1')),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField).at(0), 'belle');
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.tap(find.text('Create account'));
    await tester.pump();

    expect(find.text('Invitation code is required.'), findsOneWidget);
  });
}
