// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:usb_hid_example/main.dart';

void main() {
  testWidgets('App renders device list UI', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify the app bar title and main action buttons are present.
    expect(find.text('Plugin example app'), findsOneWidget);
    expect(find.text('Request device'), findsOneWidget);
    expect(find.text('Refresh devices'), findsOneWidget);
  });
}
