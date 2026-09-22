import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/app_event_client.dart';
import 'package:continuum_chat/services/chat_runtime_controller.dart';
import 'package:continuum_chat/services/device_capability_bridge.dart';
import 'package:continuum_chat/services/nudge_api.dart';
import 'package:continuum_chat/services/runtime_event_client.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';
import 'support/fake_path_provider.dart';

FakeHttpResponseData _canonicalAccepted(FakeHttpRequestData request) {
  final generationId = request.jsonBody['generation_id'].toString();
  final results = request.jsonBody['results'] as List<dynamic>;
  return FakeHttpResponseData.json({
    'ok': true,
    'accepted': [
      for (final result in results.cast<Map<dynamic, dynamic>>())
        {
          'generation_id': generationId,
          'tool_call_id': result['tool_call_id'].toString(),
        },
    ],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;
  final channel = const MethodChannel('nudge');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('continuum_app_event_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    await RuntimeEventClient.instance.clearCursor();
    await RuntimeEventClient.instance.clearPendingCommand();
    ChatRuntimeController.instance.bindMessages(<ChatMessage>[]);
    DeviceCapabilityBridge.instance.resetForTesting();
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ChatRuntimeController.instance.unbindMessages(<ChatMessage>[]);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('MusicPlayer source no longer owns GET pending transport', () async {
    final source = await File('lib/services/music_player.dart').readAsString();

    expect(source, isNot(contains("ServerConfig.url(8816, '/pending')")));
    expect(source, isNot(contains('registerChatHandler')));
    expect(source, contains('handlePendingMessage'));
  });

  test(
    'proactive text enters local cache without ChatPage registration',
    () async {
      final messages = <ChatMessage>[];
      ChatRuntimeController.instance.bindMessages(messages);

      await AppEventClient.instance.dispatchPending([
        {'id': 'msg-1', 'type': 'heartbeat', 'content': '我来了'},
      ]);

      expect(messages, hasLength(1));
      expect(messages.single.role, 'assistant');
      expect(messages.single.content, '我来了');
    },
  );

  test('redelivered proactive pending id is not appended twice', () async {
    final messages = <ChatMessage>[];
    ChatRuntimeController.instance.bindMessages(messages);
    const item = {
      'id': 'msg-redeliver',
      'type': 'heartbeat',
      'content': '只出现一次',
    };

    await AppEventClient.instance.dispatchPending([item]);
    await AppEventClient.instance.dispatchPending([item]);

    expect(messages, hasLength(1));
    expect(messages.single.content, '只出现一次');
    expect(messages.single.clientEventId, 'pending:msg-redeliver');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getStringList('app_event_handled_pending_ids_v1'),
      contains('msg-redeliver'),
    );
  });

  test(
    'restart resume transport loss marks originating send without activity',
    () async {
      final messages = <ChatMessage>[
        ChatMessage(role: 'user', content: '之前的问题', clientEventId: 'u-restart'),
      ];
      ChatRuntimeController.instance.bindMessages(messages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-gone","last_seq":4,'
        '"status":"running","user_client_event_id":"u-restart",'
        '"assistant_client_event_id":"a-restart"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-gone/events');
        return FakeHttpResponseData.json({
          'error': 'generation replay unavailable',
          'status': 'unknown',
        }, statusCode: 410);
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.resumeActiveGeneration(),
        createHttpClient: (_) => client,
      );

      expect(ChatRuntimeController.instance.isSending, isFalse);
      expect(messages, hasLength(1));
      expect(messages.single.role, 'user');
      expect(messages.single.sendFailed, isTrue);
      expect(messages.single.sendError, contains('replay_unavailable'));
      expect(messages.where((message) => message.role == 'activity'), isEmpty);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test('restart 404 exhausts race retry then marks user send failed', () async {
    final user = ChatMessage(
      role: 'user',
      content: '还没被接收',
      clientEventId: 'u-not-accepted',
    );
    final messages = <ChatMessage>[user];
    ChatRuntimeController.instance.bindMessages(messages);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-not-accepted","last_seq":0,'
      '"status":"running","user_client_event_id":"u-not-accepted",'
      '"assistant_client_event_id":"a-not-accepted"}',
    );
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData.json({
        'error': 'generation not found',
      }, statusCode: 404),
    );

    await HttpOverrides.runZoned(
      () => ChatRuntimeController.instance.resumeActiveGeneration(),
      createHttpClient: (_) => client,
    );

    expect(client.requests, hasLength(3));
    expect(
      client.requests.map((request) => request.method),
      everyElement('GET'),
    );
    expect(messages, [user]);
    expect(user.sendFailed, isTrue);
    expect(user.sendError, contains('generation_not_accepted'));
    expect(messages.where((message) => message.role == 'activity'), isEmpty);
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
  });

  test('restart marks untracked trailing local user bubble failed', () async {
    final user = ChatMessage(role: 'user', content: '本地幽灵消息');
    final messages = <ChatMessage>[user];
    ChatRuntimeController.instance.bindMessages(messages);

    await ChatRuntimeController.instance.resumeActiveGeneration();

    expect(messages, [user]);
    expect(user.sendFailed, isTrue);
    expect(user.sendError, contains('local_send_identity_missing'));
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    expect(ChatRuntimeController.instance.isSending, isFalse);
  });

  test(
    'restart rebuilds missing cursor from trailing generation id then marks 404 failed',
    () async {
      final user = ChatMessage(
        role: 'user',
        content: '有 generation 但 cursor 丢了',
        clientEventId: 'u-orphan-generation',
        generationId: 'gen-orphan-generation',
      );
      final messages = <ChatMessage>[user];
      ChatRuntimeController.instance.bindMessages(messages);
      final client = FakeHttpClient(
        (_) => FakeHttpResponseData.json({
          'error': 'generation not found',
        }, statusCode: 404),
      );

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.resumeActiveGeneration(),
        createHttpClient: (_) => client,
      );

      expect(client.requests, hasLength(3));
      expect(
        client.requests.map((request) => request.method),
        everyElement('GET'),
      );
      expect(messages, [user]);
      expect(user.sendFailed, isTrue);
      expect(user.sendError, contains('generation_not_accepted'));
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
      expect(ChatRuntimeController.instance.isSending, isFalse);
    },
  );

  test(
    'send cursor is durable before local message persistence finishes',
    () async {
      final sent = ChatMessage(role: 'user', content: '先保 recovery identity');
      final reply = ChatMessage(role: 'assistant', content: '');
      final messages = <ChatMessage>[sent, reply];
      final saveStarted = Completer<void>();
      final saveGate = Completer<void>();
      final client = FakeHttpClient(
        (request) => FakeHttpResponseData(
          statusCode: 200,
          headers: {
            'x-generation-id': request.jsonBody['generation_id'].toString(),
          },
          body:
              'id: 1\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        ),
      );

      await HttpOverrides.runZoned(() async {
        final operation = ChatRuntimeController.instance.startChat(
          messages: messages,
          history: [sent],
          sentMessage: sent,
          reply: reply,
          messageSaver: (_) {
            if (!saveStarted.isCompleted) saveStarted.complete();
            return saveGate.future;
          },
        );
        await saveStarted.future;

        final cursor = await RuntimeEventClient.instance.loadCursor();
        expect(cursor, isNotNull);
        expect(cursor?.generationId, sent.generationId);
        expect(cursor?.userClientEventId, sent.clientEventId);
        expect(cursor?.assistantClientEventId, reply.clientEventId);
        expect(client.requests, isEmpty);

        saveGate.complete();
        await operation;
      }, createHttpClient: (_) => client);
    },
  );

  test('send cursor is durable before request body preparation', () async {
    final sent = ChatMessage(role: 'user', content: '还在准备');
    final reply = ChatMessage(role: 'assistant', content: '');
    final messages = <ChatMessage>[sent, reply];
    final bodyGate = Completer<Map<String, dynamic>>();
    final bodyBuilderStarted = Completer<void>();
    final client = FakeHttpClient(
      (request) => FakeHttpResponseData(
        statusCode: 200,
        headers: {
          'x-generation-id': request.jsonBody['generation_id'].toString(),
        },
        body:
            'id: 1\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      ),
    );

    await HttpOverrides.runZoned(() async {
      final operation = ChatRuntimeController.instance.startChat(
        messages: messages,
        history: [sent],
        sentMessage: sent,
        reply: reply,
        requestBodyBuilder: (_) {
          bodyBuilderStarted.complete();
          return bodyGate.future;
        },
      );
      await bodyBuilderStarted.future;

      final cursor = await RuntimeEventClient.instance.loadCursor();
      expect(cursor, isNotNull);
      expect(cursor?.generationId, sent.generationId);
      expect(cursor?.userClientEventId, sent.clientEventId);
      expect(cursor?.assistantClientEventId, reply.clientEventId);
      expect(client.requests, isEmpty);

      bodyGate.complete(const <String, dynamic>{});
      await operation;
    }, createHttpClient: (_) => client);
  });

  test(
    '410 completed snapshot restores canonical reply without retry send',
    () async {
      final messages = <ChatMessage>[
        ChatMessage(role: 'user', content: '已接收的问题', clientEventId: 'u-410'),
      ];
      ChatRuntimeController.instance.bindMessages(messages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-410","last_seq":0,'
        '"status":"running","user_client_event_id":"u-410",'
        '"assistant_client_event_id":"a-410"}',
      );
      final client = FakeHttpClient(
        (_) => FakeHttpResponseData.json({
          'error': 'generation replay unavailable',
          'status': 'completed',
          'canonical_generation': {
            'lifecycle': {'status': 'completed', 'terminal': true},
            'reconciliation': {
              'canonical_event': {
                'event_id': 'assistant-event-410',
                'epoch_id': 'epoch-410',
                'generation_id': 'gen-410',
                'role': 'assistant',
                'content': '已经做完了',
                'parts': [
                  {'type': 'text', 'text': '已经做完了'},
                ],
              },
            },
          },
        }, statusCode: 410),
      );

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.resumeActiveGeneration(),
        createHttpClient: (_) => client,
      );

      expect(client.requests.map((request) => request.method), ['GET']);
      expect(messages, hasLength(2));
      expect(messages.last.role, 'assistant');
      expect(messages.last.content, '已经做完了');
      expect(messages.last.eventId, 'assistant-event-410');
      expect(messages.last.runtimeStatus, 'completed');
      expect(messages.first.sendFailed, isFalse);
      expect(messages.where((message) => message.role == 'activity'), isEmpty);
    },
  );

  test('410 failed snapshot preserves partial assistant output', () async {
    final user = ChatMessage(
      role: 'user',
      content: '部分回复测试',
      clientEventId: 'u-partial-410',
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '已经看到的部分',
      clientEventId: 'a-partial-410',
      generationId: 'gen-partial-410',
      runtimeStatus: 'running',
    );
    final messages = <ChatMessage>[user, reply];
    ChatRuntimeController.instance.bindMessages(messages);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-partial-410","last_seq":3,'
      '"status":"running","user_client_event_id":"u-partial-410",'
      '"assistant_client_event_id":"a-partial-410"}',
    );
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData.json({
        'error': 'generation replay unavailable',
        'status': 'failed',
        'canonical_generation': {
          'lifecycle': {
            'status': 'failed',
            'terminal': true,
            'terminal_reason': 'upstream_disconnected',
          },
          'reconciliation': {'canonical_event': null},
        },
      }, statusCode: 410),
    );

    await HttpOverrides.runZoned(
      () => ChatRuntimeController.instance.resumeActiveGeneration(),
      createHttpClient: (_) => client,
    );

    expect(messages, [user, reply]);
    expect(reply.content, '已经看到的部分');
    expect(reply.runtimeStatus, 'failed');
    expect(user.sendFailed, isFalse);
    expect(messages.where((message) => message.role == 'activity'), isEmpty);
  });

  test(
    'restart replays completed generation from seq zero and clears cursor',
    () async {
      final messages = <ChatMessage>[
        ChatMessage(
          role: 'user',
          content: '之前的问题',
          clientEventId: 'u-completed',
        ),
      ];
      ChatRuntimeController.instance.bindMessages(messages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-completed","last_seq":0,'
        '"status":"running","user_client_event_id":"u-completed",'
        '"assistant_client_event_id":"a-completed"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-completed/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 853\n'
              'data: {"type":"part","part":{"type":"text","text":"已恢复"}}\n\n'
              'id: 854\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.resumeActiveGeneration(),
        createHttpClient: (_) => client,
      );

      expect(client.requests.map((request) => request.method), ['GET']);
      expect(messages, hasLength(2));
      expect(messages.last.role, 'assistant');
      expect(messages.last.content, '已恢复');
      expect(messages.last.runtimeSeq, 854);
      expect(messages.last.runtimeStatus, 'completed');
      expect(ChatRuntimeController.instance.isSending, isFalse);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
    },
  );

  test(
    'transient restart replay recovers same generation and allows next send',
    () async {
      final messages = <ChatMessage>[
        ChatMessage(
          role: 'user',
          content: '旧问题',
          clientEventId: 'u-failed-replay',
        ),
      ];
      ChatRuntimeController.instance.bindMessages(messages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-failed-replay","last_seq":0,'
        '"status":"running","user_client_event_id":"u-failed-replay",'
        '"assistant_client_event_id":"a-failed-replay"}',
      );
      var replayAttempts = 0;
      final client = FakeHttpClient((request) {
        if (request.method == 'GET') {
          expect(request.uri.path, '/generations/gen-failed-replay/events');
          replayAttempts += 1;
          if (replayAttempts == 1) {
            return const FakeHttpResponseData(statusCode: 503);
          }
          return const FakeHttpResponseData(
            statusCode: 200,
            body:
                'id: 1\n'
                'data: {"type":"generation_terminal","status":"failed","error_code":"upstream_error"}\n\n',
          );
        }
        expect(request.method, 'POST');
        expect(request.uri.path, '/chat');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-next'},
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"新回复"}}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(() async {
        await ChatRuntimeController.instance.resumeActiveGeneration();

        expect(ChatRuntimeController.instance.isSending, isFalse);
        expect(messages, hasLength(1));
        expect(messages.single.role, 'user');
        expect(messages.single.sendFailed, isTrue);
        expect(messages.single.sendError, contains('upstream_error'));
        expect(await RuntimeEventClient.instance.loadCursor(), isNull);

        final nextUser = ChatMessage(
          role: 'user',
          content: '新问题',
          clientEventId: 'u-next',
          generationId: 'gen-next',
        );
        final nextReply = ChatMessage(
          role: 'assistant',
          content: '',
          clientEventId: 'a-next',
          generationId: 'gen-next',
        );
        messages.addAll([nextUser, nextReply]);
        await ChatRuntimeController.instance.startChat(
          messages: messages,
          history: [nextUser],
          sentMessage: nextUser,
          reply: nextReply,
        );

        expect(nextUser.sendFailed, isFalse);
        expect(nextReply.content, '新回复');
        expect(nextReply.runtimeStatus, 'completed');
      }, createHttpClient: (_) => client);

      expect(client.requests.map((request) => request.method), [
        'GET',
        'GET',
        'POST',
      ]);
    },
  );

  test('concurrent startup and lifecycle resumes are singleflight', () async {
    final messages = <ChatMessage>[
      ChatMessage(role: 'user', content: '问', clientEventId: 'u-wakeup'),
    ];
    ChatRuntimeController.instance.bindMessages(messages);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-wakeup","last_seq":0,'
      '"status":"running","user_client_event_id":"u-wakeup",'
      '"assistant_client_event_id":"a-wakeup"}',
    );
    final response = StreamController<List<int>>();
    final requestStarted = Completer<void>();
    final client = FakeHttpClient((request) {
      expect(request.method, 'GET');
      if (!requestStarted.isCompleted) requestStarted.complete();
      return FakeHttpResponseData(statusCode: 200, bodyStream: response.stream);
    });

    await HttpOverrides.runZoned(() async {
      final first = ChatRuntimeController.instance.resumeActiveGeneration();
      final second = ChatRuntimeController.instance.resumeActiveGeneration();
      final third = ChatRuntimeController.instance.resumeActiveGeneration();
      await requestStarted.future;
      expect(client.requests, hasLength(1));

      response.add(
        utf8.encode(
          'id: 1\n'
          'data: {"type":"generation_terminal","status":"completed"}\n\n',
        ),
      );
      await response.close();
      await Future.wait([first, second, third]);
    }, createHttpClient: (_) => client);

    expect(client.requests, hasLength(1));
    expect(await RuntimeEventClient.instance.loadCursor(), isNull);
  });

  test(
    'runtime batch prefers structured part over legacy duplicate content',
    () async {
      final sent = ChatMessage(
        role: 'user',
        content: '测试',
        generationId: 'gen-parts',
      );
      final reply = ChatMessage(role: 'assistant', content: '');
      final messages = <ChatMessage>[sent, reply];
      ChatRuntimeController.instance.bindMessages(messages);
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          expect(request.uri.path, '/chat');
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-parts'},
            body:
                'id: 1\n'
                'data: {"type":"part","part":{"type":"text","text":"唯一正文","round":1}}\n\n'
                'data: {"choices":[{"delta":{"content":"唯一正文"}}]}\n\n'
                'data: {"type":"metadata","user_raw_event_id":31,"assistant_raw_event_id":32}\n\n'
                'data: [DONE]\n\n',
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-parts/events');
        expect(request.uri.queryParameters['after_seq'], '1');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startChat(
          messages: messages,
          history: [sent],
          sentMessage: sent,
          reply: reply,
        ),
        createHttpClient: (_) => client,
      );

      expect(reply.content, '唯一正文');
      expect(reply.rawEventId, 32);
      expect(sent.rawEventId, 31);
      expect(reply.runtimeSeq, 2);
      expect(reply.runtimeStatus, 'completed');
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
    },
  );

  test(
    'no response card keeps runtime identity for later terminal replay',
    () async {
      final sent = ChatMessage(
        role: 'user',
        content: '测试',
        generationId: 'gen-no-response',
      );
      final reply = ChatMessage(role: 'assistant', content: '');
      final messages = <ChatMessage>[sent, reply];
      ChatRuntimeController.instance.bindMessages(messages);
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          expect(request.uri.path, '/chat');
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-no-response'},
            body:
                'id: 1\n'
                'data: {"type":"no_response","content":"暂时没有回应"}\n\n'
                'data: [DONE]\n\n',
          );
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-no-response/events');
        expect(request.uri.queryParameters['after_seq'], '1');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startChat(
          messages: messages,
          history: [sent],
          sentMessage: sent,
          reply: reply,
        ),
        createHttpClient: (_) => client,
      );

      expect(messages, hasLength(2));
      expect(messages.last.role, 'activity');
      expect(messages.last.content, '暂时没有回应');
      expect(messages.last.clientEventId, reply.clientEventId);
      expect(messages.last.generationId, 'gen-no-response');
      expect(messages.last.runtimeSeq, 2);
      expect(messages.last.runtimeStatus, 'completed');
      expect(
        messages.where(
          (message) => message.role == 'assistant' && message.content.isEmpty,
        ),
        isEmpty,
      );
      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
    },
  );

  test(
    'restart replay skips a seq already applied to durable chat cache',
    () async {
      final messages = <ChatMessage>[
        ChatMessage(role: 'user', content: '问', clientEventId: 'u-applied'),
        ChatMessage(
          role: 'assistant',
          content: '已经落盘',
          clientEventId: 'a-applied',
          generationId: 'gen-applied',
          runtimeSeq: 1,
          runtimeStatus: 'running',
        ),
      ];
      ChatRuntimeController.instance.bindMessages(messages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-applied","last_seq":0,'
        '"status":"running","user_client_event_id":"u-applied",'
        '"assistant_client_event_id":"a-applied"}',
      );
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-applied/events');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"已经落盘"}}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.resumeActiveGeneration(),
        createHttpClient: (_) => client,
      );

      expect(messages[1].content, '已经落盘');
      expect(messages[1].runtimeSeq, 2);
      expect(messages[1].runtimeStatus, 'completed');
      expect(ChatRuntimeController.instance.isSending, isFalse);
    },
  );

  test('music pending is diverted away from chat cache', () async {
    final messages = <ChatMessage>[];
    ChatRuntimeController.instance.bindMessages(messages);

    await AppEventClient.instance.dispatchPending([
      {'id': 'music-1', 'type': 'music', 'content': '{"action":"pause"}'},
      {'id': 'chat-1', 'type': 'heartbeat', 'content': '聊天'},
    ]);

    expect(messages.map((message) => message.content), ['聊天']);
  });

  test(
    'legacy proactive nudge tool reports by msg_id and keeps ack separate',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'call');
            expect(call.arguments['tool'], NudgeApi.ping);
            return '{"success":true,"description":"pong"}';
          });
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/tool-result');
        expect(request.jsonBody['msg_id'], 'tool-1');
        expect(request.jsonBody, isNot(contains('chat_id')));
        expect(request.jsonBody, isNot(contains('round')));
        return FakeHttpResponseData.json({'ok': true, 'msg_id': 'tool-1'});
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executePendingTools(
          msgId: 'tool-1',
          tools: [
            {
              'kind': 'nudge',
              'tool': NudgeApi.ping,
              'arguments': {'x': 1},
            },
          ],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isTrue);
      expect(outcome.labels, isNotEmpty);
      expect(client.requests, hasLength(1));
    },
  );

  test('canonical report retry does not repeat the device action', () async {
    var deviceCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          deviceCalls += 1;
          expect(call.method, 'call');
          expect(call.arguments['tool'], NudgeApi.deviceStatus);
          return '{"success":true,"description":"battery=80"}';
        });
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.uri.path, '/tool-result');
      final attempt = client.requests.length;
      return attempt == 1
          ? FakeHttpResponseData.json({'error': 'temporary'}, statusCode: 500)
          : _canonicalAccepted(request);
    });
    final tools = [
      {
        'kind': 'nudge',
        'generation_id': 'gen-retry-report',
        'tool_call_id': 'call-retry-report',
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      },
    ];

    final first = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executePendingTools(
        msgId: 'tool-retry-report',
        generationId: 'gen-retry-report',
        tools: tools,
      ),
      createHttpClient: (_) => client,
    );
    final second = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executePendingTools(
        msgId: 'tool-retry-report-redelivery',
        generationId: 'gen-retry-report',
        tools: tools,
      ),
      createHttpClient: (_) => client,
    );

    expect(first.reported, isFalse);
    expect(first.labels, isEmpty);
    expect(second.reported, isTrue);
    expect(second.labels, isNotEmpty);
    expect(deviceCalls, 1);
    expect(client.requests, hasLength(2));
  });

  test(
    'canonical fingerprint is stable and conflicting payload fails closed',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        if (client.requests.length == 1) {
          return const FakeHttpResponseData(statusCode: 503);
        }
        return _canonicalAccepted(request);
      });
      final original = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': 'gen-fingerprint',
        'tool_call_id': 'call-fingerprint',
        'tool': NudgeApi.deviceStatus,
        'arguments': {
          'b': 2,
          'a': {'y': 2, 'x': 1},
        },
      };
      final reordered = <String, dynamic>{
        ...original,
        'arguments': {
          'a': {'x': 1, 'y': 2},
          'b': 2,
        },
      };
      final conflicting = <String, dynamic>{
        ...original,
        'arguments': {'a': 99, 'b': 2},
      };
      expect(
        DeviceCapabilityBridge.actionFingerprintForTesting(original),
        DeviceCapabilityBridge.actionFingerprintForTesting(reordered),
      );

      final first = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-fingerprint',
          tools: [original],
        ),
        createHttpClient: (_) => client,
      );
      final conflict = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-fingerprint',
          tools: [conflicting],
        ),
        createHttpClient: (_) => client,
      );
      final retry = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-fingerprint',
          tools: [reordered],
        ),
        createHttpClient: (_) => client,
      );

      expect(first.reported, isFalse);
      expect(conflict.reported, isFalse);
      expect(retry.reported, isTrue);
      expect(deviceCalls, 1);
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'canonical report retry after App process restart reuses durable result',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            deviceCalls += 1;
            return '{"success":true,"description":"battery=77"}';
          });
      late final FakeHttpClient client;
      client = FakeHttpClient((request) {
        expect(request.uri.path, '/tool-result');
        final attempt = client.requests.length;
        return attempt == 1
            ? FakeHttpResponseData.json({
                'error': 'response lost',
              }, statusCode: 500)
            : _canonicalAccepted(request);
      });
      final tools = [
        {
          'kind': 'nudge',
          'generation_id': 'gen-process-restart',
          'tool_call_id': 'call-process-restart',
          'tool': NudgeApi.deviceStatus,
          'arguments': <String, dynamic>{},
        },
      ];

      final first = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-process-restart',
          tools: tools,
        ),
        createHttpClient: (_) => client,
      );
      expect(first.reported, isFalse);
      expect(deviceCalls, 1);

      // Simulate a new App process: volatile bridge state is gone, while
      // SharedPreferences survives. The physical action must not run twice.
      DeviceCapabilityBridge.instance.resetForTesting();
      final second = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-process-restart',
          tools: tools,
        ),
        createHttpClient: (_) => client,
      );

      expect(second.reported, isTrue);
      expect(deviceCalls, 1);
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'restart after durable claim fails closed instead of re-executing',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final prefs = await SharedPreferences.getInstance();
      const generationId = 'gen-claimed';
      const toolCallId = 'call-claimed';
      final canonicalKey = '${generationId.length}:$generationId$toolCallId';
      final claimedTool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': generationId,
        'tool_call_id': toolCallId,
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      };
      await prefs.setString(
        DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
        jsonEncode({
          canonicalKey: {
            'state': 'claimed',
            'generation_id': generationId,
            'tool_call_id': toolCallId,
            'fingerprint': DeviceCapabilityBridge.actionFingerprintForTesting(
              claimedTool,
            ),
            'updated_at_ms': 1,
          },
        }),
      );
      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/tool-result');
        expect(request.jsonBody['generation_id'], generationId);
        final result = request.jsonBody['results'][0]['result'];
        expect(result['error'], 'device_execution_uncertain');
        return _canonicalAccepted(request);
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: generationId,
          tools: [claimedTool],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isTrue);
      expect(deviceCalls, 0);
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'pre-fingerprint completed tombstone does not poison upgraded journal',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const oldGenerationId = 'gen-old-v1';
      const oldToolCallId = 'call-old-v1';
      final oldKey = '${oldGenerationId.length}:$oldGenerationId$oldToolCallId';
      await prefs.setString(
        DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
        jsonEncode({
          oldKey: {
            'state': 'completed',
            'generation_id': oldGenerationId,
            'tool_call_id': oldToolCallId,
            'updated_at_ms': 1,
          },
        }),
      );
      DeviceCapabilityBridge.instance.resetForTesting();

      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final client = FakeHttpClient(_canonicalAccepted);
      final tool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': 'gen-after-upgrade',
        'tool_call_id': 'call-after-upgrade',
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      };

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-after-upgrade',
          tools: [tool],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isTrue);
      expect(deviceCalls, 1);
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'pre-fingerprint claimed replay binds payload and never reexecutes',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const generationId = 'gen-old-claimed';
      const toolCallId = 'call-old-claimed';
      final key = '${generationId.length}:$generationId$toolCallId';
      final tool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': generationId,
        'tool_call_id': toolCallId,
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      };
      await prefs.setString(
        DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
        jsonEncode({
          key: {
            'state': 'claimed',
            'generation_id': generationId,
            'tool_call_id': toolCallId,
            'updated_at_ms': 1,
          },
        }),
      );
      DeviceCapabilityBridge.instance.resetForTesting();

      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final client = FakeHttpClient((request) {
        final result = request.jsonBody['results'][0]['result'];
        expect(result['error'], 'device_execution_uncertain');
        return _canonicalAccepted(request);
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: generationId,
          tools: [tool],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isTrue);
      expect(deviceCalls, 0);
      expect(client.requests, hasLength(1));
      final stored =
          jsonDecode(
                prefs.getString(
                  DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
                )!,
              )
              as Map<String, dynamic>;
      expect(stored[key]['state'], 'completed');
      expect(
        stored[key]['fingerprint'],
        DeviceCapabilityBridge.actionFingerprintForTesting(tool),
      );
    },
  );

  test(
    'corrupt canonical journal fails closed with zero action and report',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
        '{not-json',
      );
      DeviceCapabilityBridge.instance.resetForTesting();
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final client = FakeHttpClient((_) {
        fail('corrupt journal must not report');
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-corrupt',
          tools: [
            {
              'kind': 'nudge',
              'generation_id': 'gen-corrupt',
              'tool_call_id': 'call-corrupt',
              'tool': NudgeApi.deviceStatus,
              'arguments': <String, dynamic>{},
            },
          ],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isFalse);
      expect(deviceCalls, 0);
      expect(client.requests, isEmpty);
    },
  );

  test(
    'completed and closed tombstones survive restart without reports',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final completedTool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': 'gen-completed-journal',
        'tool_call_id': 'call-completed-journal',
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      };
      final closedTool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': 'gen-closed-journal',
        'tool_call_id': 'call-closed-journal',
        'tool': NudgeApi.deviceStatus,
        'arguments': <String, dynamic>{},
      };
      final client = FakeHttpClient((request) {
        if (request.jsonBody['generation_id'] == 'gen-closed-journal') {
          return FakeHttpResponseData.json({
            'ok': false,
            'generation_id': 'gen-closed-journal',
            'tool_call_id': 'call-closed-journal',
          }, statusCode: 410);
        }
        return _canonicalAccepted(request);
      });

      for (final entry in <(String, Map<String, dynamic>)>[
        ('gen-completed-journal', completedTool),
        ('gen-closed-journal', closedTool),
      ]) {
        final first = await HttpOverrides.runZoned(
          () => DeviceCapabilityBridge.instance.executeCanonicalTools(
            generationId: entry.$1,
            tools: [entry.$2],
          ),
          createHttpClient: (_) => client,
        );
        expect(first.reported, isTrue);
        DeviceCapabilityBridge.instance.resetForTesting();
        final replay = await HttpOverrides.runZoned(
          () => DeviceCapabilityBridge.instance.executeCanonicalTools(
            generationId: entry.$1,
            tools: [entry.$2],
          ),
          createHttpClient: (_) => client,
        );
        expect(replay.reported, isTrue);
        expect(replay.labels, isEmpty);
      }

      expect(deviceCalls, 2);
      expect(client.requests, hasLength(2));
    },
  );

  test('more than 2048 completed tombstones remain replay-safe', () async {
    const generationId = 'gen-large-journal';
    final journal = <String, dynamic>{};
    for (var index = 0; index < 2050; index += 1) {
      final toolCallId = 'call-$index';
      final tool = <String, dynamic>{
        'kind': 'nudge',
        'generation_id': generationId,
        'tool_call_id': toolCallId,
        'tool': NudgeApi.deviceStatus,
        'arguments': {'index': index},
      };
      journal['${generationId.length}:$generationId$toolCallId'] = {
        'state': 'completed',
        'generation_id': generationId,
        'tool_call_id': toolCallId,
        'fingerprint': DeviceCapabilityBridge.actionFingerprintForTesting(tool),
        'updated_at_ms': index,
      };
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DeviceCapabilityBridge.canonicalJournalPrefsKeyForTesting,
      jsonEncode(journal),
    );
    DeviceCapabilityBridge.instance.resetForTesting();
    final oldest = <String, dynamic>{
      'kind': 'nudge',
      'generation_id': generationId,
      'tool_call_id': 'call-0',
      'tool': NudgeApi.deviceStatus,
      'arguments': {'index': 0},
    };
    final client = FakeHttpClient((_) {
      fail('completed tombstone must not report');
    });

    final outcome = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executeCanonicalTools(
        generationId: generationId,
        tools: [oldest],
      ),
      createHttpClient: (_) => client,
    );

    expect(outcome.reported, isTrue);
    expect(client.requests, isEmpty);
  });

  test(
    'mixed canonical batch validates fully before any physical action',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final client = FakeHttpClient((_) {
        fail('invalid mixed batch must not report');
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executeCanonicalTools(
          generationId: 'gen-mixed',
          tools: [
            {
              'kind': 'nudge',
              'generation_id': 'gen-mixed',
              'tool_call_id': 'call-valid',
              'tool': NudgeApi.deviceStatus,
              'arguments': <String, dynamic>{},
            },
            {
              'kind': 'nudge',
              'generation_id': 'wrong-generation',
              'tool_call_id': 'call-invalid',
              'tool': NudgeApi.deviceStatus,
              'arguments': <String, dynamic>{},
            },
          ],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isFalse);
      expect(deviceCalls, 0);
      expect(client.requests, isEmpty);
    },
  );

  test(
    'legacy msg-id restart reuses executed result without a second action',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      late final FakeHttpClient client;
      client = FakeHttpClient(
        (_) => FakeHttpResponseData.json(
          client.requests.length == 1 ? {'error': 'temporary'} : {'ok': true},
          statusCode: client.requests.length == 1 ? 503 : 200,
        ),
      );
      final tools = <Map<String, dynamic>>[
        {
          'kind': 'nudge',
          'tool': NudgeApi.ping,
          'arguments': <String, dynamic>{},
        },
      ];

      final first = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executePendingTools(
          msgId: 'legacy-restart',
          tools: tools,
        ),
        createHttpClient: (_) => client,
      );
      DeviceCapabilityBridge.instance.resetForTesting();
      final second = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executePendingTools(
          msgId: 'legacy-restart',
          tools: tools,
        ),
        createHttpClient: (_) => client,
      );

      expect(first.reported, isFalse);
      expect(second.reported, isTrue);
      expect(deviceCalls, 1);
      expect(client.requests, hasLength(2));
    },
  );

  test(
    'partial canonical pending identity never falls back to legacy execution',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final client = FakeHttpClient((request) {
        fail(
          'invalid canonical identity must not report through legacy msg_id',
        );
      });

      final outcome = await HttpOverrides.runZoned(
        () => DeviceCapabilityBridge.instance.executePendingTools(
          msgId: 'legacy-wrapper',
          generationId: 'gen-scope-a',
          tools: [
            {
              'kind': 'nudge',
              'generation_id': 'gen-scope-b',
              'tool_call_id': 'call-scope',
              'tool': NudgeApi.deviceStatus,
              'arguments': <String, dynamic>{},
            },
          ],
        ),
        createHttpClient: (_) => client,
      );

      expect(outcome.reported, isFalse);
      expect(outcome.labels, isEmpty);
      expect(deviceCalls, 0);
      expect(client.requests, isEmpty);
    },
  );

  test('stream nudge reports canonical generation and tool call', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'call');
          expect(call.arguments['tool'], NudgeApi.deviceStatus);
          return '{"success":true,"description":"battery=80"}';
        });
    late final FakeHttpClient client;
    client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/tool-result');
      expect(request.jsonBody['generation_id'], 'gen-stream');
      expect(request.jsonBody['results'], [
        {
          'tool_call_id': 'call-stream',
          'result': {
            'command': NudgeApi.deviceStatus,
            'ok': true,
            'output': '{"success":true,"description":"battery=80"}',
          },
        },
      ]);
      expect(request.jsonBody, isNot(contains('msg_id')));
      return _canonicalAccepted(request);
    });

    final ok = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executeStreamNudge(
        generationId: 'gen-stream',
        calls: [
          {
            'tool_call_id': 'call-stream',
            'tool': NudgeApi.deviceStatus,
            'arguments': {'brief': true},
          },
        ],
      ),
      createHttpClient: (_) => client,
    );

    expect(ok, isTrue);
    expect(client.requests, hasLength(1));
  });

  test('SSE and pending redelivery execute one canonical action', () async {
    var deviceCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          deviceCalls += 1;
          return '{"success":true,"description":"ok"}';
        });
    final client = FakeHttpClient(_canonicalAccepted);
    final call = {
      'generation_id': 'gen-overlap',
      'tool_call_id': 'call-overlap',
      'kind': 'nudge',
      'tool': NudgeApi.deviceStatus,
      'arguments': <String, dynamic>{},
    };

    final streamReported = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executeStreamNudge(
        generationId: 'gen-overlap',
        calls: [call],
      ),
      createHttpClient: (_) => client,
    );
    final pendingOutcome = await HttpOverrides.runZoned(
      () => DeviceCapabilityBridge.instance.executePendingTools(
        msgId: 'legacy-delivery-wrapper',
        generationId: 'gen-overlap',
        tools: [call],
      ),
      createHttpClient: (_) => client,
    );

    expect(streamReported, isTrue);
    expect(pendingOutcome.reported, isTrue);
    expect(pendingOutcome.labels, isEmpty);
    expect(deviceCalls, 1);
    expect(client.requests, hasLength(1));
  });

  test('stale POST stream cannot adopt replacement generation identity', () async {
    final oldBody = StreamController<List<int>>();
    final newBody = StreamController<List<int>>();
    final oldAccepted = Completer<void>();
    final newAccepted = Completer<void>();
    final oldApplied = <String>[];
    final newApplied = <String>[];
    final client = FakeHttpClient((request) {
      final generationId = request.jsonBody['generation_id'].toString();
      if (generationId == 'gen-old') {
        if (!oldAccepted.isCompleted) oldAccepted.complete();
        return FakeHttpResponseData(
          statusCode: 200,
          headers: const {'x-generation-id': 'gen-old'},
          bodyStream: oldBody.stream,
        );
      }
      if (generationId == 'gen-new') {
        if (!newAccepted.isCompleted) newAccepted.complete();
        return FakeHttpResponseData(
          statusCode: 200,
          headers: const {'x-generation-id': 'gen-new'},
          bodyStream: newBody.stream,
        );
      }
      throw StateError('unexpected request $generationId');
    });

    await HttpOverrides.runZoned(() async {
      final oldOperation = RuntimeEventClient.instance.startChat(
        body: {
          'messages': const [
            {'role': 'user', 'content': 'old'},
          ],
        },
        userClientEventId: 'u-old',
        assistantClientEventId: 'a-old',
        generationId: 'gen-old',
        onEvent: (event, cursor) {
          oldApplied.add('${cursor.generationId}:${event.payloads.join('|')}');
        },
      );
      await oldAccepted.future;
      GenerationCursor? oldCursor;
      for (var attempt = 0; attempt < 20; attempt++) {
        oldCursor = await RuntimeEventClient.instance.loadCursor();
        if (oldCursor?.generationId == 'gen-old') break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(oldCursor?.generationId, 'gen-old');
      await RuntimeEventClient.instance.clearCursor(generationId: 'gen-old');

      final newOperation = RuntimeEventClient.instance.startChat(
        body: {
          'messages': const [
            {'role': 'user', 'content': 'new'},
          ],
        },
        userClientEventId: 'u-new',
        assistantClientEventId: 'a-new',
        generationId: 'gen-new',
        onEvent: (event, cursor) {
          newApplied.add('${cursor.generationId}:${event.payloads.join('|')}');
        },
      );
      await newAccepted.future;

      oldBody.add(
        utf8.encode(
          'id: 1\ndata: {"type":"part","part":{"type":"text","delta":"OLD"}}\n\n',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(oldApplied, isEmpty);
      expect(newApplied, isEmpty);

      newBody.add(
        utf8.encode(
          'id: 1\ndata: {"type":"part","part":{"type":"text","delta":"NEW"}}\n\n'
          'id: 2\ndata: {"type":"generation_terminal","status":"completed"}\n\n',
        ),
      );
      await newBody.close();
      await oldBody.close();
      await Future.wait([oldOperation, newOperation]);

      expect(newApplied.join('\n'), contains('gen-new'));
      expect(newApplied.join('\n'), contains('NEW'));
      expect(newApplied.join('\n'), isNot(contains('OLD')));
    }, createHttpClient: (_) => client);
  });
}
