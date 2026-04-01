import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/main.dart';

void main() {
  testWidgets('App starts without errors', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: HandWriterApp()),
    );
    await tester.pump();

    // Login screen should be visible
    expect(find.text('HandWriter'), findsOneWidget);
  });
}
