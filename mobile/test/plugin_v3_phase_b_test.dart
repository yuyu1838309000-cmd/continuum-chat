import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/my_plugins_page.dart';
import 'package:continuum_chat/pages/plugin_market_page.dart';
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

  testWidgets(
    'direct install returns to and refreshes the unified plugin list',
    (tester) async {
      final backend = _PhaseBBackend();

      await HttpOverrides.runZoned(() async {
        await _pumpPage(tester, const MyPluginsPage());
        await _pumpUntilFound(tester, find.text('已装命令'));

        await tester.tap(find.byTooltip('添加插件'));
        await _pumpUntilFound(tester, find.text('待装 MCP'));

        expect(find.text('添加插件'), findsOneWidget);
        expect(find.text('插件市场'), findsNothing);
        expect(find.text('MCP'), findsOneWidget);
        expect(find.text('内部'), findsNWidgets(2));
        expect(find.text('直接安装测试'), findsOneWidget);
        expect(find.text('已安装'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, '安装'), findsOneWidget);
        expect(find.text('更多'), findsNWidgets(2));

        await tester.tap(find.widgetWithText(FilledButton, '安装'));
        await tester.pumpAndSettle();
        await _pumpUntilFound(tester, find.text('插件已安装'));

        expect(find.text('已装命令'), findsOneWidget);
        expect(find.text('插件已安装'), findsOneWidget);
        expect(backend.directInstalled, isTrue);
        expect(
          backend.client.requests.where(
            (request) =>
                request.method == 'POST' &&
                request.uri.path == '/plugin-market/install',
          ),
          hasLength(1),
        );
      }, createHttpClient: (_) => backend.client);
    },
  );

  testWidgets('manual MCP save closes add flow and refreshes unified plugins', (
    tester,
  ) async {
    final backend = _PhaseBBackend();

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('已装命令'));

      await tester.tap(find.byTooltip('添加插件'));
      await _pumpUntilFound(tester, find.text('手动添加 MCP'));
      await tester.tap(find.text('手动添加 MCP'));
      await tester.pumpAndSettle();

      expect(find.text('导入 Skill'), findsNothing);
      expect(find.text('HTTP 服务'), findsOneWidget);
      expect(find.text('本地命令'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '名称'), '手动服务');
      await tester.enterText(
        find.widgetWithText(TextField, 'HTTP 地址'),
        'https://example.com/mcp',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _pumpUntilFound(tester, find.text('手动服务'));

      expect(find.text('MCP 已保存'), findsWidgets);
      expect(find.text('插件'), findsOneWidget);
      expect(backend.manualServers.single['source'], 'manual');
    }, createHttpClient: (_) => backend.client);
  });

  testWidgets('add flow handles search empty and failure states', (
    tester,
  ) async {
    final backend = _PhaseBBackend();

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const PluginMarketPage());
      await _pumpUntilFound(tester, find.text('待装 MCP'));

      final search = find.widgetWithText(TextField, '搜索插件');
      await tester.enterText(search, '没有');
      await tester.pump(const Duration(milliseconds: 500));
      await _pumpUntilFound(tester, find.text('没搜到匹配的插件'));

      await tester.enterText(search, '失败');
      await tester.pump(const Duration(milliseconds: 500));
      await _pumpUntilFound(tester, find.textContaining('拉取插件市场失败'));
      expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => backend.client);
  });

  testWidgets('add flow fits compact light and dark widths', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    addTearDown(() => binding.setSurfaceSize(null));
    final backend = _PhaseBBackend();
    final appTheme = themes[AppThemeId.midnightGold]!;

    await HttpOverrides.runZoned(() async {
      for (final width in <double>[320, 375, 414]) {
        await binding.setSurfaceSize(Size(width, 760));
        for (final theme in [appTheme.light, appTheme.dark]) {
          await _pumpPage(tester, const PluginMarketPage(), theme: theme);
          await _pumpUntilFound(tester, find.text('待装 MCP'));

          expect(find.byType(SettingCard), findsNWidgets(2));
          expect(
            tester.takeException(),
            isNull,
            reason: '${theme.brightness.name} ${width.toInt()}px',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    }, createHttpClient: (_) => backend.client);
  });
}

class _PhaseBBackend {
  _PhaseBBackend() {
    client = FakeHttpClient(_handle);
  }

  late FakeHttpClient client;
  bool directInstalled = false;
  List<Map<String, dynamic>> manualServers = [];

  FakeHttpResponseData _handle(FakeHttpRequestData request) {
    return switch ((request.method, request.uri.path)) {
      ('GET', '/mcp-config') => FakeHttpResponseData.json({
        'servers': [
          if (directInstalled)
            {
              'id': 'direct-mcp',
              'name': '待装 MCP',
              'type': 'remote',
              'url': 'https://example.com/direct',
              'enabled': true,
            },
          ...manualServers,
        ],
      }),
      ('POST', '/mcp-config') => _saveMcp(request),
      ('GET', '/plugin-config') => FakeHttpResponseData.json({
        'plugins': [
          {'id': 'installed-command', 'name': '已装命令', 'enabled': true},
        ],
      }),
      ('GET', '/skills') => FakeHttpResponseData.json({'skills': const []}),
      ('GET', '/plugin-market') => _market(request),
      ('POST', '/plugin-market/install') => _install(request),
      _ => FakeHttpResponseData.json({'ok': true}),
    };
  }

  FakeHttpResponseData _market(FakeHttpRequestData request) {
    final query = request.uri.queryParameters['q'] ?? '';
    if (query == '失败') {
      return FakeHttpResponseData.json({
        'error': 'market unavailable',
      }, statusCode: 500);
    }
    final plugins = query == '没有'
        ? const <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            {
              'id': 'direct-mcp',
              'name': '待装 MCP',
              'type': 'mcp',
              'source': 'internal',
              'description': '直接安装测试',
              'installed': directInstalled,
            },
            {
              'id': 'installed-command',
              'name': '已装命令',
              'type': 'command',
              'source': 'internal',
              'description': '已经存在的插件',
              'installed': true,
            },
          ];
    return FakeHttpResponseData.json({'plugins': plugins, 'has_more': false});
  }

  FakeHttpResponseData _install(FakeHttpRequestData request) {
    expect(request.jsonBody['id'], 'direct-mcp');
    expect(request.jsonBody['source'], 'internal');
    directInstalled = true;
    return FakeHttpResponseData.json({'ok': true, 'installed': true});
  }

  FakeHttpResponseData _saveMcp(FakeHttpRequestData request) {
    manualServers = (request.jsonBody['servers'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .toList();
    return FakeHttpResponseData.json({'ok': true});
  }
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
  await tester.pump();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = [
    for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
  ].join(' | ');
  fail('Finder was not found: $finder; visibleText=$visibleText');
}
