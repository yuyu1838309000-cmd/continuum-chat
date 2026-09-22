import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(int status, Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test('GET retries once after a transient transport failure', () async {
    var calls = 0;
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        calls += 1;
        if (calls == 1) throw http.ClientException('offline once');
        return _json(200, {'ok': true, 'revision': 7});
      }),
    );

    final result = await api.capabilities();

    expect(result['revision'], 7);
    expect(calls, 2);
  });

  test('GET surfaces transport failure after the retry also fails', () async {
    var calls = 0;
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        calls += 1;
        throw http.ClientException('still offline');
      }),
    );

    await expectLater(
      api.capabilities(),
      throwsA(
        isA<RuntimeHistoryException>()
            .having((error) => error.kind, 'kind', 'transport')
            .having((error) => error.message, 'message', 'still offline'),
      ),
    );
    expect(calls, 2);
  });

  test('GET does not retry after an HTTP response is received', () async {
    var calls = 0;
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        calls += 1;
        return _json(503, {'error': 'busy'});
      }),
    );

    await expectLater(
      api.capabilities(),
      throwsA(
        isA<RuntimeHistoryException>()
            .having((error) => error.kind, 'kind', 'http')
            .having((error) => error.statusCode, 'statusCode', 503),
      ),
    );
    expect(calls, 1);
  });

  test('GET does not retry a contract error after a response', () async {
    var calls = 0;
    final api = RuntimeHistoryApi(
      client: MockClient((request) async {
        calls += 1;
        return _json(200, {'ok': false, 'error': 'invalid contract'});
      }),
    );

    await expectLater(
      api.capabilities(),
      throwsA(
        isA<RuntimeHistoryException>()
            .having((error) => error.kind, 'kind', 'contract')
            .having((error) => error.message, 'message', 'invalid contract'),
      ),
    );
    expect(calls, 1);
  });
}
