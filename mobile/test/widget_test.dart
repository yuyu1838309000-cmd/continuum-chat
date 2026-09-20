import 'package:continuum_chat/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the five destinations and navigates to History', (
    tester,
  ) async {
    await tester.pumpWidget(const ContinuumApp());
    await tester.pump();

    expect(find.text('Continuum Chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-memory')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-tools')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-settings')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-history')));
    await tester.pump();

    expect(find.text('History'), findsWidgets);
  });
}
