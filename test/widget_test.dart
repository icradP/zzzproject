import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zzzproject/src/app/zzz_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ZZZ chat shell renders', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const ZzzApp());
    await tester.pump();
  });
}
