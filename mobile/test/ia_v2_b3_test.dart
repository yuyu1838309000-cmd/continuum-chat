import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/assistant_hub_page.dart';
import 'package:continuum_chat/pages/my_plugins_page.dart';
import 'package:continuum_chat/pages/profile_page.dart';
import 'package:continuum_chat/pages/reading_page.dart';
import 'package:continuum_chat/pages/self_prompt_memory_page.dart';
import 'package:continuum_chat/pages/self_prompt_page.dart';
import 'package:continuum_chat/pages/self_prompt_system_page.dart';
import 'package:continuum_chat/pages/settings_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';
import 'support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory cacheDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Continuum Chat',
      packageName: 'app.continuum.frontend',
      version: '0.0.0-test',
      buildNumber: '1',
      buildSignature: '',
    );
    await ServerConfig.instance.setHost('127.0.0.1');
    originalPathProvider = PathProviderPlatform.instance;
    cacheDirectory = await Directory.systemTemp.createTemp('ia_v2_b3_test_');
    PathProviderPlatform.instance = FakePathProvider(cacheDirectory.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  testWidgets('Settings V2 groups user options and opens advanced settings', (
    tester,
  ) async {
    await _withFakeBackend(tester, () async {
      await _pumpPage(
        tester,
        const SettingsPage(),
        size: const Size(414, 1100),
      );
      await _pumpUntilFound(tester, find.text('高级设置'));

      for (final group in ['聊天', '外观', '权限与通知', '高级', '关于']) {
        expect(find.text(group), findsOneWidget);
      }
      expect(find.text('快捷消息管理'), findsOneWidget);
      for (final removed in ['工具箱', '配置中心', '提示词']) {
        expect(find.text(removed), findsNothing);
      }

      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();

      expect(find.text('高级设置'), findsOneWidget);
      expect(find.text('工具测试器'), findsOneWidget);
      expect(find.text('共读探针'), findsOneWidget);
      expect(
        find.text('历史迁移预演'),
        ServerConfig.isCandidateRuntime ? findsOneWidget : findsNothing,
      );
    });
  });

  testWidgets('Assistant and profile flows use product-facing concepts', (
    tester,
  ) async {
    await _withFakeBackend(tester, () async {
      await _pumpPage(tester, const AssistantHubPage());
      expect(
        find.byKey(const ValueKey('assistant_profile_hero')),
        findsOneWidget,
      );
      for (final label in ['当前心情', '个人内容', '相处偏好']) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.text('相处偏好'));
      await _pumpUntilFound(tester, find.text('相处偏好'));
      await _pumpUntilFound(tester, find.text('日常相处'));

      expect(find.textContaining('长按卡片可以调整顺序'), findsOneWidget);
      expect(find.text('0 条'), findsOneWidget);
      for (final internalTerm in ['提示词管理', '【用户设定】', '【系统提示词】']) {
        expect(find.textContaining(internalTerm), findsNothing);
      }

      await _pumpPage(tester, const ProfilePage(), size: const Size(375, 900));
      final assistantTop = tester.getTopLeft(find.text('AI 助手')).dy;
      final participantTop = tester.getTopLeft(find.text('用户').first).dy;
      expect(assistantTop, lessThan(participantTop));
      await tester.scrollUntilVisible(
        find.text('长期说明'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('长期说明'), findsOneWidget);
      expect(find.textContaining('点击换图'), findsNothing);
      expect(find.textContaining('改完我会知道'), findsNothing);
      expect(find.text('自我提示'), findsNothing);
    });
  });

  testWidgets('Long-term description pages hide prompt assembly language', (
    tester,
  ) async {
    await _withFakeBackend(tester, () async {
      await _pumpPage(tester, const SelfPromptPage());
      expect(find.text('长期说明'), findsOneWidget);
      expect(find.text('身份与性格'), findsOneWidget);
      expect(find.text('想记住的事'), findsOneWidget);
      expect(find.text('系统提示词'), findsNothing);

      await _pumpPage(tester, const SelfPromptSystemPage());
      await _pumpUntilFound(tester, find.textContaining('AI 助手会在聊天中遵循'));
      expect(find.text('身份与性格'), findsOneWidget);
      expect(find.textContaining('注入'), findsNothing);
      expect(find.textContaining('系统提示词'), findsNothing);

      await _pumpPage(tester, const SelfPromptMemoryPage());
      expect(find.text('想记住的事'), findsOneWidget);
      expect(find.byTooltip('添加一件事'), findsOneWidget);
      expect(find.textContaining('注入'), findsNothing);
      expect(find.textContaining('【记忆】'), findsNothing);
    });
  });

  testWidgets('Regular reading and installed-plugin flows hide diagnostics', (
    tester,
  ) async {
    await _withFakeBackend(tester, () async {
      await _pumpPage(tester, const ReadingPage());
      expect(find.byTooltip('共读探针'), findsNothing);
      expect(find.text('共读探针'), findsNothing);

      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('本地服务'));
      expect(find.byTooltip('测试'), findsNothing);
      expect(find.text('工具测试器'), findsNothing);
    });
  });

  testWidgets('Manual MCP save no longer offers a tester shortcut', (
    tester,
  ) async {
    await _withFakeBackend(tester, () async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('本地服务'));
      await tester.tap(find.byTooltip('添加插件'));
      await _pumpUntilFound(tester, find.text('手动添加 MCP'));
      await tester.tap(find.text('手动添加 MCP'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '名称'), '手动服务');
      await tester.enterText(
        find.widgetWithText(TextField, 'HTTP 地址'),
        'https://example.com/mcp',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await _pumpUntilFound(tester, find.text('MCP 已保存'));

      expect(find.text('测试'), findsNothing);
      expect(find.byType(SnackBarAction), findsNothing);
      expect(find.text('工具测试器'), findsNothing);
    });
  });
}

