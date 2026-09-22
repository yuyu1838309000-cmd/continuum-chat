import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/reading_probe_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('continuum/reading_probe');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('enabled empty probe still shows diagnostic metadata', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getState');
      return jsonEncode({
        'enabled': true,
        'accessibility_running': true,
        'current_package': 'dev.continuum.chat',
        'probe_diagnostic': 'usage_stats_ok',
        'poll_foreground_package': 'net.cpwxx.cpfiction',
        'probe_diagnostic_ts': 1788451204000,
        'attempts': <String, Object?>{},
        'events': <Object?>[],
        'failures': <Object?>[],
        'ocr_text': '诊断面板不得显示的正文',
      });
    });

    await tester.pumpWidget(const MaterialApp(home: ReadingProbePage()));
    await tester.pumpAndSettle();

    expect(find.text('轮询诊断'), findsOneWidget);
    expect(find.textContaining('probe_diagnostic  '), findsOneWidget);
    expect(
      find.textContaining('UsageStats 正常（usage_stats_ok）'),
      findsOneWidget,
    );
    expect(find.textContaining('poll_foreground_package  '), findsOneWidget);
    expect(find.textContaining('net.cpwxx.cpfiction'), findsOneWidget);
    expect(find.textContaining('probe_diagnostic_ts  '), findsOneWidget);
    expect(find.textContaining('current_package  '), findsOneWidget);
    expect(find.textContaining('accessibility_running  '), findsOneWidget);
    expect(find.text('还没捕获到外部页面'), findsOneWidget);
    expect(find.textContaining('诊断面板不得显示的正文'), findsNothing);
  });

  testWidgets('known UsageStats diagnostics are translated to Chinese', (
    tester,
  ) async {
    var diagnostic = 'usage_stats_denied';
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => jsonEncode({
        'enabled': true,
        'accessibility_running': false,
        'probe_diagnostic': diagnostic,
        'attempts': <String, Object?>{},
        'events': <Object?>[],
        'failures': <Object?>[],
      }),
    );

    await tester.pumpWidget(const MaterialApp(home: ReadingProbePage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('UsageStats 权限未授权'), findsOneWidget);

    diagnostic = 'usage_stats_no_result';
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('UsageStats 暂无前台应用结果'), findsOneWidget);

    diagnostic = 'usage_stats_unavailable';
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('UsageStats 服务不可用'), findsOneWidget);

    diagnostic = 'usage_stats_error:SecurityException';
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('UsageStats 查询异常：SecurityException'),
      findsOneWidget,
    );
  });
}
