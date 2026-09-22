import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/chat_api.dart';

import 'support/fake_http.dart';

void main() {
  test('deleteIngested sends exact raw event ids to ingest delete', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'DELETE');
      expect(request.uri.path, '/ingest');
      expect(
        request.jsonBody,
        equals({
          'ids': [11, 22],
        }),
      );
      return FakeHttpResponseData.json({'ok': true, 'soft_deleted': 2});
    });

    final deleted = await HttpOverrides.runZoned(
      () => ChatApi.deleteIngested([11, 22]),
      createHttpClient: (_) => client,
    );

    expect(deleted, 2);
    expect(client.requests, hasLength(1));
  });

  test('deleteIngested empty list performs no request', () async {
    var calls = 0;
    final client = FakeHttpClient((request) {
      calls += 1;
      return FakeHttpResponseData.json({'ok': true});
    });

    final deleted = await HttpOverrides.runZoned(
      () => ChatApi.deleteIngested([]),
      createHttpClient: (_) => client,
    );

    expect(deleted, 0);
    expect(calls, 0);
  });

  test(
    'deleteIngested non-200 returns null without fabricating success',
    () async {
      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/ingest');
        return FakeHttpResponseData.json({'error': 'failed'}, statusCode: 500);
      });

      final deleted = await HttpOverrides.runZoned(
        () => ChatApi.deleteIngested([33]),
        createHttpClient: (_) => client,
      );

      expect(deleted, isNull);
    },
  );

  test('rollover posts stable epoch id to runtime route', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/runtime/epochs/rollover');
      expect(request.jsonBody, {'thread_id': 'main', 'epoch_id': 'epoch-next'});
      return FakeHttpResponseData.json({'ok': true, 'epoch_id': 'epoch-next'});
    });

    final result = await HttpOverrides.runZoned(
      () => ChatApi.rolloverRuntimeEpoch(epochId: 'epoch-next'),
      createHttpClient: (_) => client,
    );

    expect(result?['ok'], isTrue);
  });

  test('edit posts canonical event identity and replacement payload', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/runtime/events/event-user/edit');
      expect(request.jsonBody['thread_id'], 'main');
      expect(request.jsonBody['epoch_id'], 'epoch-1');
      expect(request.jsonBody['generation_id'], 'gen-edit');
      expect(request.jsonBody['client_event_id'], 'client-edit');
      expect(request.jsonBody['content'], 'edited');
      return FakeHttpResponseData.json({
        'ok': true,
        'event': {'event_id': 'event-user-new'},
      });
    });

    final result = await HttpOverrides.runZoned(
      () => ChatApi.editRuntimeEvent(
        eventId: 'event-user',
        epochId: 'epoch-1',
        generationId: 'gen-edit',
        clientEventId: 'client-edit',
        content: 'edited',
      ),
      createHttpClient: (_) => client,
    );

    expect(result?['ok'], isTrue);
  });

  test(
    'edit transport retry reuses the exact same idempotency identities',
    () async {
      var attempts = 0;
      final client = FakeHttpClient((request) {
        attempts += 1;
        expect(request.method, 'POST');
        expect(request.uri.path, '/runtime/events/event-retry/edit');
        expect(request.jsonBody['generation_id'], 'gen-stable');
        expect(request.jsonBody['client_event_id'], 'client-stable');
        if (attempts == 1) {
          throw const SocketException('response lost after send');
        }
        return FakeHttpResponseData.json({
          'ok': true,
          'generation_id': 'gen-stable',
          'user_event_id': 'event-new',
          'epoch_id': 'epoch-1',
        });
      });

      final result = await HttpOverrides.runZoned(
        () => ChatApi.editRuntimeEvent(
          eventId: 'event-retry',
          epochId: 'epoch-1',
          generationId: 'gen-stable',
          clientEventId: 'client-stable',
          requestId: 'gen-stable',
          content: 'edited',
        ),
        createHttpClient: (_) => client,
      );

      expect(result?['ok'], isTrue);
      expect(client.requests, hasLength(2));
      expect(client.requests[0].jsonBody, client.requests[1].jsonBody);
    },
  );

  test(
    'delete posts canonical event path without raw ingest fallback',
    () async {
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        expect(request.method, 'DELETE');
        expect(request.uri.path, '/runtime/events/event-a');
        expect(request.jsonBody, {'thread_id': 'main', 'epoch_id': 'epoch-1'});
        return FakeHttpResponseData.json({'ok': true, 'event_id': 'event-a'});
      });

      final result = await HttpOverrides.runZoned(
        () =>
            ChatApi.deleteRuntimeEvent(eventId: 'event-a', epochId: 'epoch-1'),
        createHttpClient: (_) => client,
      );

      expect(result?['ok'], isTrue);
    },
  );

  test('regenerate calls canonical generation command', () async {
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/runtime/events/event-user/regenerate');
      expect(request.jsonBody, {
        'thread_id': 'main',
        'epoch_id': 'epoch-1',
        'generation_id': 'gen-new',
      });
      return FakeHttpResponseData.json({
        'ok': true,
        'user_event_id': 'event-user',
      });
    });

    final result = await HttpOverrides.runZoned(
      () => ChatApi.regenerateRuntimeEvent(
        userEventId: 'event-user',
        epochId: 'epoch-1',
        generationId: 'gen-new',
      ),
      createHttpClient: (_) => client,
    );

    expect(result?['ok'], isTrue);
    expect(client.requests, hasLength(1));
  });
}
