import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ZZZ chat shell renders', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Knock Knock'), findsOneWidget);
    expect(find.text('No messages yet.'), findsOneWidget);
    expect(find.text('Start a conversation!'), findsOneWidget);
  });
}
