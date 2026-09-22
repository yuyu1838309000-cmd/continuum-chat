import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/termux_api.dart';

import 'support/fake_http.dart';

void main() {
  test(
    'canonical tool results keep generation and per-call identities',
    () async {
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/tool-result');
        expect(request.jsonBody, {
          'generation_id': 'gen-123',
          'results': [
            {
              'tool_call_id': 'call-a',
              'result': {'command': 'pwd', 'ok': true, 'output': '/sdcard'},
            },
            {
              'tool_call_id': 'call-b',
              'result': {'command': 'date', 'ok': true, 'output': 'today'},
            },
          ],
        });
        return FakeHttpResponseData.json({
          'ok': true,
          'accepted': [
            {'generation_id': 'gen-123', 'tool_call_id': 'call-a'},
            {'generation_id': 'gen-123', 'tool_call_id': 'call-b'},
          ],
        });
      });

      final report = await HttpOverrides.runZoned(
        () => TermuxApi.reportCanonicalResults('gen-123', [
          {
            'tool_call_id': 'call-a',
            'result': {'command': 'pwd', 'ok': true, 'output': '/sdcard'},
          },
          {
            'tool_call_id': 'call-b',
            'result': {'command': 'date', 'ok': true, 'output': 'today'},
          },
        ]),
        createHttpClient: (_) => client,
      );

      expect(report.status, CanonicalReportStatus.accepted);
      expect(report.identities, {
        const CanonicalToolIdentity(
          generationId: 'gen-123',
          toolCallId: 'call-a',
        ),
        const CanonicalToolIdentity(
          generationId: 'gen-123',
          toolCallId: 'call-b',
        ),
      });
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'canonical terminal rejection is settled instead of replayed forever',
    () async {
      final client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/tool-result');
        return FakeHttpResponseData.json({
          'ok': false,
          'error': 'generation waiter expired',
          'generation_id': 'gen-expired',
          'tool_call_id': 'call-expired',
        }, statusCode: 410);
      });

      final report = await HttpOverrides.runZoned(
        () => TermuxApi.reportCanonicalResults('gen-expired', [
          {
            'tool_call_id': 'call-expired',
            'result': {'command': 'device_status', 'output': 'late'},
          },
        ]),
        createHttpClient: (_) => client,
      );

      expect(report.status, CanonicalReportStatus.closed);
      expect(report.identities, {
        const CanonicalToolIdentity(
          generationId: 'gen-expired',
          toolCallId: 'call-expired',
        ),
      });
      expect(client.requests, hasLength(1));
    },
  );

  test('canonical ACK classes preserve exact requested identities', () async {
    const generationId = 'gen-ack-classes';
    const toolCallId = 'call-ack-classes';
    const payload = [
      {
        'tool_call_id': toolCallId,
        'result': {'ok': true},
      },
    ];

    Future<CanonicalReportResult> report(FakeHttpResponseData response) {
      final client = FakeHttpClient((_) => response);
      return HttpOverrides.runZoned(
        () => TermuxApi.reportCanonicalResults(generationId, payload),
        createHttpClient: (_) => client,
      );
    }

    for (final status in <int>[408, 425, 429, 500, 503]) {
      final result = await report(FakeHttpResponseData(statusCode: status));
      expect(result.status, CanonicalReportStatus.retryable);
      expect(result.identities.single.toolCallId, toolCallId);
    }
    for (final status in <int>[400, 401, 403, 404, 409]) {
      final result = await report(FakeHttpResponseData(statusCode: status));
      expect(result.status, CanonicalReportStatus.rejected);
      expect(result.identities.single.generationId, generationId);
    }
  });

  test('malformed partial and ok-false 200 ACKs are rejected', () async {
    const generationId = 'gen-malformed-ack';
    const payload = [
      {
        'tool_call_id': 'call-a',
        'result': {'ok': true},
      },
      {
        'tool_call_id': 'call-b',
        'result': {'ok': true},
      },
    ];
    final responses = <FakeHttpResponseData>[
      const FakeHttpResponseData(statusCode: 200, body: 'not json'),
      FakeHttpResponseData.json({'ok': false, 'accepted': const []}),
      FakeHttpResponseData.json({
        'ok': true,
        'accepted': const [
          {'generation_id': generationId, 'tool_call_id': 'call-a'},
        ],
      }),
      FakeHttpResponseData.json({
        'ok': true,
        'accepted': const [
          {'generation_id': generationId, 'tool_call_id': 'call-a'},
          {'generation_id': 'wrong', 'tool_call_id': 'call-b'},
        ],
      }),
    ];

    for (final response in responses) {
      final client = FakeHttpClient((_) => response);
      final result = await HttpOverrides.runZoned(
        () => TermuxApi.reportCanonicalResults(generationId, payload),
        createHttpClient: (_) => client,
      );
      expect(result.status, CanonicalReportStatus.rejected);
      expect(result.identities, hasLength(2));
    }
  });

  test('chat tool result keeps chat id round and result payload', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/tool-result');
      expect(request.jsonBody['chat_id'], 'chat-123');
      expect(request.jsonBody['round'], 7);
      expect(
        request.jsonBody['results'],
        equals([
          {'tool': 'device_status', 'ok': true, 'output': 'battery=80'},
        ]),
      );
      return FakeHttpResponseData.json({'ok': true, 'chat_id': 'chat-123'});
    });

    final ok = await HttpOverrides.runZoned(
      () => TermuxApi.reportResults('chat-123', 7, [
        {'tool': 'device_status', 'ok': true, 'output': 'battery=80'},
      ]),
      createHttpClient: (_) => client,
    );

    expect(ok, isTrue);
    expect(client.requests, hasLength(1));
  });

  test('proactive tool result uses message id instead of chat round', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/tool-result');
      expect(request.jsonBody['msg_id'], 'heartbeat-456');
      expect(request.jsonBody, isNot(contains('chat_id')));
      expect(request.jsonBody, isNot(contains('round')));
      expect(
        request.jsonBody['results'],
        equals([
          {'command': 'pwd', 'ok': true, 'output': '/sdcard'},
        ]),
      );
      return FakeHttpResponseData.json({'ok': true, 'msg_id': 'heartbeat-456'});
    });

    final ok = await HttpOverrides.runZoned(
      () => TermuxApi.reportResultsByMsgId('heartbeat-456', [
        {'command': 'pwd', 'ok': true, 'output': '/sdcard'},
      ]),
      createHttpClient: (_) => client,
    );

    expect(ok, isTrue);
    expect(client.requests, hasLength(1));
  });
}
