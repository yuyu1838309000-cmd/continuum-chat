import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/reading_probe_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('continuum/reading_probe');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('state decodes native json', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getState');
      return jsonEncode({
        'enabled': true,
        'probe_diagnostic': 'usage_stats_ok',
        'poll_foreground_package': 'net.cpwxx.cpfiction',
        'probe_diagnostic_ts': 1788451204000,
        'current_package': 'dev.continuum.chat',
        'accessibility_running': true,
        'events': [
          {
            'event_package': 'reader.app',
            'root_package': 'reader.app',
            'package_match': true,
            'preview_path': '/private/cache/reader.app.jpg',
            'ocr_text': '本机识别正文',
            'ocr_char_count': 6,
            'page_fingerprint': 'text:abc123',
          },
        ],
        'failures': [],
      });
    });

    final state = await ReadingProbeApi.state();
    expect(state['enabled'], isTrue);
    expect(state['probe_diagnostic'], 'usage_stats_ok');
    expect(state['poll_foreground_package'], 'net.cpwxx.cpfiction');
    expect(state['probe_diagnostic_ts'], 1788451204000);
    expect(state['current_package'], 'dev.continuum.chat');
    expect(state['accessibility_running'], isTrue);
    final capture = (state['events'] as List).single as Map<String, dynamic>;
    expect(capture['package_match'], isTrue);
    expect(capture['preview_path'], '/private/cache/reader.app.jpg');
    expect(capture['ocr_text'], '本机识别正文');
    expect(capture['page_fingerprint'], 'text:abc123');
  });

  test('setEnabled forwards explicit toggle', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setEnabled');
      expect(call.arguments, {'enabled': false});
      return jsonEncode({'enabled': false, 'events': []});
    });

    final state = await ReadingProbeApi.setEnabled(false);
    expect(state['enabled'], isFalse);
  });

  test('malformed native payload fails closed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => 'not-json');
    expect(await ReadingProbeApi.state(), isEmpty);
  });

  test('clear invokes native clear and returns empty probe session', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'clear');
      expect(call.arguments, isNull);
      return jsonEncode({
        'enabled': true,
        'events': [],
        'failures': [],
        'captures': {},
        'attempts': {},
      });
    });

    final state = await ReadingProbeApi.clear();
    expect(state['events'], isEmpty);
    expect(state['failures'], isEmpty);
    expect(state['captures'], isEmpty);
    expect(state['attempts'], isEmpty);
  });
}
