import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('continuum_metadata_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    ChatStore.cache = null;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    ChatStore.cache = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('old JSON without runtime metadata remains readable', () async {
    await File('${temp.path}/chat.json').writeAsString(
      '[{"role":"user","content":"旧消息","time":"2026-08-31T00:00:00.000"}]',
    );

    final loaded = await ChatStore.load();

    expect(loaded, hasLength(1));
    expect(loaded.single.content, '旧消息');
    expect(loaded.single.eventId, isNull);
    expect(loaded.single.generationId, isNull);
  });

  test('save and load preserves runtime metadata', () async {
    await ChatStore.save([
      ChatMessage(
        role: 'assistant',
        content: 'ok',
        eventId: 'evt-1',
        clientEventId: 'client-1',
        generationId: 'gen-1',
        epochId: 'epoch-1',
        kind: 'assistant',
        runtimeSeq: 3,
        runtimeStatus: 'completed',
      ),
    ]);

    final loaded = await ChatStore.load();

    expect(loaded.single.eventId, 'evt-1');
    expect(loaded.single.clientEventId, 'client-1');
    expect(loaded.single.generationId, 'gen-1');
    expect(loaded.single.epochId, 'epoch-1');
    expect(loaded.single.runtimeSeq, 3);
    expect(loaded.single.runtimeStatus, 'completed');
  });
}
