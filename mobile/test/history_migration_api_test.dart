import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/history_migration_api.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
  });

  test(
    'old server capability response fails safely before payload POST',
    () async {
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/runtime/capabilities');
        return FakeHttpResponseData.json({'ok': true, 'agent_runtime': true});
      });

      await expectLater(
        HttpOverrides.runZoned(
          () => const HistoryMigrationApi().requireCapability(),
          createHttpClient: (_) => client,
        ),
        throwsA(isA<HistoryMigrationException>()),
      );

      expect(client.requests, hasLength(1));
    },
  );

  test('preview import and status use isolated migration routes', () async {
    final client = FakeHttpClient((request) {
      expect(request.uri.port, 8816);
      expect(request.headers['x-token'], anyOf(isNull, isEmpty));
      return switch ((request.method, request.uri.path)) {
        ('GET', '/runtime/capabilities') => FakeHttpResponseData.json({
          'ok': true,
          'history_migration': {
            'version': 1,
            'preview': true,
            'import': true,
            'status': true,
          },
        }),
        ('POST', '/runtime/history-migration/preview') =>
          FakeHttpResponseData.json({'ok': true, 'can_import': true}),
        ('POST', '/runtime/history-migration/import') =>
          FakeHttpResponseData.json({'ok': true, 'status': 'complete'}),
        ('GET', '/runtime/history-migration/status') =>
          FakeHttpResponseData.json({'ok': true, 'status': 'complete'}),
        _ => FakeHttpResponseData.json({
          'error': 'unexpected',
        }, statusCode: 500),
      };
    });
    const api = HistoryMigrationApi();
    final snapshot = {
      'migration_version': 1,
      'snapshot_id': 'snapshot-1',
      'snapshot_hash': 'hash-1',
      'thread_id': 'main',
      'windows': <Object>[],
    };

    await HttpOverrides.runZoned(() async {
      await api.requireCapability();
      expect((await api.preview(snapshot))['can_import'], isTrue);
      expect((await api.importSnapshot(snapshot))['status'], 'complete');
      expect((await api.status('snapshot-1'))?['status'], 'complete');
    }, createHttpClient: (_) => client);

    expect(client.requests.map((request) => request.uri.path), [
      '/runtime/capabilities',
      '/runtime/history-migration/preview',
      '/runtime/history-migration/import',
      '/runtime/history-migration/status',
    ]);
    expect(
      client.requests.last.uri.queryParameters['snapshot_id'],
      'snapshot-1',
    );
  });
}