Future<void> _withFakeBackend(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final client = FakeHttpClient((request) {
    return switch ((request.method, request.uri.path)) {
      ('GET', '/status') => FakeHttpResponseData.json({
        'allow_proactive': true,
      }),
      ('GET', '/prompts') => FakeHttpResponseData.json({
        'active': 'default',
        'prompts': {
          'default': {
            'sections': [
              {'title': '日常相处', 'items': const []},
            ],
          },
        },
      }),
      ('GET', '/self-prompt') => FakeHttpResponseData.json({
        'system_prompt': '温柔、坦诚',
        'memories': ['一件值得记住的事'],
      }),
      ('GET', '/read_data.json') => FakeHttpResponseData.json({}),
      ('GET', '/mcp-config') => FakeHttpResponseData.json({
        'servers': [
          {
            'id': 'local',
            'name': '本地服务',
            'enabled': true,
            'url': 'http://127.0.0.1:9000',
          },
        ],
      }),
      ('POST', '/mcp-config') => FakeHttpResponseData.json({'ok': true}),
      ('GET', '/plugin-config') => FakeHttpResponseData.json({
        'plugins': const [],
      }),
      ('GET', '/skills') => FakeHttpResponseData.json({'skills': const []}),
      ('GET', '/plugin-market') => FakeHttpResponseData.json({
        'plugins': const [],
        'has_more': false,
      }),
      _ => FakeHttpResponseData.json({'ok': true}),
    };
  });

  await HttpOverrides.runZoned(body, createHttpClient: (_) => client);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  Size size = const Size(375, 760),
}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  addTearDown(() => binding.setSurfaceSize(null));
  await binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7C59)),
        useMaterial3: true,
      ),
      home: page,
    ),
  );
  await tester.pump();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = [
    for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
  ].join(' | ');
  fail('Finder was not found: $finder; visibleText=$visibleText');
}
