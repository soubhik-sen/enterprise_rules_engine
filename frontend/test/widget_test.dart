import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';

void main() {
  testWidgets('Enterprise studio renders core shell',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(2200, 1200));
    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pumpAndSettle();

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('TABLE SETTINGS'), findsOneWidget);
    expect(find.text('Test Bench'), findsOneWidget);

    await tester.binding.setSurfaceSize(null);
  });
}
