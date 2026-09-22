import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/model_config_page.dart';
import 'package:continuum_chat/services/chat_api.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
  });

  test(
    'discoverModels posts unsaved provider config and parses success',
    () async {
      late FakeHttpRequestData captured;
      final client = FakeHttpClient((request) {
        captured = request;
        return FakeHttpResponseData.json({
          'ok': true,
          'models': ['alpha', 'beta'],
          'count': 2,
          'latency_ms': 18,
          'fetched_at': '2026-09-03T12:00:00+08:00',
        });
      });

      final result = await HttpOverrides.runZoned(
        () => ChatApi.discoverModels('custom', {
          'base_url': 'https://models.example/v1',
          'model': 'draft-model',
          'temperature': 0.7,
        }),
        createHttpClient: (_) => client,
      );

      expect(captured.method, 'POST');
      expect(captured.uri.path, '/models/discover');
      expect(captured.jsonBody, {
        'provider': 'custom',
        'config': {
          'base_url': 'https://models.example/v1',
          'model': 'draft-model',
          'temperature': 0.7,
        },
      });
      expect(result?['ok'], isTrue);
      expect(result?['models'], ['alpha', 'beta']);
    },
  );

  test('discoverModels preserves a structured server failure', () async {
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData.json({
        'ok': false,
        'models': const [],
        'error': '供应商暂时不可用',
      }, statusCode: 502),
    );

    final result = await HttpOverrides.runZoned(
      () => ChatApi.discoverModels('gemini', const {}),
      createHttpClient: (_) => client,
    );

    expect(result, {'ok': false, 'models': const [], 'error': '供应商暂时不可用'});
  });

  testWidgets(
    'refresh keeps a saved model missing online, deduplicates, and never saves',
    (tester) async {
      final client = _modelClient(
        discoverResponse: {
          'ok': true,
          'models': ['online-a', 'online-a', 'online-b'],
          'count': 3,
          'latency_ms': 24,
        },
      );

      await HttpOverrides.runZoned(() async {
        await _pumpPage(tester);
        await _openProvider(tester, 'DeepSeek');

        expect(find.text('连接'), findsOneWidget);
        expect(find.text('模型'), findsOneWidget);
        expect(find.text('生成设置'), findsOneWidget);
        expect(find.text('legacy-model'), findsWidgets);
        expect(find.text('已发现 2 个在线模型 · 24ms'), findsOneWidget);

        await tester.tap(find.text('legacy-model').last);
        await tester.pumpAndSettle();
        expect(find.text('online-a'), findsOneWidget);
        expect(find.text('online-b'), findsOneWidget);
        await tester.tap(find.text('legacy-model').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('刷新在线模型'));
        await tester.pumpAndSettle();

        expect(find.text('legacy-model'), findsWidgets);
        expect(
          client.requests.where(
            (request) =>
                request.method == 'POST' &&
                request.uri.path == '/models/discover',
          ),
          hasLength(2),
        );
        expect(
          client.requests.where(
            (request) =>
                request.method == 'POST' && request.uri.path == '/model-config',
          ),
          isEmpty,
        );
      }, createHttpClient: (_) => client);
    },
  );

  testWidgets(
    'discover failure keeps current model and manual input available',
    (tester) async {
      final client = _modelClient(
        discoverResponse: {
          'ok': false,
          'models': const [],
          'error': '获取模型失败，请稍后重试',
        },
      );

      await HttpOverrides.runZoned(() async {
        await _pumpPage(tester);
        await _openProvider(tester, 'OpenRouter');

        expect(find.text('legacy-openrouter'), findsWidgets);
        expect(find.text('获取模型失败，请稍后重试'), findsOneWidget);
        expect(find.text('重试'), findsOneWidget);

        await tester.tap(find.text('legacy-openrouter').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('手动输入…').last);
        await tester.pumpAndSettle();

        expect(find.text('手动输入模型'), findsOneWidget);
        expect(
          client.requests.where(
            (request) =>
                request.method == 'POST' && request.uri.path == '/model-config',
          ),
          isEmpty,
        );
      }, createHttpClient: (_) => client);
    },
  );

  testWidgets(
    'all provider types use discovery without compact-width overflow',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() => binding.setSurfaceSize(null));
      final appTheme = themes[AppThemeId.midnightGold]!;
      final client = _modelClient(
        discoverResponse: {
          'ok': true,
          'models': ['live-model-a', 'live-model-b'],
          'count': 2,
          'latency_ms': 11,
        },
      );

      await HttpOverrides.runZoned(() async {
        for (final width in <double>[320, 375, 414]) {
          await binding.setSurfaceSize(Size(width, 900));
          for (final theme in [appTheme.light, appTheme.dark]) {
            await _pumpPage(tester, theme: theme);
            for (final provider in [
              'DeepSeek',
              'Gemini',
              'OpenRouter',
              '自定义',
            ]) {
              await _openProvider(tester, provider);
              expect(find.byTooltip('刷新在线模型'), findsOneWidget);
              expect(tester.takeException(), isNull);
              Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
              await tester.pumpAndSettle();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          }
        }
      }, createHttpClient: (_) => client);

      final discoveredProviders = client.requests
          .where((request) => request.uri.path == '/models/discover')
          .map((request) => request.jsonBody['provider'])
          .toSet();
      expect(
        discoveredProviders,
        containsAll(['deepseek', 'gemini', 'openrouter', 'custom']),
      );
    },
  );
}

FakeHttpClient _modelClient({required Map<String, dynamic> discoverResponse}) {
  return FakeHttpClient((request) {
    return switch ((request.method, request.uri.path)) {
      ('GET', '/model-config') => FakeHttpResponseData.json(_modelConfig()),
      ('GET', '/balance') => FakeHttpResponseData.json({
        'ok': false,
        'error': 'balance unavailable in test',
      }),
      ('POST', '/models/discover') => FakeHttpResponseData.json(
        discoverResponse,
        statusCode: discoverResponse['ok'] == true ? 200 : 502,
      ),
      _ => FakeHttpResponseData.json({
        'ok': false,
        'error': 'unexpected ${request.method} ${request.uri.path}',
      }, statusCode: 404),
    };
  });
}

Map<String, dynamic> _modelConfig() => {
  'active': 'deepseek',
  'providers': {
    'deepseek': _provider(model: 'legacy-model'),
    'gemini': {
      ..._provider(model: 'legacy-gemini'),
      'top_k': null,
      'thinking': true,
      'thinking_mode': 'level',
      'thinking_level': 'MEDIUM',
      'thinking_budget': null,
    },
    'openrouter': _provider(model: 'legacy-openrouter'),
    'custom': {..._provider(model: 'legacy-custom'), 'name': '自定义'},
  },
};

Map<String, dynamic> _provider({required String model}) => {
  'base_url': 'https://models.example/v1',
  'model': model,
  'api_key': '已配置',
  'temperature': 1.0,
  'top_p': 1.0,
  'max_tokens': null,
  'thinking': true,
  'reasoning_effort': 'high',
  'timeout': 60,
  'extra_params': const {},
  'configured': true,
};

Future<void> _pumpPage(WidgetTester tester, {ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? themes[AppThemeId.midnightGold]!.light,
      home: const ModelConfigPage(),
    ),
  );
  await _pumpUntilFound(tester, find.text('DeepSeek'));
}

Future<void> _openProvider(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await tester.pumpAndSettle();
  await _pumpUntilFound(tester, find.text('连接'));
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}
