import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/my_plugins_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('MCP toggle rolls back on save failure and ignores repeat taps', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    final save = Completer<FakeHttpResponseData>();
    var saveCalls = 0;
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      return switch ((request.method, request.uri.path)) {
        ('GET', '/mcp-config') => FakeHttpResponseData.json({
          'servers': [
            {
              'id': 'local',
              'name': 'local server',
              'enabled': true,
              'url': 'http://127.0.0.1:9000',
            },
          ],
        }),
        ('GET', '/plugin-config') => FakeHttpResponseData.json({
          'plugins': const [],
        }),
        ('GET', '/skills') => FakeHttpResponseData.json({'skills': const []}),
        ('POST', '/mcp-config') => () {
          saveCalls++;
          expect(request.jsonBody['servers'], isA<List<dynamic>>());
          expect(
            (request.jsonBody['servers'] as List<dynamic>).first,
            containsPair('enabled', false),
          );
          return save.future;
        }(),
        _ => FakeHttpResponseData.json({
          'error': 'unexpected',
        }, statusCode: 404),
      };
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        const MyPluginsPage(),
        size: const Size(320, 568),
      );
      await _pumpUntilFound(tester, find.text('local server'));

      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(saveCalls, 1);
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(saveCalls, 1);

      save.complete(
        FakeHttpResponseData.json({'error': 'write failed'}, statusCode: 500),
      );
      await _pumpUntilFound(tester, find.textContaining('已恢复原状态'));

      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      expect(find.textContaining('已恢复原状态'), findsWidgets);
      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Skill delete restores the row when deleteSkill returns null', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    final delete = Completer<FakeHttpResponseData>();
    var deleteCalls = 0;
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      return switch ((request.method, request.uri.path)) {
        ('GET', '/mcp-config') => FakeHttpResponseData.json({
          'servers': const [],
        }),
        ('GET', '/plugin-config') => FakeHttpResponseData.json({
          'plugins': const [],
        }),
        ('GET', '/skills') => FakeHttpResponseData.json({
          'skills': [
            {
              'id': 'skill-a',
              'name': '技能 A',
              'description': '用于删除回滚测试',
              'enabled': true,
            },
          ],
        }),
        ('POST', '/skills') => () {
          deleteCalls++;
          expect(request.jsonBody, {'action': 'delete', 'name': 'skill-a'});
          return delete.future;
        }(),
        _ => FakeHttpResponseData.json({
          'error': 'unexpected',
        }, statusCode: 404),
      };
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const MyPluginsPage());
      await _pumpUntilFound(tester, find.text('技能 A'));

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();

      expect(deleteCalls, 1);
      expect(find.text('技能 A'), findsNothing);

      delete.complete(
        FakeHttpResponseData.json({'error': 'delete failed'}, statusCode: 500),
      );
      await _pumpUntilFound(tester, find.text('技能 A'));

      expect(find.text('技能 A'), findsOneWidget);
      expect(find.textContaining('Skill 删除失败'), findsOneWidget);
    }, createHttpClient: (_) => client);
  });
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
