import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_runtime_controller.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/services/runtime_event_client.dart';
import 'package:continuum_chat/services/server_config.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_http.dart';
import 'support/fake_path_provider.dart';

Future<void> _waitForRuntimeIdle() async {
  for (var i = 0; i < 100; i++) {
    if (!ChatRuntimeController.instance.isSending) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('runtime did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;
  late List<ChatMessage> messages;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('continuum_command_flow_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    await RuntimeEventClient.instance.clearCursor();
    await RuntimeEventClient.instance.clearPendingCommand();
    ChatStore.cache = null;
    messages = <ChatMessage>[];
  });

  tearDown(() async {
    ChatRuntimeController.instance.unbindMessages(messages);
    await RuntimeEventClient.instance.clearCursor();
    ChatStore.cache = null;
    PathProviderPlatform.instance = previousPathProvider;
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Runtime cleanup may remove the temp directory between exists() and delete().
    }
  });

  test(
    'canonical edit command starts and replays one generation without /chat',
    () async {
      final target = ChatMessage(
        role: 'user',
        content: 'old caption',
        eventId: 'ev-user-old',
        clientEventId: 'client-old',
        epochId: 'epoch-main',
        imageUrl: 'https://img.example/a.jpg',
        ocrText: 'image words',
      );
      final oldReply = ChatMessage(
        role: 'assistant',
        content: 'old answer',
        eventId: 'ev-assistant-old',
        epochId: 'epoch-main',
      );
      messages = [target, oldReply];
      late String generationId;
      final client = FakeHttpClient((request) {
        expect(request.uri.path, isNot('/chat'));
        if (request.method == 'POST') {
          expect(request.uri.path, '/runtime/events/ev-user-old/edit');
          generationId = request.jsonBody['generation_id'].toString();
          expect(
            request.jsonBody['client_event_id'].toString(),
            startsWith('user-'),
          );
          expect(request.jsonBody['content'], contains('new caption'));
          expect(
            request.jsonBody['content'],
            contains('https://img.example/a.jpg'),
          );
          return FakeHttpResponseData.json({
            'ok': true,
            'generation_id': generationId,
            'status': 'running',
            'user_event_id': 'ev-user-new',
            'epoch_id': 'epoch-main',
            'event': {'event_id': 'ev-user-new'},
            'active_branch': [
              {
                'role': 'user',
                'content': 'expanded server content',
                'event_id': 'ev-user-new',
                'client_event_id': request.jsonBody['client_event_id'],
                'generation_id': generationId,
                'epoch_id': 'epoch-main',
              },
            ],
          });
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/$generationId/events');
        return FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"new answer"}}\n\n'
              'id: 2\n'
              'data: {"type":"metadata","user_event_id":"ev-user-new","assistant_event_id":"ev-assistant-new","epoch_id":"epoch-main","generation_id":"$generationId"}\n\n'
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      final error = await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startCanonicalEdit(
          messages: messages,
          target: target,
          editedText: 'new caption',
        ),
        createHttpClient: (_) => client,
      );
      expect(error, isNull);
      await _waitForRuntimeIdle();

      expect(client.requests.map((r) => r.method), ['POST', 'GET']);
      expect(messages, hasLength(2));
      expect(messages[0].content, 'new caption');
      expect(messages[0].eventId, 'ev-user-new');
      expect(messages[0].imageUrl, 'https://img.example/a.jpg');
      expect(messages[0].ocrText, 'image words');
      expect(messages[1].content, 'new answer');
      expect(messages[1].eventId, 'ev-assistant-new');
      expect(messages[1].generationId, generationId);
    },
  );

  test('failed canonical edit leaves the local branch unchanged', () async {
    final target = ChatMessage(
      role: 'user',
      content: 'keep me',
      eventId: 'ev-user',
      clientEventId: 'client-user',
      epochId: 'epoch-main',
    );
    final oldReply = ChatMessage(role: 'assistant', content: 'keep reply');
    messages = [target, oldReply];
    final before = List<ChatMessage>.of(messages);
    final client = FakeHttpClient((request) {
      expect(request.method, 'POST');
      expect(request.uri.path, '/runtime/events/ev-user/edit');
      return FakeHttpResponseData.json({'error': 'precheck'}, statusCode: 502);
    });

    final error = await HttpOverrides.runZoned(
      () => ChatRuntimeController.instance.startCanonicalEdit(
        messages: messages,
        target: target,
        editedText: 'do not apply',
      ),
      createHttpClient: (_) => client,
    );

    expect(error, isNotNull);
    expect(messages, orderedEquals(before));
    expect(messages[0], same(target));
    expect(messages[1], same(oldReply));
    expect(ChatRuntimeController.instance.isSending, isFalse);
    expect(client.requests, hasLength(1));
  });

  test(
    'durable active cursor blocks canonical mutation before server branch changes',
    () async {
      final target = ChatMessage(
        role: 'user',
        content: 'do not mutate',
        eventId: 'ev-blocked',
        clientEventId: 'client-blocked',
        epochId: 'epoch-main',
      );
      messages = [target];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        RuntimeEventClient.cursorPrefsKeyForTesting,
        '{"thread":"main","generation_id":"gen-existing",'
        '"last_seq":2,"status":"running"}',
      );
      final client = FakeHttpClient((request) {
        fail(
          'canonical command must not reach server while a generation is active',
        );
      });

      final error = await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startCanonicalEdit(
          messages: messages,
          target: target,
          editedText: 'changed',
        ),
        createHttpClient: (_) => client,
      );

      expect(error, contains('仍在服务器运行'));
      expect(client.requests, isEmpty);
      expect(messages.single, same(target));
      expect(ChatRuntimeController.instance.isSending, isFalse);
    },
  );

  test(
    'canonical regenerate reuses the original user event and never POSTs chat',
    () async {
      final user = ChatMessage(
        role: 'user',
        content: 'question',
        eventId: 'ev-question',
        clientEventId: 'client-question',
        generationId: 'gen-old',
        epochId: 'epoch-main',
      );
      final oldReply = ChatMessage(
        role: 'assistant',
        content: 'old answer',
        eventId: 'ev-old-answer',
        generationId: 'gen-old',
        epochId: 'epoch-main',
      );
      messages = [user, oldReply];
      late String generationId;
      final client = FakeHttpClient((request) {
        expect(request.uri.path, isNot('/chat'));
        if (request.method == 'POST') {
          expect(request.uri.path, '/runtime/events/ev-question/regenerate');
          generationId = request.jsonBody['generation_id'].toString();
          return FakeHttpResponseData.json({
            'ok': true,
            'generation_id': generationId,
            'status': 'running',
            'user_event_id': 'ev-question',
            'epoch_id': 'epoch-main',
          });
        }
        expect(request.method, 'GET');
        expect(request.uri.path, '/generations/$generationId/events');
        return FakeHttpResponseData(
          statusCode: 200,
          body:
              'id: 1\n'
              'data: {"type":"part","part":{"type":"text","text":"new answer"}}\n\n'
              'id: 2\n'
              'data: {"type":"metadata","user_event_id":"ev-question","assistant_event_id":"ev-new-answer","epoch_id":"epoch-main","generation_id":"$generationId"}\n\n'
              'id: 3\n'
              'data: {"type":"generation_terminal","status":"completed"}\n\n',
        );
      });

      final error = await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startCanonicalRegenerate(
          messages: messages,
          userMessage: user,
        ),
        createHttpClient: (_) => client,
      );
      expect(error, isNull);
      await _waitForRuntimeIdle();

      expect(client.requests.map((r) => r.method), ['POST', 'GET']);
      expect(messages.where((m) => m.role == 'user'), hasLength(1));
      expect(messages.first, same(user));
      expect(messages.first.eventId, 'ev-question');
      expect(messages.first.generationId, generationId);
      expect(messages.last.role, 'assistant');
      expect(messages.last.eventId, 'ev-new-answer');
      expect(messages.last.content, 'new answer');
    },
  );
}
