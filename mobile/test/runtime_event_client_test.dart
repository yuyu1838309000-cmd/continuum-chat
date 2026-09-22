import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_api.dart';
import 'package:continuum_chat/services/runtime_event_client.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';

Stream<List<int>> _bytesThenError(String body, Object error) async* {
  if (body.isNotEmpty) yield utf8.encode(body);
  throw error;
}

Stream<List<int>> _commentsThenTerminal() async* {
  yield utf8.encode(': connected\n\n');
  await Future<void>.delayed(const Duration(milliseconds: 4));
  yield utf8.encode(': keepalive\n\n');
  await Future<void>.delayed(const Duration(milliseconds: 4));
  yield utf8.encode(
    'id: 1\n'
    'data: {"type":"generation_terminal","status":"completed"}\n\n',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    await RuntimeEventClient.instance.clearCursor();
    await RuntimeEventClient.instance.clearPendingCommand();
  });

  test('SSE parser recognizes id seq and data payload', () async {
    final events = await Stream<String>.fromIterable([
      'id: 7',
      'data: {"type":"part","part":{"type":"text","text":"hi"}}',
      '',
      'id: 8',
      'data: [DONE]',
      '',
    ]).transform(const RuntimeSseParser()).toList();

    expect(events, hasLength(2));
    expect(events.first.seq, 7);
    expect(events.first.json?['type'], 'part');
    expect(events.last.seq, 8);
    expect(events.last.isDonePayload, isTrue);
  });

  test('terminal SSE batch is emitted before the connection closes', () async {
    final controller = StreamController<String>();
    final firstEvent = controller.stream
        .transform(const RuntimeSseParser())
        .first
        .timeout(const Duration(seconds: 1));

    controller.add('id: 12');
    controller.add('data: {"type":"generation_terminal","status":"completed"}');
    controller.add('');

    final event = await firstEvent;
    expect(event.seq, 12);
    expect(event.json?['type'], 'generation_terminal');
    await controller.close();
  });

  test(
    'one replay seq keeps all nested SSE frames in one atomic batch',
    () async {
      final events = await Stream<String>.fromIterable([
        'id: 11',
        'data: {"type":"part","part":{"type":"text","text":"正文"}}',
        '',
        'data: {"choices":[{"delta":{"content":"兼容正文"}}]}',
        '',
        'data: {"type":"metadata","user_raw_event_id":9}',
        '',
        'data: [DONE]',
        '',
      ]).transform(const RuntimeSseParser()).toList();

      expect(events, hasLength(1));
      expect(events.single.seq, 11);
      expect(events.single.payloads, hasLength(4));
      expect(events.single.json?['type'], 'part');
      expect(events.single.hasDonePayload, isTrue);
    },
  );

  test('POST and resume share parser, persist cursor, dedupe seq', () async {
    final client = FakeHttpClient((request) {
      if (request.method == 'POST') {
        expect(request.uri.path, '/chat');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-1'},
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"A"}}\n\n'
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"dup"}}\n\n'
              'id: 2\n'
              'data: [DONE]\n\n',
        );
      }
      expect(request.method, 'GET');
      expect(request.uri.path, '/generations/gen-1/events');
      expect(request.uri.queryParameters['after_seq'], '2');
      return const FakeHttpResponseData(
        statusCode: 200,
        headers: {'x-generation-id': 'gen-1'},
        body:
            'id: 3\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });
    final applied = <String>[];

    await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.startChat(
        body: {'messages': const []},
        userClientEventId: 'u1',
        assistantClientEventId: 'a1',
        generationId: 'gen-1',
        onEvent: (event, _) {
          final part = event.json?['part'];
          if (part is Map) applied.add(part['text'].toString());
        },
      ),
      createHttpClient: (_) => client,
    );

    expect(applied, ['A']);
    expect(client.requests.map((r) => r.method), ['POST', 'GET']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(RuntimeEventClient.cursorPrefsKeyForTesting),
      isNull,
    );
  });

  test(
    'replayable device report failure keeps seq pending and replays without re-POSTing',
    () async {
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          expect(request.uri.path, '/chat');
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-device-retry'},
            body:
                'id: 1\n'
                'data: {"type":"nudge_pending","generation_id":"gen-device-retry"}\n\n',
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-device-retry/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"nudge_pending","generation_id":"gen-device-retry"}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      var pendingAttempts = 0;

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.startChat(
          body: {'messages': const []},
          userClientEventId: 'u-device-retry',
          assistantClientEventId: 'a-device-retry',
          generationId: 'gen-device-retry',
          onEvent: (event, _) {
            if (event.seq != 1) return;
            pendingAttempts += 1;
            if (pendingAttempts == 1) {
              throw const RuntimeException(
                'device_tool_report_failed',
                'temporary report failure',
              );
            }
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(pendingAttempts, 2);
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'POST EOF without DONE resumes the same generation instead of re-POSTing',
    () async {
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          expect(request.uri.path, '/chat');
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-detached'},
            body:
                'id: 1\n'
                'data: {"type":"part","part":{"type":"text","text":"半句"}}\n\n',
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-detached/events');
        expect(request.uri.queryParameters['after_seq'], '1');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-detached'},
          body:
              'id: 2\n'
              'data: {"type":"part","part":{"type":"text","text":"后半句"}}\n\n'
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.startChat(
          body: {'messages': const []},
          userClientEventId: 'u-detached',
          assistantClientEventId: 'a-detached',
          generationId: 'gen-detached',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(applied, ['半句', '后半句']);
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'accepted POST network failure before events resumes from seq zero with GET',
    () async {
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          return FakeHttpResponseData(
            statusCode: 200,
            headers: const {'x-generation-id': 'gen-zero-replay'},
            bodyStream: _bytesThenError(
              '',
              const SocketException('network lost after acceptance'),
            ),
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-zero-replay/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"补回"}}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.startChat(
          body: {'messages': const []},
          userClientEventId: 'u-zero-replay',
          assistantClientEventId: 'a-zero-replay',
          generationId: 'gen-zero-replay',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(applied, ['补回']);
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'partial stream failure resumes strictly after the last applied seq',
    () async {
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          return FakeHttpResponseData(
            statusCode: 200,
            headers: const {'x-generation-id': 'gen-partial-replay'},
            bodyStream: _bytesThenError(
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"前"}}\n\n'
              'id: 2\n',
              const SocketException('network lost after seq one'),
            ),
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-partial-replay/events');
        expect(request.uri.queryParameters['after_seq'], '1');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"重复"}}\n\n'
              'id: 2\n'
              'data: {"type":"part","part":{"type":"text","text":"后"}}\n\n'
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.startChat(
          body: {'messages': const []},
          userClientEventId: 'u-partial-replay',
          assistantClientEventId: 'a-partial-replay',
          generationId: 'gen-partial-replay',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(applied, ['前', '后']);
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
    },
  );

  test(
    'normal replay EOF before terminal reconnects from the advanced cursor',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-replay-eof","last_seq":0,'
        '"status":"running"}',
      );
      var attempts = 0;
      final client = FakeHttpClient((request) {
        attempts += 1;
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-replay-eof/events');
        if (attempts == 1) {
          expect(request.uri.queryParameters['after_seq'], '0');
          return const FakeHttpResponseData(
            statusCode: 200,
            body:
                'id: 1\n'
                'data: {"type":"part","part":{"type":"text","text":"前半"}}\n\n',
          );
        }
        expect(request.uri.queryParameters['after_seq'], '1');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.resume(onEvent: (_, _) {}),
        createHttpClient: (_) => client,
      );

      expect(client.requests, hasLength(2));
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'resume header silence times out and reconnects the same cursor',
    () async {
      final runtime = RuntimeEventClient(
        responseHeaderTimeout: const Duration(milliseconds: 10),
        bodyIdleTimeout: const Duration(milliseconds: 50),
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
      );
      await runtime.prepareGeneration(
        generationId: 'gen-header-silence',
        userClientEventId: 'u-header-silence',
        assistantClientEventId: 'a-header-silence',
      );
      var attempts = 0;
      final never = Completer<FakeHttpResponseData>();
      final client = FakeHttpClient((request) {
        attempts += 1;
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-header-silence/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        if (attempts == 1) return never.future;
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => runtime.resume(onEvent: (_, _) {}),
        createHttpClient: (_) => client,
      );

      expect(attempts, 2);
      expect(await runtime.loadCursor(), isNull);
    },
  );

  test('resume body silence reconnects without settling locally', () async {
    final runtime = RuntimeEventClient(
      responseHeaderTimeout: const Duration(milliseconds: 50),
      bodyIdleTimeout: const Duration(milliseconds: 10),
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );
    await runtime.prepareGeneration(
      generationId: 'gen-body-silence',
      userClientEventId: 'u-body-silence',
      assistantClientEventId: 'a-body-silence',
    );
    final silentBody = StreamController<List<int>>();
    var attempts = 0;
    final client = FakeHttpClient((request) {
      attempts += 1;
      expect(request.method, 'GET');
      expect(request.uri.queryParameters['after_seq'], '0');
      if (attempts == 1) {
        return FakeHttpResponseData(
          statusCode: 200,
          bodyStream: silentBody.stream,
        );
      }
      return const FakeHttpResponseData(
        statusCode: 200,
        body:
            'id: 1\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });

    await HttpOverrides.runZoned(
      () => runtime.resume(onEvent: (_, _) {}),
      createHttpClient: (_) => client,
    );
    await silentBody.close();

    expect(attempts, 2);
    expect(await runtime.loadCursor(), isNull);
  });

  test(
    'SSE comments keep the body alive and never become runtime events',
    () async {
      final runtime = RuntimeEventClient(
        responseHeaderTimeout: const Duration(milliseconds: 50),
        bodyIdleTimeout: const Duration(milliseconds: 7),
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
      );
      await runtime.prepareGeneration(
        generationId: 'gen-comments',
        userClientEventId: 'u-comments',
        assistantClientEventId: 'a-comments',
      );
      final applied = <int?>[];
      final client = FakeHttpClient(
        (_) => FakeHttpResponseData(
          statusCode: 200,
          bodyStream: _commentsThenTerminal(),
        ),
      );

      await HttpOverrides.runZoned(
        () => runtime.resume(onEvent: (event, _) => applied.add(event.seq)),
        createHttpClient: (_) => client,
      );

      expect(applied, [1]);
      expect(client.requests, hasLength(1));
    },
  );

  test('all transient replay statuses retry the same generation', () async {
    final runtime = RuntimeEventClient(
      responseHeaderTimeout: const Duration(milliseconds: 50),
      bodyIdleTimeout: const Duration(milliseconds: 50),
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );
    await runtime.prepareGeneration(
      generationId: 'gen-transient-statuses',
      userClientEventId: 'u-transient-statuses',
      assistantClientEventId: 'a-transient-statuses',
    );
    final statuses = <int>[408, 425, 429, 500, 503];
    var attempt = 0;
    final client = FakeHttpClient((request) {
      expect(request.method, 'GET');
      expect(request.uri.path, '/generations/gen-transient-statuses/events');
      expect(request.uri.queryParameters['after_seq'], '0');
      if (attempt < statuses.length) {
        return FakeHttpResponseData(statusCode: statuses[attempt++]);
      }
      return const FakeHttpResponseData(
        statusCode: 200,
        body:
            'id: 1\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });

    await HttpOverrides.runZoned(
      () => runtime.resume(onEvent: (_, _) {}),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(statuses.length + 1));
    expect(await runtime.loadCursor(), isNull);
  });

  test('deterministic replay 4xx fails without retrying', () async {
    for (final status in <int>[400, 401, 403, 409, 422]) {
      SharedPreferences.setMockInitialValues({});
      final runtime = RuntimeEventClient(
        responseHeaderTimeout: const Duration(milliseconds: 50),
        bodyIdleTimeout: const Duration(milliseconds: 50),
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
      );
      await runtime.prepareGeneration(
        generationId: 'gen-deterministic-$status',
        userClientEventId: 'u-deterministic-$status',
        assistantClientEventId: 'a-deterministic-$status',
      );
      final client = FakeHttpClient(
        (_) => FakeHttpResponseData(statusCode: status),
      );

      await expectLater(
        HttpOverrides.runZoned(
          () => runtime.resume(onEvent: (_, _) {}),
          createHttpClient: (_) => client,
        ),
        throwsA(
          isA<RuntimeException>().having(
            (error) => error.code,
            'code',
            'generation_resume_failed',
          ),
        ),
      );
      expect(client.requests, hasLength(1));
      await runtime.clearCursor();
    }
  });

  test(
    'repeated network and lifecycle wakeups share one replay subscription',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-single-flight","last_seq":0,'
        '"status":"running"}',
      );
      final response = StreamController<List<int>>();
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        return FakeHttpResponseData(
          statusCode: 200,
          bodyStream: response.stream,
        );
      });
      final applied = <int>[];

      await HttpOverrides.runZoned(() async {
        final first = RuntimeEventClient.instance.resume(
          onEvent: (event, _) => applied.add(event.seq!),
        );
        RuntimeEventClient.instance.wakeReconnect();
        final second = RuntimeEventClient.instance.resume(
          onEvent: (event, _) => applied.add(event.seq!),
        );
        RuntimeEventClient.instance.wakeReconnect();
        final third = RuntimeEventClient.instance.resume(
          onEvent: (event, _) => applied.add(event.seq!),
        );
        await pumpEventQueue(times: 5);

        expect(client.requests, hasLength(1));
        response.add(
          utf8.encode(
            'id: 1\n'
            'data: {"type":"part","part":{"type":"text","text":"once"}}\n\n'
            'id: 2\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
          ),
        );
        await response.close();
        await Future.wait([first, second, third]);
      }, createHttpClient: (_) => client);

      expect(applied, [1, 2]);
      expect(client.requests, hasLength(1));
    },
  );

  test('terminal replay stops reconnecting and clears the cursor', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-terminal-stop","last_seq":7,'
      '"status":"running"}',
    );
    final client = FakeHttpClient((request) {
      expect(request.method, 'GET');
      expect(request.uri.queryParameters['after_seq'], '7');
      return const FakeHttpResponseData(
        statusCode: 200,
        body:
            'id: 8\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });

    await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.resume(onEvent: (_, _) {}),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(1));
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
  });

  test(
    'durable replay from seq zero never re-POSTs the user message',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-get-only","last_seq":0,'
        '"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-get-only/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.resume(onEvent: (_, _) {}),
        createHttpClient: (_) => client,
      );

      expect(
        client.requests.map((request) => request.method),
        everyElement('GET'),
      );
    },
  );

  test(
    '410 without usable snapshot is explicit local failure and does not POST',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-gone","last_seq":4,'
        '"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-gone/events');
        expect(request.uri.queryParameters['after_seq'], '4');
        return FakeHttpResponseData.json({
          'error': 'generation replay unavailable',
          'generation_id': 'gen-gone',
          'status': 'unknown',
        }, statusCode: 410);
      });

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.resume(onEvent: (_, _) {}),
        createHttpClient: (_) => client,
      );

      expect(client.requests, hasLength(1));
      final saved = await RuntimeEventClient.instance.loadCursor();
      expect(saved?.status, GenerationTerminalStatus.replayUnavailable);
    },
  );

  test('410 accepted running snapshot keeps reconciling with GET', () async {
    final runtime = RuntimeEventClient(
      responseHeaderTimeout: const Duration(milliseconds: 50),
      bodyIdleTimeout: const Duration(milliseconds: 50),
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );
    await runtime.prepareGeneration(
      generationId: 'gen-accepted-race',
      userClientEventId: 'u-accepted-race',
      assistantClientEventId: 'a-accepted-race',
    );
    var attempt = 0;
    final client = FakeHttpClient((_) {
      attempt += 1;
      if (attempt == 1) {
        return FakeHttpResponseData.json({
          'error': 'generation replay unavailable',
          'status': 'running',
          'canonical_generation': {
            'lifecycle': {'status': 'running', 'terminal': false},
            'reconciliation': {'canonical_event': null},
          },
        }, statusCode: 410);
      }
      return const FakeHttpResponseData(
        statusCode: 200,
        body:
            'id: 1\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });

    await HttpOverrides.runZoned(
      () => runtime.resume(onEvent: (_, _) {}),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(2));
    expect(
      client.requests.map((request) => request.method),
      everyElement('GET'),
    );
    expect(await runtime.loadCursor(), isNull);
  });

  test('404 retries only GET before proving generation unaccepted', () async {
    final runtime = RuntimeEventClient(
      responseHeaderTimeout: const Duration(milliseconds: 50),
      bodyIdleTimeout: const Duration(milliseconds: 50),
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );
    await runtime.prepareGeneration(
      generationId: 'gen-unaccepted',
      userClientEventId: 'u-unaccepted',
      assistantClientEventId: 'a-unaccepted',
    );
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData.json({
        'error': 'generation not found',
      }, statusCode: 404),
    );

    await expectLater(
      HttpOverrides.runZoned(
        () => runtime.resume(onEvent: (_, _) {}),
        createHttpClient: (_) => client,
      ),
      throwsA(
        isA<RuntimeException>().having(
          (error) => error.code,
          'code',
          'generation_not_accepted',
        ),
      ),
    );

    expect(client.requests, hasLength(3));
    expect(
      client.requests.map((request) => request.method),
      everyElement('GET'),
    );
  });

  test('410 terminal snapshot emits canonical reply before terminal', () async {
    final runtime = RuntimeEventClient(
      responseHeaderTimeout: const Duration(milliseconds: 50),
      bodyIdleTimeout: const Duration(milliseconds: 50),
      initialRetryDelay: Duration.zero,
      maxRetryDelay: Duration.zero,
    );
    await runtime.prepareGeneration(
      generationId: 'gen-canonical-410',
      userClientEventId: 'u-canonical-410',
      assistantClientEventId: 'a-canonical-410',
    );
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData.json({
        'error': 'generation replay unavailable',
        'status': 'completed',
        'canonical_generation': {
          'lifecycle': {'status': 'completed', 'terminal': true},
          'reconciliation': {
            'canonical_event': {
              'event_id': 'event-assistant',
              'generation_id': 'gen-canonical-410',
              'role': 'assistant',
              'content': '服务器已完成',
              'parts': [
                {'type': 'text', 'text': '服务器已完成'},
              ],
            },
          },
        },
      }, statusCode: 410),
    );
    final types = <String?>[];

    await HttpOverrides.runZoned(
      () => runtime.resume(
        onEvent: (event, _) => types.addAll(
          event.jsonPayloads.map((payload) => payload['type']?.toString()),
        ),
      ),
      createHttpClient: (_) => client,
    );

    expect(types, ['canonical_generation_snapshot', 'generation_terminal']);
    expect(await runtime.loadCursor(), isNull);
    expect(client.requests.single.method, 'GET');
  });

  test(
    'attachGeneration replays an already-started generation from seq zero without POST chat',
    () async {
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-command/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"完成"}}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.attachGeneration(
          generationId: 'gen-command',
          userClientEventId: 'user-command',
          assistantClientEventId: 'assistant-command',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(applied, ['完成']);
      expect(client.requests, hasLength(1));
      expect(client.requests.single.method, 'GET');
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test('cancel 200 clears cursor as cancelled', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-cancelled","last_seq":3,'
      '"status":"running"}',
    );
    final client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/generations/gen-cancelled/cancel');
      return FakeHttpResponseData.json({
        'ok': true,
        'generation_id': 'gen-cancelled',
        'status': 'cancelled',
      });
    });

    final outcome = await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.cancelActive(
        visibleContent: 'visible',
        visibleParts: const [],
      ),
      createHttpClient: (_) => client,
    );

    expect(outcome, CancelGenerationOutcome.cancelled);
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
  });

  test('explicit cancel still posts after its cursor was cleared', () async {
    final client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/generations/gen-old-explicit/cancel');
      return FakeHttpResponseData.json({
        'ok': true,
        'generation_id': 'gen-old-explicit',
        'status': 'cancelled',
      });
    });

    final outcome = await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.cancelActive(
        generationId: 'gen-old-explicit',
        visibleContent: '',
        visibleParts: const [],
      ),
      createHttpClient: (_) => client,
    );

    expect(outcome, CancelGenerationOutcome.cancelled);
    expect(client.requests, hasLength(1));
  });

  test('explicit old cancel cannot clear replacement cursor', () async {
    await RuntimeEventClient.instance.prepareGeneration(
      generationId: 'gen-replacement',
      userClientEventId: 'user-replacement',
      assistantClientEventId: 'assistant-replacement',
    );
    final client = FakeHttpClient((request) {
      expect(request.uri.path, '/generations/gen-old/cancel');
      return FakeHttpResponseData.json({
        'ok': true,
        'generation_id': 'gen-old',
        'status': 'cancelled',
      });
    });

    final outcome = await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.cancelActive(
        generationId: 'gen-old',
        visibleContent: 'old prefix',
        visibleParts: const [],
      ),
      createHttpClient: (_) => client,
    );

    expect(outcome, CancelGenerationOutcome.cancelled);
    final current = await RuntimeEventClient.instance.loadCursor();
    expect(current?.generationId, 'gen-replacement');
    expect(current?.status, GenerationTerminalStatus.running);
  });

  test(
    'cancel 202 keeps cursor until cancelled terminal replay arrives',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-cancel-requested","last_seq":3,'
        '"status":"waiting_tool"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/generations/gen-cancel-requested/cancel');
        expect(request.jsonBody['visible_content'], 'visible');
        expect(request.jsonBody['visible_parts'], isEmpty);
        return FakeHttpResponseData.json({
          'ok': true,
          'generation_id': 'gen-cancel-requested',
          'status': 'cancel_requested',
        }, statusCode: 202);
      });

      final outcome = await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.cancelActive(
          visibleContent: 'visible',
          visibleParts: const [],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome, CancelGenerationOutcome.cancelled);
      final saved = await RuntimeEventClient.instance.loadCursor();
      expect(saved?.generationId, 'gen-cancel-requested');
      expect(saved?.status, GenerationTerminalStatus.waitingTool);
      expect(saved?.lastSeq, 3);
    },
  );

  test('completed late stop reports durable reconciliation', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-reconciled","last_seq":5,'
      '"status":"running"}',
    );
    final client = FakeHttpClient((request) {
      expect(request.jsonBody['visible_content'], 'shown');
      expect(request.jsonBody['visible_parts'], [
        {'type': 'text', 'text': 'shown'},
      ]);
      return FakeHttpResponseData.json({
        'ok': true,
        'generation_id': 'gen-reconciled',
        'status': 'completed',
        'reconciled': true,
      });
    });

    final outcome = await HttpOverrides.runZoned(
      () => RuntimeEventClient.instance.cancelActive(
        visibleContent: 'shown',
        visibleParts: const [
          {'type': 'text', 'text': 'shown'},
        ],
      ),
      createHttpClient: (_) => client,
    );

    expect(outcome, CancelGenerationOutcome.reconciled);
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
  });

  test(
    'cancel 409 reports already terminal without fabricating cancelled',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-completed-race","last_seq":5,'
        '"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        return FakeHttpResponseData.json({
          'ok': false,
          'generation_id': 'gen-completed-race',
          'status': 'completed',
          'error': 'generation already terminal',
        }, statusCode: 409);
      });

      final outcome = await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.cancelActive(
          visibleContent: 'visible',
          visibleParts: const [],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome, CancelGenerationOutcome.alreadyTerminal);
      expect(
        (await RuntimeEventClient.instance.loadCursor())?.status,
        GenerationTerminalStatus.running,
      );
    },
  );

  test(
    'cancel 410 becomes replay unavailable instead of fake terminal',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-runtime-gone","last_seq":2,'
        '"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        return FakeHttpResponseData.json({
          'ok': false,
          'generation_id': 'gen-runtime-gone',
          'status': 'completed',
          'error': 'generation runtime unavailable',
        }, statusCode: 410);
      });

      final outcome = await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.cancelActive(
          visibleContent: 'visible',
          visibleParts: const [],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome, CancelGenerationOutcome.replayUnavailable);
      expect(
        (await RuntimeEventClient.instance.loadCursor())?.status,
        GenerationTerminalStatus.replayUnavailable,
      );
    },
  );

  test(
    'cancel transport failure keeps active cursor and reports failed',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-cancel-failed","last_seq":1,'
        '"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        return FakeHttpResponseData.json({
          'error': 'temporary',
        }, statusCode: 503);
      });

      final outcome = await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.cancelActive(
          visibleContent: 'visible',
          visibleParts: const [],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome, CancelGenerationOutcome.failed);
      expect(
        (await RuntimeEventClient.instance.loadCursor())?.status,
        GenerationTerminalStatus.running,
      );
    },
  );

  test(
    'pending mutation identity survives retry and rejects conflicting payload',
    () async {
      final first = await RuntimeEventClient.instance.prepareMutationCommand(
        kind: 'edit',
        targetEventId: 'ev-edit',
        payloadFingerprint: 'same payload',
        epochId: 'epoch-main',
        localContent: 'edited',
      );
      final second = await RuntimeEventClient.instance.prepareMutationCommand(
        kind: 'edit',
        targetEventId: 'ev-edit',
        payloadFingerprint: 'same payload',
        epochId: 'epoch-main',
        localContent: 'edited',
      );

      expect(second.generationId, first.generationId);
      expect(second.userClientEventId, first.userClientEventId);
      expect(second.assistantClientEventId, first.assistantClientEventId);
      expect(
        () => RuntimeEventClient.instance.prepareMutationCommand(
          kind: 'edit',
          targetEventId: 'ev-edit',
          payloadFingerprint: 'different payload',
          epochId: 'epoch-main',
        ),
        throwsA(
          isA<RuntimeException>().having(
            (error) => error.code,
            'code',
            'command_acceptance_uncertain',
          ),
        ),
      );
    },
  );

  test('canonical chat request uploads only the newest user command', () async {
    final body = await ChatApi.chatRequestBodyForTesting([
      ChatMessage(
        role: 'user',
        content: 'older user',
        eventId: 'event-user-old',
        epochId: 'epoch-main',
      ),
      ChatMessage(
        role: 'assistant',
        content: 'older assistant',
        eventId: 'event-assistant-old',
        epochId: 'epoch-main',
      ),
      ChatMessage(
        role: 'user',
        content: 'latest',
        clientEventId: 'client-latest',
        generationId: 'gen-latest',
      ),
    ]);

    final messages = body['messages'] as List<dynamic>;
    expect(messages, hasLength(1));
    expect((messages.single as Map)['content'], 'latest');
    expect(body['context_epoch_id'], 'epoch-main');
    expect(body['client_event_id'], 'client-latest');
    expect(body['generation_id'], 'gen-latest');
  });

  test(
    'legacy chat request keeps full history before canonical bootstrap',
    () async {
      final body = await ChatApi.chatRequestBodyForTesting([
        ChatMessage(role: 'user', content: 'one'),
        ChatMessage(role: 'assistant', content: 'two'),
        ChatMessage(role: 'user', content: 'three'),
      ]);

      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(3));
      expect(body.containsKey('context_epoch_id'), isFalse);
    },
  );

  test(
    'uncertain POST replays the same durable command after 404 reconciliation',
    () async {
      final runtime = RuntimeEventClient(
        responseHeaderTimeout: const Duration(milliseconds: 50),
        bodyIdleTimeout: const Duration(milliseconds: 50),
        initialRetryDelay: Duration.zero,
        maxRetryDelay: Duration.zero,
        startPostAttempts: 2,
      );
      var postAttempts = 0;
      var getAttempts = 0;
      final postBodies = <Map<String, dynamic>>[];
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          postAttempts += 1;
          postBodies.add(request.jsonBody);
          if (postAttempts == 1) {
            throw const SocketException('first request response lost');
          }
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-same-id'},
            body:
                'id: 1\n'
                'data: {"type":"part","part":{"type":"text","text":"accepted"}}\n\n'
                'id: 2\n'
                'data: [DONE]\n\n',
          );
        }
        getAttempts += 1;
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-same-id/events');
        if (postAttempts == 1) {
          return FakeHttpResponseData.json({
            'error': 'generation not found',
          }, statusCode: 404);
        }
        expect(request.uri.queryParameters['after_seq'], '2');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-same-id'},
          body:
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => runtime.startChat(
          body: {
            'messages': [
              {'role': 'user', 'content': 'same command'},
            ],
          },
          userClientEventId: 'u-same-id',
          assistantClientEventId: 'a-same-id',
          generationId: 'gen-same-id',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(postAttempts, 2);
      expect(getAttempts, 4);
      expect(postBodies, hasLength(2));
      for (final body in postBodies) {
        expect(body['generation_id'], 'gen-same-id');
        expect(body['request_id'], 'gen-same-id');
        expect(body['client_event_id'], 'u-same-id');
      }
      expect(applied, ['accepted']);
      expect(await runtime.loadCursor(), isNull);
    },
  );

  test(
    'uncertain POST transport failure resumes by GET without a second POST',
    () async {
      var postAttempts = 0;
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          postAttempts += 1;
          expect(request.uri.path, '/chat');
          expect(request.jsonBody['generation_id'], 'gen-uncertain');
          expect(request.jsonBody['request_id'], 'gen-uncertain');
          expect(request.jsonBody['client_event_id'], 'u-uncertain');
          throw const SocketException('response lost');
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-uncertain/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-uncertain'},
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"accepted"}}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });
      final applied = <String>[];

      await HttpOverrides.runZoned(
        () => RuntimeEventClient.instance.startChat(
          body: {'messages': const []},
          userClientEventId: 'u-uncertain',
          assistantClientEventId: 'a-uncertain',
          generationId: 'gen-uncertain',
          onEvent: (event, _) {
            final part = event.json?['part'];
            if (part is Map) applied.add(part['text'].toString());
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(postAttempts, 1);
      expect(applied, ['accepted']);
      expect(client.requests, hasLength(2));
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'provider payload carries runtime ids as fields, not content text',
    () async {
      final body = await ChatApi.chatRequestBodyForTesting([
        ChatMessage(
          role: 'user',
          content: 'hello',
          eventId: 'evt-1',
          clientEventId: 'client-1',
          generationId: 'gen-1',
          runtimeSeq: 99,
          runtimeStatus: 'running',
        ),
      ]);

      final messages = body['messages'] as List<dynamic>;
      final user = messages.single as Map<String, dynamic>;
      expect(user['content'], 'hello');
      expect(user['event_id'], 'evt-1');
      expect(user['client_event_id'], 'client-1');
      expect(user['generation_id'], 'gen-1');
      expect(user['content'], isNot(contains('runtimeSeq')));
      expect(user['content'], isNot(contains('running')));
    },
  );
}
