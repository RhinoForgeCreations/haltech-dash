import 'package:flutter_test/flutter_test.dart';
import 'package:haltech_dash/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const HaltechApp());
    expect(find.text('DISCONNECTED'), findsOneWidget);
  });
}
