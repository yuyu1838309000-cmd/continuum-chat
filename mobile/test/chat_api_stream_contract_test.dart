import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_api.dart';
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
    'chat stream only completes after DONE and delivers metadata ids',
    () async {
      final client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/chat');
        return const FakeHttpResponseData(
          statusCode: 200,
          body:
              'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n'
              'data: {"type":"metadata","user_raw_event_id":11,'
              '"assistant_raw_event_id":12}\n\n'
              'data: [DONE]\n\n',
        );
      });
      final deltas = <String>[];
      var done = 0;
      final errors = <String>[];
      int? userId;
      int? assistantId;

      await HttpOverrides.runZoned(
        () => ChatApi.send(
          [ChatMessage(role: 'user', content: '嗨')],
          onDelta: deltas.add,
          onDone: () => done += 1,
          onError: errors.add,
          onRawEventIds: (u, a) {
            userId = u;
            assistantId = a;
          },
        ),
        createHttpClient: (_) => client,
      );

      expect(deltas, ['你好']);
      expect(done, 1);
      expect(errors, isEmpty);
      expect(userId, 11);
      expect(assistantId, 12);
    },
  );

  test('EOF without DONE is stream_incomplete and never normal done', () async {
    final client = FakeHttpClient(
      (_) => const FakeHttpResponseData(
        statusCode: 200,
        body: 'data: {"choices":[{"delta":{"content":"半句"}}]}\n\n',
      ),
    );
    var done = 0;
    final chatErrors = <String>[];
    final fallbackErrors = <String>[];

    await HttpOverrides.runZoned(
      () => ChatApi.send(
        [ChatMessage(role: 'user', content: '继续')],
        onDelta: (_) {},
        onChatError: (code, _) => chatErrors.add(code),
        onDone: () => done += 1,
        onError: fallbackErrors.add,
      ),
      createHttpClient: (_) => client,
    );

    expect(done, 0);
    expect(chatErrors, ['stream_incomplete']);
    expect(fallbackErrors, isEmpty);
  });

  test('parts mode suppresses legacy content after structured part', () async {
    final client = FakeHttpClient(
      (_) => const FakeHttpResponseData(
        statusCode: 200,
        body:
            'data: {"type":"part","part":{"type":"text",'
            '"text":"结构化正文","round":1}}\n\n'
            'data: {"choices":[{"delta":{"content":"重复正文"}}]}\n\n'
            'data: [DONE]\n\n',
      ),
    );

    final parts = <ChatMessagePart>[];
    final deltas = <String>[];
    await HttpOverrides.runZoned(
      () => ChatApi.send(
        [ChatMessage(role: 'user', content: '测试 parts')],
        onPart: parts.add,
        onDelta: deltas.add,
        onDone: () {},
        onError: fail,
      ),
      createHttpClient: (_) => client,
    );

    expect(parts, hasLength(1));
    expect(parts.single.type, ChatMessagePartType.text);
    expect(parts.single.text, '结构化正文');
    expect(deltas, isEmpty);
  });
}
