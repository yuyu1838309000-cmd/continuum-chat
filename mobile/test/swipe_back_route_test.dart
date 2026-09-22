import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:continuum_chat/widgets/swipe_back.dart';

void main() {
  test('Android uses material transition while iOS keeps Cupertino', () {
    final transitions =
        AppThemeManager.instance.currentTheme.light.pageTransitionsTheme;

    expect(
      transitions.builders[TargetPlatform.android],
      isA<FadeUpwardsPageTransitionsBuilder>(),
    );
    expect(
      transitions.builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
  });

  testWidgets('SwipeBackRoute stays short and right swipe pops', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  SwipeBackRoute<void>(
                    builder: (_) => const Scaffold(body: Text('detail')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final route =
        ModalRoute.of(tester.element(find.text('detail')))!
            as SwipeBackRoute<void>;
    expect(route.transitionDuration, const Duration(milliseconds: 160));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 120));

    await tester.fling(find.byType(SwipeBackWrap), const Offset(140, 0), 800);
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('detail'), findsNothing);
  });
}
