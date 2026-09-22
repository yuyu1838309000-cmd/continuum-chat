import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/tool_tester_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ToolTester separates network failure from an empty tool list', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    late final FakeHttpClient networkClient;
    networkClient = FakeHttpClient((request) {
      if (request.method == 'GET' && request.uri.path == '/mcp/tools') {
        throw const SocketException('connection refused');
      }
      return _configResponse(request);
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        ToolTesterPage(key: UniqueKey(), initialServerName: 'srv'),
        size: const Size(320, 620),
      );
      await _pumpUntilFound(tester, find.textContaining('网络不可达'));

      expect(find.textContaining('网络不可达或 8816 连不上'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => networkClient);

    late final FakeHttpClient emptyClient;
    emptyClient = FakeHttpClient((request) {
      if (request.method == 'GET' && request.uri.path == '/mcp/tools') {
        return FakeHttpResponseData.json({'ok': true, 'tools': const []});
      }
      return _configResponse(request);
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        ToolTesterPage(key: UniqueKey(), initialServerName: 'srv'),
        size: const Size(320, 620),
      );
      await _pumpUntilFound(tester, find.textContaining('当前没有可测试工具'));

      expect(find.textContaining('当前没有可测试工具'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => emptyClient);
  });

  testWidgets('ToolTester shows server missing and tool failure details', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    late final FakeHttpClient missingClient;
    missingClient = FakeHttpClient((request) {
      if (request.method == 'GET' && request.uri.path == '/mcp/tools') {
        return FakeHttpResponseData.json({
          'error': 'srv is not configured',
        }, statusCode: 404);
      }
      return _configResponse(request);
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        ToolTesterPage(key: UniqueKey(), initialServerName: 'srv'),
      );
      await _pumpUntilFound(tester, find.textContaining('Server 不存在'));

      expect(find.textContaining('Server 不存在'), findsOneWidget);
      expect(find.textContaining('srv is not configured'), findsOneWidget);
    }, createHttpClient: (_) => missingClient);

    late final FakeHttpClient failureClient;
    failureClient = FakeHttpClient((request) {
      return switch ((request.method, request.uri.path)) {
        ('GET', '/mcp/tools') => FakeHttpResponseData.json({
          'ok': true,
          'tools': [
            {'name': 'lookup', 'description': 'Lookup data'},
          ],
        }),
        ('POST', '/mcp/test') => FakeHttpResponseData.json({
          'error': 'tool exploded',
        }, statusCode: 500),
        _ => _configResponse(request),
      };
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        ToolTesterPage(key: UniqueKey(), initialServerName: 'srv'),
      );
      await _pumpUntilFound(tester, find.text('lookup'));

      await tester.tap(find.widgetWithText(FilledButton, '发送测试调用'));
      await tester.pump();
      await _pumpUntilFound(tester, find.textContaining('工具调用失败'));

      expect(find.textContaining('HTTP 500'), findsOneWidget);
      expect(find.textContaining('tool exploded'), findsOneWidget);
    }, createHttpClient: (_) => failureClient);
  });
}

FakeHttpResponseData _configResponse(FakeHttpRequestData request) {
  return switch ((request.method, request.uri.path)) {
    ('GET', '/mcp-config') => FakeHttpResponseData.json({
      'servers': [
        {'name': 'srv', 'enabled': true, 'url': 'http://127.0.0.1:9000'},
      ],
    }),
    ('GET', '/skills') => FakeHttpResponseData.json({'skills': const []}),
    ('GET', '/plugin-config') => FakeHttpResponseData.json({
      'plugins': const [],
    }),
    _ => FakeHttpResponseData.json({'error': 'unexpected'}, statusCode: 404),
  };
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(375, 760),
}) async {
  final theme = ThemeData(
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7C59)),
    useMaterial3: true,
  );
  await TestWidgetsFlutterBinding.ensureInitialized().setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(theme: theme, home: child));
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Finder was not found: $finder');
}

void _resetViewAfterTest(WidgetTester tester) {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  addTearDown(() async {
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    await binding.setSurfaceSize(null);
  });
}
