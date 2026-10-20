import 'package:flutter_test/flutter_test.dart';
import 'package:sequenzy_example/main.dart';

void main() {
  testWidgets('shows the sign-in form', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    expect(find.text('Sequenzy example'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
