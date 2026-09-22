import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/chat_api.dart';

import 'support/fake_http.dart';

void main() {
  test('ackPending posts only non-empty ids to pending ack route', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/pending/ack');
      expect(
        request.jsonBody,
        equals({
          'ids': ['a', 'b'],
        }),
      );
      return FakeHttpResponseData.json({'ok': true, 'acked': 2});
    });

    await HttpOverrides.runZoned(
      () => ChatApi.ackPending(['a', '', 'b']),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(1));
  });

  test('ackPending with no usable ids performs no request', () async {
    var calls = 0;
    final client = FakeHttpClient((request) {
      calls += 1;
      return FakeHttpResponseData.json({'ok': true});
    });

    await HttpOverrides.runZoned(
      () => ChatApi.ackPending(['', '']),
      createHttpClient: (_) => client,
    );

    expect(calls, 0);
    expect(client.requests, isEmpty);
  });

  test('ackPending tolerates non-200 for backward compatibility', () async {
    final client = FakeHttpClient((request) {
      expect(request.uri.path, '/pending/ack');
      return FakeHttpResponseData.json({'error': 'missing'}, statusCode: 404);
    });

    await HttpOverrides.runZoned(
      () => ChatApi.ackPending(['legacy']),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(1));
  });
}
