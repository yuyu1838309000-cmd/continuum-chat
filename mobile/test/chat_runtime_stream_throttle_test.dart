import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
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

// 本文件专门守“高频流式不再每个 delta 落盘/通知”的性能契约。
// save 次数统计来自 ChatStore.saveCallCount（真实存储层调用次数）。

String _partFrame(int seq, String type, String delta) {
  final payload = jsonEncode({
    'type': 'part',
    'part': {'type': type, 'delta': delta, 'round': 1},
  });
  return 'id: $seq\ndata: $payload\n\n';
}

const String _terminalFrame =
    'id: 900000\n'
    'data: {"type":"generation_terminal","status":"completed"}\n\n';

Future<void> _waitUntil(bool Function() predicate, [String what = '']) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition did not become true: $what');
}

// ChatStore.load() 不与写链互斥，写盘进行中可能读到旧文件；这里轮询到
// 目标内容真正落在文件里为止，避免把“写还没完成”误判成“内容丢了”。
Future<List<ChatMessage>> _loadUntil(
  bool Function(List<ChatMessage> messages) ready,
  String what,
) async {
  List<ChatMessage> loaded = const [];
  for (var attempt = 0; attempt < 200; attempt++) {
    ChatStore.cache = null;
    loaded = await ChatStore.load();
    if (ready(loaded)) return loaded;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'condition did not become true: $what (last=${loaded.length}, reasoning=${loaded.isEmpty ? '<none>' : loaded.last.reasoning})',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;
  late List<ChatMessage> boundMessages;

  ({ChatMessage user, ChatMessage reply}) seedMessages(String generationId) {
    final user = ChatMessage(
      role: 'user',
      content: '长窗口提问',
      clientEventId: '$generationId-user',
      generationId: generationId,
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '',
      clientEventId: '$generationId-assistant',
      generationId: generationId,
      runtimeStatus: 'running',
    );
    boundMessages = [user, reply];
    ChatRuntimeController.instance.bindMessages(boundMessages);
    return (user: user, reply: reply);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('continuum_stream_throttle_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    await ServerConfig.instance.setHost('127.0.0.1');
    await RuntimeEventClient.instance.clearCursor();
    await RuntimeEventClient.instance.clearPendingCommand();
    ChatStore.cache = null;
    ChatStore.saveCallCount = 0;
    boundMessages = <ChatMessage>[];
  });

  tearDown(() async {
    await ChatRuntimeController.instance.flushPendingStreamingWork();
    ChatRuntimeController.instance.unbindMessages(boundMessages);
    await RuntimeEventClient.instance.clearCursor();
    ChatStore.cache = null;
    ChatStore.saveCallCount = 0;
    PathProviderPlatform.instance = previousPathProvider;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('reasoning UI batches more aggressively than normal text', () {
    expect(
      ChatRuntimeController.reasoningUiCoalesceWindow,
      greaterThan(ChatRuntimeController.streamUiCoalesceWindow),
    );
    expect(
      ChatRuntimeController.reasoningUiCoalesceWindow.inMilliseconds,
      lessThanOrEqualTo(100),
    );
  });

  test(
    'burst reasoning deltas stay complete while save/notify stay bounded',
    () async {
      const deltaCount = 200;
      final seeded = seedMessages('gen-throttle');
      final expectedReasoning = [
        for (var index = 0; index < deltaCount; index++) 'r$index,',
      ].join();
      final body = StringBuffer();
      for (var index = 0; index < deltaCount; index++) {
        body.write(_partFrame(index + 1, 'reasoning', 'r$index,'));
      }
      body
        ..write(_partFrame(deltaCount + 1, 'text', '正文'))
        ..write(_terminalFrame);

      final client = FakeHttpClient((request) {
        expect(request.method, 'POST');
        expect(request.uri.path, '/chat');
        return FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-throttle'},
          body: body.toString(),
        );
      });

      var notifyCount = 0;
      void listener() => notifyCount += 1;
      ChatRuntimeController.instance.addListener(listener);
      try {
        await HttpOverrides.runZoned(
          () => ChatRuntimeController.instance.startChat(
            messages: boundMessages,
            history: [seeded.user],
            sentMessage: seeded.user,
            reply: seeded.reply,
          ),
          createHttpClient: (_) => client,
        );
      } finally {
        ChatRuntimeController.instance.removeListener(listener);
      }

      // 1. 内存 canonical message 逐字完整、顺序不变。
      expect(seeded.reply.reasoning, expectedReasoning);
      expect(seeded.reply.content, '正文');
      expect(seeded.reply.parts.map((part) => part.type).toList(), [
        ChatMessagePartType.reasoning,
        ChatMessagePartType.text,
      ]);
      expect(seeded.reply.parts.first.text, expectedReasoning);
      expect(ChatRuntimeController.instance.isSending, isFalse);

      // 2./3. $deltaCount 个 delta 只换来个位数 save/notify。
      expect(ChatStore.saveCallCount, lessThanOrEqualTo(3));
      expect(notifyCount, lessThanOrEqualTo(6));

      // 4. terminal 立即落盘，不等 checkpoint timer。
      ChatStore.cache = null;
      final restored = await ChatStore.load();
      expect(restored.last.reasoning, expectedReasoning);
      expect(restored.last.content, '正文');
      expect(restored.last.runtimeStatus, 'completed');
    },
  );

  test(
    'long stream checkpoints to disk before the generation terminal',
    () async {
      final seeded = seedMessages('gen-checkpoint');
      final response = StreamController<List<int>>();
      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/chat');
        return FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-checkpoint'},
          bodyStream: response.stream,
        );
      });

      await HttpOverrides.runZoned(() async {
        final started = ChatRuntimeController.instance.startChat(
          messages: boundMessages,
          history: [seeded.user],
          sentMessage: seeded.user,
          reply: seeded.reply,
        );
        // RuntimeSseParser 在下一个 `id:` 帧头到达时才交出上一帧（这是既有
        // 解析契约），所以这里按真实节奏再补一帧，让第一帧进入内存。
        response
          ..add(utf8.encode(_partFrame(1, 'reasoning', '想一半')))
          ..add(utf8.encode(_partFrame(2, 'reasoning', '还有一半')));
        await _waitUntil(
          () => seeded.reply.reasoning == '想一半',
          'reasoning-mid',
        );

        // 流式仍在进行：checkpoint 必须在终态之前把增量写进文件。
        await _waitUntil(() => ChatStore.saveCallCount >= 2, 'checkpoint-save');
        final midStream = await _loadUntil(
          (messages) => messages.isNotEmpty && messages.last.reasoning == '想一半',
          'checkpoint-on-disk',
        );
        expect(midStream.last.reasoning, '想一半');
        expect(ChatRuntimeController.instance.isSending, isTrue);

        response
          ..add(utf8.encode(_partFrame(3, 'text', '正文')))
          ..add(utf8.encode(_terminalFrame));
        await _waitUntil(() => seeded.reply.content == '正文', 'text-mid');
        await response.close();
        await started;
      }, createHttpClient: (_) => client);

      ChatStore.cache = null;
      final restored = await ChatStore.load();
      expect(restored.last.reasoning, '想一半还有一半');
      expect(restored.last.content, '正文');
      expect(restored.last.runtimeStatus, 'completed');
    },
  );

  test(
    'pausing the app flushes stream content that is not checkpointed yet',
    () async {
      final seeded = seedMessages('gen-pause');
      final response = StreamController<List<int>>();
      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/chat');
        return FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-pause'},
          bodyStream: response.stream,
        );
      });

      await HttpOverrides.runZoned(() async {
        final started = ChatRuntimeController.instance.startChat(
          messages: boundMessages,
          history: [seeded.user],
          sentMessage: seeded.user,
          reply: seeded.reply,
        );
        // 同上的帧边界：第二帧让第一帧先进入内存，随后立刻切后台。
        response
          ..add(utf8.encode(_partFrame(1, 'reasoning', '切后台前')))
          ..add(utf8.encode(_partFrame(2, 'reasoning', '切后台后')));
        await _waitUntil(
          () => seeded.reply.reasoning == '切后台前',
          'reasoning-pause',
        );

        // checkpoint 定时器被生命周期 flush 取消：只允许出现起始保存 + 本次 flush。
        ChatRuntimeController.instance.didChangeAppLifecycleState(
          AppLifecycleState.paused,
        );
        // Await the lifecycle-triggered flush itself, not only the save-call counter.
        await ChatRuntimeController.instance.flushPendingStreamingWork();
        expect(ChatStore.saveCallCount, greaterThanOrEqualTo(2));
        final flushed = await _loadUntil(
          (messages) =>
              messages.isNotEmpty && messages.last.reasoning.startsWith('切后台前'),
          'pause-flush-on-disk',
        );
        expect(flushed.last.reasoning, startsWith('切后台前'));
        expect(ChatRuntimeController.instance.isSending, isTrue);

        response.add(utf8.encode(_terminalFrame));
        await response.close();
        await started;
      }, createHttpClient: (_) => client);
    },
  );

  test(
    'chat_error cancels pending timers, fails the bubble, keeps prefix',
    () async {
      final seeded = seedMessages('gen-error');
      final body = StringBuffer()
        ..write(_partFrame(1, 'text', '已经显示'))
        ..write(
          'id: 2\n'
          'data: {"type":"chat_error","code":"stream_incomplete",'
          '"message":"回复中断，请稍后重试"}\n\n',
        );
      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/chat');
        return FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-error'},
          body: body.toString(),
        );
      });

      await HttpOverrides.runZoned(
        () => ChatRuntimeController.instance.startChat(
          messages: boundMessages,
          history: [seeded.user],
          sentMessage: seeded.user,
          reply: seeded.reply,
        ),
        createHttpClient: (_) => client,
      );

      expect(seeded.reply.content, '已经显示');
      expect(seeded.reply.runtimeStatus, 'failed');
      expect(ChatRuntimeController.instance.isSending, isFalse);
      final savesAfterFailure = ChatStore.saveCallCount;
      expect(savesAfterFailure, lessThanOrEqualTo(3));

      // 终态后不再有迟到的 timer 写盘。
      await Future<void>.delayed(
        ChatRuntimeController.streamCheckpointInterval * 2,
      );
      expect(ChatStore.saveCallCount, savesAfterFailure);

      ChatStore.cache = null;
      final restored = await ChatStore.load();
      expect(restored.last.content, '已经显示');
      expect(restored.last.runtimeStatus, 'failed');
    },
  );

  test('no_response replaces the bubble and flushes without waiting', () async {
    final seeded = seedMessages('gen-empty');
    final body = StringBuffer()
      ..write(_partFrame(1, 'reasoning', '想了想'))
      ..write(
        'id: 2\n'
        'data: {"type":"no_response","content":"无回应"}\n\n',
      )
      ..write(_terminalFrame);
    final client = FakeHttpClient(
      (_) => FakeHttpResponseData(
        statusCode: 200,
        headers: {'x-generation-id': 'gen-empty'},
        body: body.toString(),
      ),
    );

    await HttpOverrides.runZoned(
      () => ChatRuntimeController.instance.startChat(
        messages: boundMessages,
        history: [seeded.user],
        sentMessage: seeded.user,
        reply: seeded.reply,
      ),
      createHttpClient: (_) => client,
    );

    // 气泡换成 no_response 卡片，交互状态立即回正。
    expect(boundMessages.last.kind, 'no_response');
    expect(boundMessages.last.clientEventId, 'gen-empty-assistant');
    expect(ChatRuntimeController.instance.isSending, isFalse);
    final saves = ChatStore.saveCallCount;
    expect(saves, lessThanOrEqualTo(3));

    // no_response 之后不允许再有迟到的流式 timer 写盘。
    await Future<void>.delayed(
      ChatRuntimeController.streamCheckpointInterval * 2,
    );
    expect(ChatStore.saveCallCount, saves);

    ChatStore.cache = null;
    final restored = await ChatStore.load();
    expect(restored.last.kind, 'no_response');
    expect(restored.last.content, '无回应');
  });

  test(
    'long window (1200 deltas) keeps disk and notify work bounded',
    () async {
      const reasoningDeltas = 1199;
      final seeded = seedMessages('gen-window');
      final body = StringBuffer();
      for (var index = 0; index < reasoningDeltas; index++) {
        body.write(_partFrame(index + 1, 'reasoning', 'x'));
      }
      // 纯 reasoning 且无正文的 completed 轮次会被既有契约替换成“无回应”，
      // 这里按真实轮次补一个正文增量。
      body
        ..write(_partFrame(reasoningDeltas + 1, 'text', '正文'))
        ..write(_terminalFrame);

      final client = FakeHttpClient((request) {
        expect(request.uri.path, '/chat');
        return FakeHttpResponseData(
          statusCode: 200,
          headers: {'x-generation-id': 'gen-window'},
          body: body.toString(),
        );
      });

      var notifyCount = 0;
      void listener() => notifyCount += 1;
      ChatRuntimeController.instance.addListener(listener);
      try {
        await HttpOverrides.runZoned(
          () => ChatRuntimeController.instance.startChat(
            messages: boundMessages,
            history: [seeded.user],
            sentMessage: seeded.user,
            reply: seeded.reply,
          ),
          createHttpClient: (_) => client,
        );
      } finally {
        ChatRuntimeController.instance.removeListener(listener);
      }

      expect(seeded.reply.reasoning.length, reasoningDeltas);
      expect(seeded.reply.content, '正文');
      expect(ChatStore.saveCallCount, lessThanOrEqualTo(4));
      expect(notifyCount, lessThanOrEqualTo(12));

      ChatStore.cache = null;
      final restored = await ChatStore.load();
      expect(restored.last.reasoning.length, reasoningDeltas);
      expect(restored.last.content, '正文');
      expect(restored.last.runtimeStatus, 'completed');
    },
  );
}
