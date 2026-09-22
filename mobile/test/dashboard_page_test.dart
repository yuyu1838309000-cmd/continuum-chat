import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/dashboard_page.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Dashboard ignores an in-flight refresh after dispose', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    final pending = Completer<FakeHttpResponseData>();
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'GET');
      expect(request.uri.path, '/status');
      return pending.future;
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(tester, const DashboardPage());
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      pending.complete(_statusResponse(usedMb: 128));
      await tester.pump();

      expect(tester.takeException(), isNull);
    }, createHttpClient: (_) => client);
  });

  testWidgets('Dashboard silent refresh failure keeps stale data visible', (
    tester,
  ) async {
    _resetViewAfterTest(tester);
    await ServerConfig.instance.setHost('127.0.0.1');
    var calls = 0;
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      calls++;
      if (calls == 1) return _statusResponse(usedMb: 128);
      return FakeHttpResponseData.json({
        'error': 'backend down',
      }, statusCode: 500);
    });

    await HttpOverrides.runZoned(() async {
      await _pumpPage(
        tester,
        const DashboardPage(),
        size: const Size(320, 620),
      );
      await _pumpUntilFound(tester, find.text('128 MB'));
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 31));
      await _pumpUntilFound(tester, find.textContaining('显示旧数据'));

      expect(calls, 2);
      expect(find.text('128 MB'), findsOneWidget);
      expect(find.textContaining('刷新失败，显示旧数据'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    }, createHttpClient: (_) => client);
  });
}

FakeHttpResponseData _statusResponse({required int usedMb}) {
  return FakeHttpResponseData.json({
    'system': {
      'ts': '2026-08-30T13:04:20.040421+08:00',
      'memory': {
        'used_mb': usedMb,
        'total_mb': 1024,
        'avail_mb': 896,
        'percent': 12.5,
      },
      'disk': {'used_gb': 20, 'total_gb': 100, 'free_gb': 80, 'percent': 20},
      'cpu': {
        'percent': 8,
        'cores': 4,
        'load1': 0.1,
        'load5': 0.2,
        'load15': 0.3,
      },
      'ports': [
        {'name': '8816', 'alive': true},
      ],
    },
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
