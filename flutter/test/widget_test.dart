// Smoke test for the SIM-bridge app shell: it builds with demo
// data and shows the five tabs.

import 'package:flutter_test/flutter_test.dart';
import 'package:sim_bridge/src/ui/ui.dart';

void main() {
  testWidgets('App builds and shows all five tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(SimBridgeApp(model: AppModel.demo()));

    expect(find.text('تماس‌ها'), findsOneWidget);
    expect(find.text('مخاطبین'), findsOneWidget);
    expect(find.text('شماره‌گیر'), findsOneWidget);
    expect(find.text('پیام‌ها'), findsOneWidget);
    expect(find.text('اتصال'), findsOneWidget);
    // Demo data renders on the first tab (Recents).
    expect(find.text('سارا احمدی'), findsWidgets);
  });
}
