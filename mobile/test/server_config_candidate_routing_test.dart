import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/server_config.dart';

void main() {
  test('candidate build only remaps Runtime port', () {
    const candidate = bool.fromEnvironment(
      'CONTINUUM_CANDIDATE',
      defaultValue: false,
    );
    expect(ServerConfig.runtimePort, candidate ? 8815 : 8816);
    expect(
      ServerConfig.runtimeUrl('/chat'),
      candidate ? 'http://127.0.0.1:8815/chat' : 'http://127.0.0.1:8816/chat',
    );
    expect(
      ServerConfig.url(8816, '/health'),
      candidate
          ? 'http://127.0.0.1:8815/health'
          : 'http://127.0.0.1:8816/health',
    );
    expect(ServerConfig.url(8820, '/stats'), 'http://127.0.0.1:8820/stats');
  });

  test('all representative Runtime paths share the effective endpoint', () {
    const candidate = bool.fromEnvironment(
      'CONTINUUM_CANDIDATE',
      defaultValue: false,
    );
    final expectedPort = candidate ? 8815 : 8816;
    for (final path in <String>[
      '/chat',
      '/pending',
      '/notify-status',
      '/tool-result',
      '/screenshot-analyze',
      '/generations/gen-route/events',
    ]) {
      expect(
        Uri.parse(ServerConfig.runtimeUrl(path)).port,
        expectedPort,
        reason: path,
      );
    }
  });

  test('active production source has no direct Runtime port URL leaks', () {
    final offenders = <String>[];
    for (final root in <Directory>[
      Directory('lib'),
      Directory('android/app/src/main/kotlin'),
    ]) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File ||
            (!entity.path.endsWith('.dart') && !entity.path.endsWith('.kt')) ||
            entity.path.contains('.bak')) {
          continue;
        }
        if (entity.readAsStringSync().contains(':8816/')) {
          offenders.add(entity.path);
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test(
    'background and native bridges receive the effective Runtime endpoint',
    () {
      final notifySource = File(
        'lib/services/notify_panel.dart',
      ).readAsStringSync();
      final nudgeApiSource = File(
        'lib/services/nudge_api.dart',
      ).readAsStringSync();
      final nativeSource = File(
        'android/app/src/main/kotlin/dev/continuum/chat/NudgeTools.kt',
      ).readAsStringSync();
      final configPageSource = File(
        'lib/pages/server_config_page.dart',
      ).readAsStringSync();

      expect(
        notifySource,
        contains("'runtime_port': ServerConfig.runtimePort"),
      );
      expect(notifySource, contains('required int runtimePort'));
      expect(
        nudgeApiSource,
        contains("'server_base_url': ServerConfig.runtimeUrl('')"),
      );
      expect(nativeSource, contains('args.toString("server_base_url"'));
      expect(nativeSource, isNot(contains(':8816/')));
      expect(configPageSource, contains("ServerConfig.runtimeUrl('')"));
    },
  );
}
