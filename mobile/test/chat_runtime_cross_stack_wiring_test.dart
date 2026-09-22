import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_api.dart';
import 'package:continuum_chat/services/chat_runtime_controller.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/services/runtime_event_client.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';
import 'support/fake_path_provider.dart';

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition did not become true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;
  late List<ChatMessage> boundMessages;
  final nudgeChannel = const MethodChannel('nudge');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('continuum_cross_stack_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    await RuntimeEventClient.instance.clearCursor();
    await RuntimeEventClient.instance.clearPendingCommand();
    ChatStore.cache = null;
    boundMessages = <ChatMessage>[];
  });

  tearDown(() async {
    ChatRuntimeController.instance.unbindMessages(boundMessages);
    await RuntimeEventClient.instance.clearCursor();
    ChatStore.cache = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nudgeChannel, null);
    PathProviderPlatform.instance = previousPathProvider;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('normal chat metadata persists canonical message identities', () async {
    final user = ChatMessage(
      role: 'user',
      content: 'hello',
      clientEventId: 'user-local',
      generationId: 'gen-normal',
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      clientEventId: 'assistant-local',
    );
    boundMessages = [user, reply];
    final client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/chat');
      return const FakeHttpResponseData(
        statusCode: 200,
        headers: {'x-generation-id': 'gen-normal'},
        body:
            'id: 1\n'
            'data: {"type":"part","part":{"type":"text","text":"hi"}}\n\n'
            'id: 2\n'
            'data: {"type":"metadata","user_event_id":"ev-user","assistant_event_id":"ev-assistant","epoch_id":"epoch-main","generation_id":"gen-normal"}\n\n'
            'id: 3\n'
            'data: {"type":"generation_terminal","status":"completed"}\n\n',
      );
    });

    await HttpOverrides.runZoned(
      () => ChatRuntimeController.instance.startChat(
        messages: boundMessages,
        history: [user],
        sentMessage: user,
        reply: reply,
      ),
      createHttpClient: (_) => client,
    );

    expect(user.eventId, 'ev-user');
    expect(user.epochId, 'epoch-main');
    expect(user.generationId, 'gen-normal');
    expect(reply.eventId, 'ev-assistant');
    expect(reply.epochId, 'epoch-main');
    expect(reply.generationId, 'gen-normal');

    ChatStore.cache = null;
    final reloaded = await ChatStore.load();
    expect(reloaded[0].eventId, 'ev-user');
    expect(reloaded[1].eventId, 'ev-assistant');
  });

  test(
    'cancel freezes visible prefix, discards late tail, and next send works',
    () async {
      final response = StreamController<List<int>>();
      final user = ChatMessage(
        role: 'user',
        content: 'long answer',
        clientEventId: 'user-cancel',
        generationId: 'gen-cancel',
      );
      final replyPart = ChatMessagePart(
        type: ChatMessagePartType.text,
        text: '',
        round: 1,
      );
      final reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: 'assistant-cancel',
        generationId: 'gen-cancel',
        runtimeStatus: 'running',
        parts: [replyPart],
      );
      boundMessages = [user, reply];
      ChatRuntimeController.instance.bindMessages(boundMessages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-cancel","last_seq":0,'
        '"status":"running","user_client_event_id":"user-cancel",'
        '"assistant_client_event_id":"assistant-cancel"}',
      );
      var nextGeneration = false;
      var cancelRequests = 0;
      final client = FakeHttpClient((request) {
        if (request.method == 'GET') {
          expect(request.uri.path, '/generations/gen-cancel/events');
          return FakeHttpResponseData(
            statusCode: 200,
            bodyStream: response.stream,
          );
        }
        if (request.uri.path == '/generations/gen-cancel/cancel') {
          cancelRequests += 1;
          expect(request.jsonBody['visible_content'], '已经显示');
          expect(request.jsonBody['visible_parts'], hasLength(1));
          if (cancelRequests == 1) {
            return FakeHttpResponseData.json({
              'error': 'temporary stop transport failure',
            }, statusCode: 503);
          }
          response
            ..add(
              utf8.encode(
                'id: 3\n'
                'data: {"type":"part","part":{"type":"text",'
                '"round":1,"delta":"取消后的尾部"}}\n\n',
              ),
            )
            ..add(
              utf8.encode(
                'id: 4\n'
                'data: {"type":"generation_cancelled",'
                '"generation_id":"gen-cancel","status":"cancelled"}\n\n',
              ),
            )
            ..close();
          return FakeHttpResponseData.json({
            'ok': true,
            'generation_id': 'gen-cancel',
            'status': 'cancel_requested',
          }, statusCode: 202);
        }
        if (request.uri.path == '/chat') {
          nextGeneration = true;
          return const FakeHttpResponseData(
            statusCode: 200,
            headers: {'x-generation-id': 'gen-next'},
            body:
                'id: 1\n'
                'data: {"type":"part","part":{"type":"text",'
                '"delta":"next works"}}\n\n'
                'id: 2\n'
                'data: {"type":"generation_terminal","status":"completed"}\n\n',
          );
        }
        fail('unexpected request: ${request.method} ${request.uri.path}');
      });

      await HttpOverrides.runZoned(() async {
        final resume = ChatRuntimeController.instance.resumeActiveGeneration();
        await _waitUntil(
          () => client.requests.any((request) => request.method == 'GET'),
        );
        response.add(
          utf8.encode(
            'id: 1\n'
            'data: {"type":"part","part":{"type":"text",'
            '"round":1,"delta":"已经显示，排队尾部"}}\n\n'
            'id: 2\n'
            'data: {"type":"busy","round":1}\n\n',
          ),
        );
        await _waitUntil(() => reply.content == '已经显示，排队尾部');

        final visibleParts = [
          ChatMessagePart(
            type: ChatMessagePartType.text,
            text: '已经显示',
            round: 1,
          ),
        ];
        final firstStop = ChatRuntimeController.instance.stopActiveGeneration(
          visibleContent: '已经显示',
          visibleParts: visibleParts,
        );
        final duplicateStop = ChatRuntimeController.instance
            .stopActiveGeneration(
              visibleContent: '不应覆盖首次前缀',
              visibleParts: const [],
            );
        expect(identical(firstStop, duplicateStop), isTrue);
        expect(ChatRuntimeController.instance.isStopping, isTrue);
        expect(await firstStop, CancelGenerationOutcome.failed);
        expect(cancelRequests, 1);
        expect(ChatRuntimeController.instance.isStopping, isFalse);
        expect(ChatRuntimeController.instance.isSending, isTrue);
        expect(reply.content, '已经显示');

        final outcome = await ChatRuntimeController.instance
            .stopActiveGeneration(
              visibleContent: '已经显示',
              visibleParts: visibleParts,
            );
        await resume;

        expect(outcome, CancelGenerationOutcome.cancelled);
        expect(cancelRequests, 2);
        expect(reply.content, '已经显示');
        expect(reply.parts.single.text, '已经显示');
        expect(reply.runtimeStatus, 'cancelled');
        expect(ChatRuntimeController.instance.isSending, isFalse);
        expect(await RuntimeEventClient.instance.loadCursor(), isNull);

        ChatStore.cache = null;
        final restored = await ChatStore.load();
        expect(restored.last.content, '已经显示');
        expect(restored.last.runtimeStatus, 'cancelled');

        final nextUser = ChatMessage(
          role: 'user',
          content: 'next',
          clientEventId: 'user-next',
          generationId: 'gen-next',
        );
        final nextReply = ChatMessage(
          role: 'assistant',
          content: '',
          clientEventId: 'assistant-next',
          generationId: 'gen-next',
        );
        boundMessages.addAll([nextUser, nextReply]);
        await ChatRuntimeController.instance.startChat(
          messages: boundMessages,
          history: [nextUser],
          sentMessage: nextUser,
          reply: nextReply,
        );

        expect(nextGeneration, isTrue);
        expect(nextReply.content, 'next works');
        expect(nextReply.runtimeStatus, 'completed');
        expect(ChatRuntimeController.instance.isSending, isFalse);
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'restart resumes a durable cancel request without resurrecting tail',
    () async {
      final user = ChatMessage(
        role: 'user',
        content: 'stop before restart',
        clientEventId: 'user-restart-cancel',
        generationId: 'gen-restart-cancel',
      );
      final reply = ChatMessage(
        role: 'assistant',
        content: '重启前可见',
        clientEventId: 'assistant-restart-cancel',
        generationId: 'gen-restart-cancel',
        runtimeStatus: 'cancel_requested',
        parts: [
          ChatMessagePart(
            type: ChatMessagePartType.text,
            text: '重启前可见',
            round: 1,
          ),
        ],
      );
      boundMessages = [user, reply];
      ChatRuntimeController.instance.bindMessages(boundMessages);
      await ChatStore.save(boundMessages);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-restart-cancel",'
        '"last_seq":4,"status":"running",'
        '"user_client_event_id":"user-restart-cancel",'
        '"assistant_client_event_id":"assistant-restart-cancel"}',
      );
      final client = FakeHttpClient((request) {
        if (request.method == 'POST') {
          expect(request.uri.path, '/generations/gen-restart-cancel/cancel');
          return FakeHttpResponseData.json({
            'ok': true,
            'generation_id': 'gen-restart-cancel',
            'status': 'cancel_requested',
          }, statusCode: 202);
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-restart-cancel/events');
        expect(request.uri.queryParameters['after_seq'], '4');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 5\n'
              'data: {"type":"part","part":{"type":"text",'
              '"round":1,"delta":"不应复活"}}\n\n'
              'id: 6\n'
              'data: {"type":"generation_cancelled",'
              '"generation_id":"gen-restart-cancel",'
              '"status":"cancelled"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        ChatRuntimeController.instance.resumeActiveGeneration,
        createHttpClient: (_) => client,
      );

      expect(client.requests.map((request) => request.method), ['POST', 'GET']);
      expect(reply.content, '重启前可见');
      expect(reply.parts.single.text, '重启前可见');
      expect(reply.runtimeStatus, 'cancelled');
      expect(ChatRuntimeController.instance.isSending, isFalse);
      expect(await RuntimeEventClient.instance.loadCursor(), isNull);
      ChatStore.cache = null;
      expect((await ChatStore.load()).last.content, '重启前可见');
    },
  );

  test('late stop with zero visible text removes the placeholder', () async {
    final response = StreamController<List<int>>();
    final user = ChatMessage(
      role: 'user',
      content: 'stop before text',
      clientEventId: 'user-empty-stop',
      generationId: 'gen-empty-stop',
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      clientEventId: 'assistant-empty-stop',
      generationId: 'gen-empty-stop',
      runtimeStatus: 'running',
    );
    boundMessages = [user, reply];
    ChatRuntimeController.instance.bindMessages(boundMessages);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      RuntimeEventClient.cursorPrefsKeyForTesting,
      '{"thread":"main","generation_id":"gen-empty-stop","last_seq":0,'
      '"status":"running","user_client_event_id":"user-empty-stop",'
      '"assistant_client_event_id":"assistant-empty-stop"}',
    );
    final client = FakeHttpClient((request) {
      if (request.method == 'GET') {
        return FakeHttpResponseData(
          statusCode: 200,
          bodyStream: response.stream,
        );
      }
      expect(request.jsonBody['visible_content'], isEmpty);
      expect(request.jsonBody['visible_parts'], isEmpty);
      response.close();
      return FakeHttpResponseData.json({
        'ok': true,
        'generation_id': 'gen-empty-stop',
        'status': 'completed',
        'reconciled': true,
        'removed_placeholder': true,
      });
    });

    await HttpOverrides.runZoned(() async {
      final resume = ChatRuntimeController.instance.resumeActiveGeneration();
      await _waitUntil(
        () => client.requests.any((request) => request.method == 'GET'),
      );
      final outcome = await ChatRuntimeController.instance.stopActiveGeneration(
        visibleContent: '',
        visibleParts: const [],
      );
      await resume;

      expect(outcome, CancelGenerationOutcome.reconciled);
      expect(boundMessages, [same(user)]);
      expect(ChatRuntimeController.instance.isSending, isFalse);
      ChatStore.cache = null;
      expect(await ChatStore.load(), hasLength(1));
    }, createHttpClient: (_) => client);
  });

  test(
    'canonical command attaches existing generation and reconciles branch',
    () async {
      final oldUser = ChatMessage(
        role: 'user',
        content: 'old',
        eventId: 'ev-old-user',
        clientEventId: 'client-old',
        epochId: 'epoch-main',
      );
      final oldReply = ChatMessage(
        role: 'assistant',
        content: 'old answer',
        eventId: 'ev-old-assistant',
        epochId: 'epoch-main',
      );
      final replacement = ChatMessage(
        role: 'user',
        content: 'edited',
        eventId: 'ev-new-user',
        clientEventId: 'client-new-user',
        generationId: 'gen-edit',
        epochId: 'epoch-main',
      );
      final reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: 'client-new-assistant',
        generationId: 'gen-edit',
        epochId: 'epoch-main',
      );
      boundMessages = [oldUser, oldReply];
      final activeBranch = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': 'edited',
          'event_id': 'ev-new-user',
          'client_event_id': 'client-new-user',
          'generation_id': 'gen-edit',
          'epoch_id': 'epoch-main',
        },
      ];
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-edit/events');
        expect(request.uri.queryParameters['after_seq'], '0');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"new answer"}}\n\n'
              'id: 2\n'
              'data: {"type":"metadata","user_event_id":"ev-new-user","assistant_event_id":"ev-new-assistant","epoch_id":"epoch-main","generation_id":"gen-edit"}\n\n'
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.attachCommandGeneration(
          messages: boundMessages,
          userMessage: replacement,
          reply: reply,
          generationId: 'gen-edit',
          epochId: 'epoch-main',
          activeBranch: activeBranch,
        ),
        createHttpClient: (_) => client,
      );

      expect(client.requests, hasLength(1));
      expect(client.requests.single.method, 'GET');
      expect(boundMessages, hasLength(2));
      expect(boundMessages[0], same(replacement));
      expect(boundMessages[0].eventId, 'ev-new-user');
      expect(boundMessages[1].content, 'new answer');
      expect(boundMessages[1].eventId, 'ev-new-assistant');
      expect(boundMessages[1].generationId, 'gen-edit');

      ChatStore.cache = null;
      final reloaded = await ChatStore.load();
      expect(reloaded[0].eventId, 'ev-new-user');
      expect(reloaded[1].eventId, 'ev-new-assistant');
      expect(reloaded[1].runtimeStatus, 'completed');
    },
  );

  test(
    'branch reconcile adopts legacy attachment messages without losing local cards',
    () async {
      final legacyImage = ChatMessage(
        role: 'user',
        content: '看这个',
        imageUrl: 'https://example.test/cat.jpg',
        ocrText: '猫猫',
      );
      final legacyReply = ChatMessage(role: 'assistant', content: '看到了');
      final currentUser = ChatMessage(
        role: 'user',
        content: '再说说',
        eventId: 'ev-current-user',
        clientEventId: 'client-current',
        generationId: 'gen-current',
        epochId: 'epoch-main',
      );
      final reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: 'client-new-assistant',
        generationId: 'gen-current',
        epochId: 'epoch-main',
      );
      boundMessages = [legacyImage, legacyReply, currentUser];
      final activeBranch = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': ChatApi.runtimeMutationContent(legacyImage),
          'event_id': 'ev-legacy-image',
          'epoch_id': 'epoch-main',
        },
        {
          'role': 'assistant',
          'content': '看到了',
          'event_id': 'ev-legacy-reply',
          'epoch_id': 'epoch-main',
        },
        {
          'role': 'user',
          'content': '再说说',
          'event_id': 'ev-current-user',
          'client_event_id': 'client-current',
          'generation_id': 'gen-current',
          'epoch_id': 'epoch-main',
        },
      ];
      final client = FakeHttpClient((request) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/gen-current/events');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"metadata","user_event_id":"ev-current-user","assistant_event_id":"ev-new-assistant","epoch_id":"epoch-main","generation_id":"gen-current"}\n\n'
              'id: 2\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.attachCommandGeneration(
          messages: boundMessages,
          userMessage: currentUser,
          reply: reply,
          generationId: 'gen-current',
          epochId: 'epoch-main',
          activeBranch: activeBranch,
        ),
        createHttpClient: (_) => client,
      );

      expect(boundMessages[0], same(legacyImage));
      expect(boundMessages[0].eventId, 'ev-legacy-image');
      expect(boundMessages[0].imageUrl, 'https://example.test/cat.jpg');
      expect(boundMessages[0].ocrText, '猫猫');
      expect(boundMessages[1], same(legacyReply));
      expect(boundMessages[1].eventId, 'ev-legacy-reply');
      expect(boundMessages[2], same(currentUser));
      expect(boundMessages[3].eventId, 'ev-new-assistant');
    },
  );
  test(
    'stream device generation mismatch fails closed before phone action',
    () async {
      var deviceCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nudgeChannel, (call) async {
            deviceCalls += 1;
            return '{"success":true}';
          });
      final user = ChatMessage(
        role: 'user',
        content: 'check',
        clientEventId: 'user-scope',
        generationId: 'gen-scope-a',
      );
      final reply = ChatMessage(
        role: 'assistant',
        content: '',
        clientEventId: 'assistant-scope',
      );
      boundMessages = [user, reply];
      final client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/chat');
        return const FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-scope-a'},
          body:
              'id: 1\n'
              'data: {"type":"nudge_pending","generation_id":"gen-scope-b","round":1,"calls":[{"tool_call_id":"call-scope","tool":"device_status","arguments":{}}]}\n\n',
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startChat(
          messages: boundMessages,
          history: [user],
          sentMessage: user,
          reply: reply,
        ),
        createHttpClient: (_) => client,
      );

      expect(deviceCalls, 0);
      expect(user.sendFailed, isTrue);
      expect(user.sendError, contains('device_tool_identity_invalid'));
      expect(client.requests, hasLength(1));
    },
  );
}
