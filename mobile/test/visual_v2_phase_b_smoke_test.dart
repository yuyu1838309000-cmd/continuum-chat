import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/assistant_hub_page.dart';
import 'package:continuum_chat/pages/config_center_page.dart';
import 'package:continuum_chat/pages/history_hub_page.dart';
import 'package:continuum_chat/pages/overview_drawer.dart';
import 'package:continuum_chat/pages/settings_page.dart';
import 'package:continuum_chat/pages/together_hub_page.dart';
import 'package:continuum_chat/pages/toolbox_page.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Continuum Chat',
      packageName: 'app.continuum.frontend',
      version: '0.0.0-test',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('Phase B main IA fits phone widths in light and dark', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final fakeClient = FakeHttpClient(
      (_) => FakeHttpResponseData.json({'allow_proactive': true}),
    );

    await HttpOverrides.runZoned(() async {
      for (final width in <double>[320, 375, 414]) {
        await binding.setSurfaceSize(Size(width, 760));
        for (final brightness in Brightness.values) {
          final appTheme = themes[AppThemeId.midnightGold]!;
          final theme = brightness == Brightness.light
              ? appTheme.light
              : appTheme.dark;
          final pages = <Widget>[
            const HistoryHubPage(currentMessages: []),
            const AssistantHubPage(),
            const TogetherHubPage(),
            const ToolboxPage(title: '能力'),
            const ConfigCenterPage(),
            const SettingsPage(),
            _drawerFixture(width),
          ];

          for (final page in pages) {
            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                themeAnimationDuration: Duration.zero,
                home: page,
              ),
            );
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason:
                  '${page.runtimeType} ${brightness.name} ${width.toInt()}px',
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
        }
      }
    }, createHttpClient: (_) => fakeClient);
  });

  testWidgets('Assistant hero uses the opaque semantic card layer', (
    tester,
  ) async {
    final appTheme = themes[AppThemeId.midnightGold]!;

    for (final theme in [appTheme.light, appTheme.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: AssistantHubPage(moodLoader: ({onCached}) async => null),
        ),
      );
      await tester.pump();
      final cardColor = theme.extension<AppSemanticColors>()!.card;
      final hero = find.byKey(const ValueKey('assistant_profile_hero'));
      final heroMaterial = find.descendant(
        of: hero,
        matching: find.byType(Material),
      );

      expect(hero, findsOneWidget);
      expect(heroMaterial, findsWidgets);
      expect(
        tester.widget<Material>(heroMaterial.first).color,
        tester.element(hero).semanticColors.card,
      );
      expect(tester.element(hero).semanticColors.card, cardColor);
      expect(cardColor.a, 1);
      expect(tester.takeException(), isNull);
    }
  });
}

Widget _drawerFixture(double width) {
  return Scaffold(
    body: Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(width: width * 0.8, child: const OverviewDrawer()),
    ),
  );
}
