import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/theme_settings_page.dart';
import 'package:continuum_chat/utils/app_theme.dart';

void main() {
  test(
    'theme ids remain stable and every palette exposes light/dark roles',
    () {
      expect(AppThemeId.values.map((id) => id.key), const [
        'midnight_gold',
        'cream_warm',
        'mint',
        'lavender',
        'mono',
      ]);

      for (final id in AppThemeId.values) {
        final appTheme = themes[id];
        expect(appTheme, isNotNull, reason: id.key);
        for (final theme in [appTheme!.light, appTheme.dark]) {
          final colors = theme.extension<AppSemanticColors>();
          expect(colors, isNotNull, reason: '${id.key} ${theme.brightness}');
          expect(theme.colorScheme.surface, colors!.base);
          expect(theme.colorScheme.surfaceContainerLow, colors.layer);
          expect(theme.colorScheme.surfaceContainer, colors.card);
          expect(theme.colorScheme.surfaceContainerHigh, colors.elevated);
          expect(theme.colorScheme.surfaceContainerHighest, colors.field);
          expect(theme.colorScheme.primaryContainer, colors.assistantBubble);
          expect(theme.colorScheme.secondaryContainer, colors.userBubble);
          expect(theme.colorScheme.tertiaryContainer, colors.process);
          expect(theme.cardTheme.color, colors.card);
          expect(theme.inputDecorationTheme.fillColor, colors.field);
          expect(theme.dividerTheme.color, colors.stroke);
          expect(theme.dialogTheme.backgroundColor, colors.elevated);
          expect(theme.bottomSheetTheme.backgroundColor, colors.elevated);

          if (theme.brightness == Brightness.dark) {
            expect(colors.base.a, 1, reason: '${id.key} dark base is opaque');
            expect(colors.card.a, 1, reason: '${id.key} dark card is opaque');
            expect(colors.field.a, 1, reason: '${id.key} dark field is opaque');
            expect(
              colors.process.a,
              1,
              reason: '${id.key} dark process is opaque',
            );
            expect(colors.base, isNot(colors.card));
            expect(colors.card, isNot(colors.field));
          }
        }
      }
    },
  );

  testWidgets('theme cards preview the effective light/dark palette', (
    tester,
  ) async {
    final defaultTheme = themes[AppThemeId.midnightGold]!;

    for (final dark in [false, true]) {
      await tester.binding.setSurfaceSize(const Size(375, 1800));
      await tester.pumpWidget(
        MaterialApp(
          theme: defaultTheme.light,
          darkTheme: defaultTheme.dark,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const ThemeSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      for (final id in AppThemeId.values) {
        final expectedTheme = dark ? themes[id]!.dark : themes[id]!.light;
        final expectedColors = expectedTheme.extension<AppSemanticColors>()!;
        final preview = tester.widget<Container>(
          find.byKey(ValueKey('theme-preview-${id.key}')),
        );
        expect(
          (preview.decoration! as BoxDecoration).color,
          expectedColors.base,
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == '${id.label}${dark ? '深色' : '浅色'}预览',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('theme settings has no horizontal overflow at phone widths', (
    tester,
  ) async {
    final appTheme = themes[AppThemeId.midnightGold]!;
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final width in <double>[320, 375, 414]) {
      await tester.binding.setSurfaceSize(Size(width, 720));
      await tester.pumpWidget(
        MaterialApp(theme: appTheme.light, home: const ThemeSettingsPage()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width top');

      await tester.drag(find.byType(ListView), const Offset(0, -1400));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'width $width bottom');
    }
  });
}
