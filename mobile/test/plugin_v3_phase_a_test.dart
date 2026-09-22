import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/my_plugins_page.dart';
import 'package:continuum_chat/pages/toolbox_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:continuum_chat/widgets/setting_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
  });

  testWidgets('Plugin V3 uses one Toolbox entry and one flat plugin list', (
    tester,
  ) async {
    final client = _pluginClient();

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const ToolboxPage(title: '能力'));

      expect(find.text('插件'), findsOneWidget);
      expect(find.text('插件市场'), findsNothing);
      expect(find.text('我的插件'), findsNothing);

      await tester.tap(find.text('插件'));
      await _pumpUntilFound(tester, find.text('MCP Alpha'));

      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.byTooltip('添加插件'), findsOneWidget);
      for (final sectionTitle in ['MCP 工具', 'Skill 技能', '命令工具']) {
        expect(find.text(sectionTitle), findsNothing);
      }
      for (final name in ['MCP Alpha', '技能 Alpha', '命令 Alpha']) {
        expect(find.text(name), findsOneWidget);
      }
      for (final type in ['MCP', 'Skill', '命令']) {
        expect(find.text(type), findsOneWidget);
      }

      await tester.tap(find.text('MCP Alpha'));
      await _pumpUntilFound(tester, find.text('编辑 MCP 工具'));
      expect(find.text('编辑 MCP 工具'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _pumpUntilFound(tester, find.text('MCP Alpha'));

      await tester.tap(find.text('命令 Alpha'));
      await _pumpUntilFound(tester, find.text('编辑命令工具'));
      expect(find.text('编辑命令工具'), findsOneWidget);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Plugin V3 rolls back a failed toggle operation', (tester) async {
    final client = _pluginClient(failWrites: true);

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('MCP Alpha'));

      await tester.tap(find.byType(Switch).first);
      await _pumpUntilFound(tester, find.textContaining('已恢复原状态'));
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Plugin V3 rolls back a failed overflow delete operation', (
    tester,
  ) async {
    final client = _pluginClient(failWrites: true);

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('技能 Alpha'));

      final skillCard = find.ancestor(
        of: find.text('技能 Alpha'),
        matching: find.byType(SettingCard),
      );
      final skillMenu = find.descendant(
        of: skillCard,
        matching: find.byTooltip('更多操作'),
      );
      await tester.tap(skillMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await _pumpUntilFound(tester, find.textContaining('Skill 删除失败'));

      expect(find.text('技能 Alpha'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Plugin V3 fits compact widths in light and dark themes', (
    tester,
  ) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final appTheme = themes[AppThemeId.midnightGold]!;
    final client = _pluginClient();

    await HttpOverrides.runZoned(() async {
      for (final width in <double>[320, 375, 414]) {
        await binding.setSurfaceSize(Size(width, 760));
        for (final theme in [appTheme.light, appTheme.dark]) {
          await _pumpPage(tester, const MyPluginsPage(), theme: theme);
          await _pumpUntilFound(tester, find.text('MCP Alpha'));

          expect(find.byTooltip('更多操作'), findsNWidgets(3));
          expect(
            tester.takeException(),
            isNull,
            reason: '${theme.brightness.name} ${width.toInt()}px',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    }, createHttpClient: (_) => client);
  });

  testWidgets('Plugin V3 empty state offers add plugin directly', (
    tester,
  ) async {
    final client = _pluginClient(empty: true);

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('还没有安装插件'));

      expect(find.widgetWithText(FilledButton, '添加插件'), findsOneWidget);
      expect(find.text('工具测试器'), findsNothing);
    }, createHttpClient: (_) => client);
  });
}

FakeHttpClient _pluginClient({bool failWrites = false, bool empty = false}) {
  return FakeHttpClient((request) {
    return switch ((request.method, request.uri.path)) {
      ('GET', '/mcp-config') => FakeHttpResponseData.json({
        'servers': empty
            ? const []
            : [
                {
                  'id': 'mcp-alpha',
                  'name': 'MCP Alpha',
                  'enabled': true,
                  'type': 'remote',
                  'url': 'https://example.com/mcp',
                },
              ],
      }),
      ('GET', '/plugin-config') => FakeHttpResponseData.json({
        'plugins': empty
            ? const []
            : [
                {
                  'id': 'command-alpha',
                  'name': '命令 Alpha',
                  'description': '测试命令',
                  'enabled': true,
                },
              ],
      }),
      ('GET', '/skills') => FakeHttpResponseData.json({
        'skills': empty
            ? const []
            : [
                {
                  'id': 'skill-alpha',
                  'name': '技能 Alpha',
                  'description': '测试技能',
                  'enabled': true,
                },
              ],
      }),
      ('POST', '/mcp-config') =>
        failWrites
            ? FakeHttpResponseData.json({
                'error': 'write failed',
              }, statusCode: 500)
            : FakeHttpResponseData.json({'ok': true}),
      ('POST', '/skills') =>
        failWrites
            ? FakeHttpResponseData.json({
                'error': 'delete failed',
              }, statusCode: 500)
            : FakeHttpResponseData.json({'ok': true}),
      _ => FakeHttpResponseData.json({'ok': true}),
    };
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? themes[AppThemeId.midnightGold]!.light,
      themeAnimationDuration: Duration.zero,
      home: child,
    ),
  );
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Finder was not found: $finder');
}
