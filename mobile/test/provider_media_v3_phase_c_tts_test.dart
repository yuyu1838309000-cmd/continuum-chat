import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/pages/tts_config_page.dart';
import 'package:continuum_chat/services/tts_api.dart';
import 'package:continuum_chat/utils/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tts-v3-test-');
    SharedPreferences.setMockInitialValues({
      'tts_model': 'custom-voice-model',
      'tts_api_url': 'https://voice.example/run',
      'tts_read_aloud': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return tempDir.path;
          }
          return tempDir.path;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('legacy config defaults to the current adapter and sends it', () async {
    await TtsConfig.instance.load();
    expect(TtsConfig.instance.adapter, TtsConfig.defaultAdapter);
    final params = TtsConfig.instance.toParams('hello');
    expect(params['adapter'], TtsConfig.defaultAdapter);
    expect(params['model'], 'custom-voice-model');
  });

  testWidgets('TTS page has editable model and no fixed provider/model chips', (
    tester,
  ) async {
    await _pumpPage(tester, themes[AppThemeId.midnightGold]!.light, 375);

    expect(find.text('MiniMax'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('当前协议：T2A v2'), findsOneWidget);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .any((field) => field.controller?.text == 'custom-voice-model'),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TTS page fits compact light and dark widths', (tester) async {
    for (final width in [320.0, 375.0, 414.0]) {
      for (final theme in [
        themes[AppThemeId.midnightGold]!.light,
        themes[AppThemeId.midnightGold]!.dark,
      ]) {
        await _pumpPage(tester, theme, width);
        expect(find.text('语音服务'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  ThemeData theme,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: theme, home: const TtsConfigPage()),
  );
  await tester.pumpAndSettle();
}
