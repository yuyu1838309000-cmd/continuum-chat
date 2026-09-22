import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/archived_chat.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/chat_store.dart';
import 'package:continuum_chat/services/history_migration_api.dart';
import 'package:continuum_chat/services/history_migration_repository.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_path_provider.dart';

class _FakeHistoryMigrationApi extends HistoryMigrationApi {
  var capabilityCalls = 0;
  var previewCalls = 0;
  var importCalls = 0;
  var statusCalls = 0;
  Object? capabilityError;
  Object? previewError;
  final List<Object> importOutcomes = [];
  Map<String, dynamic>? remoteStatus;
  Map<String, dynamic>? lastSnapshot;

  @override
  Future<Map<String, dynamic>> requireCapability() async {
    capabilityCalls++;
    if (capabilityError case final error?) throw error;
    return {'version': 1, 'preview': true, 'import': true, 'status': true};
  }

  @override
  Future<Map<String, dynamic>> preview(Map<String, dynamic> snapshot) async {
    previewCalls++;
    lastSnapshot = snapshot;
    if (previewError case final error?) throw error;
    final windows = snapshot['windows'] as List<dynamic>;
    final messages = windows.fold<int>(
      0,
      (sum, window) =>
          sum + ((window as Map<String, dynamic>)['messages'] as List).length,
    );
    return {
      'ok': true,
      'can_import': true,
      'snapshot_hash': snapshot['snapshot_hash'],
      'window_count': windows.length,
      'archive_window_count': windows.length - 1,
      'active_window_count': 1,
      'message_count': messages,
      'reused_event_count': 0,
      'new_event_count': messages,
      'conflict_count': 0,
      'anomaly_count': 0,
      'warning_count': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> importSnapshot(
    Map<String, dynamic> snapshot,
  ) async {
    importCalls++;
    lastSnapshot = snapshot;
    if (importOutcomes.isNotEmpty) {
      final outcome = importOutcomes.removeAt(0);
      if (outcome is Exception) throw outcome;
      return (outcome as Map).map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return {
      'ok': true,
      'status': 'complete',
      'snapshot_id': snapshot['snapshot_id'],
      'snapshot_hash': snapshot['snapshot_hash'],
    };
  }

  @override
  Future<Map<String, dynamic>?> status(String snapshotId) async {
    statusCalls++;
    return remoteStatus;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late PathProviderPlatform previousPathProvider;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'continuum_history_migration_',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp.path);
    SharedPreferences.setMockInitialValues({});
    ChatStore.cache = null;
  });

  tearDown(() async {
    ChatStore.cache = null;
    PathProviderPlatform.instance = previousPathProvider;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> seedFixtureHistory() async {
    final archive = ArchivedChat(
      id: 'archive-1000',
      archivedAt: DateTime(2026, 8, 1, 9),
      title: '旧窗口',
      messages: [
        ChatMessage(
          role: 'user',
          content: '旧问题',
          time: DateTime(2026, 8, 1, 8),
          rawEventId: 501,
        ),
        ChatMessage(
          role: 'assistant',
          content: '旧回答',
          time: DateTime(2026, 8, 1, 8, 1),
          rawEventId: 502,
        ),
      ],
    );
    await ChatStore.saveArchives([archive]);
    await ChatStore.save([
      ChatMessage(
        role: 'user',
        content: '现在',
        time: DateTime(2026, 8, 30, 8),
        rawEventId: 503,
        imageUrl: 'https://img.example/current.jpg',
        ocrText: '图片文字',
        parts: [
          ChatMessagePart(type: ChatMessagePartType.text, text: '现在'),
          ChatMessagePart(
            type: ChatMessagePartType.image,
            url: 'https://img.example/current.jpg',
          ),
        ],
      ),
      ChatMessage(
        role: 'assistant',
        content: '收到',
        time: DateTime(2026, 8, 30, 8, 1),
        reasoning: '内部思考',
      ),
    ]);
  }

  test('stable snapshot matches the shared cross-stack fixture', () async {
    await seedFixtureHistory();
    final repository = HistoryMigrationRepository(
      api: _FakeHistoryMigrationApi(),
    );

    final first = await repository.createOrLoadSnapshot();
    final second = await HistoryMigrationRepository(
      api: _FakeHistoryMigrationApi(),
    ).createOrLoadSnapshot();
    final fixture = jsonDecode(
      await File('test/fixtures/legacy_chat_migration_v1.json').readAsString(),
    );

    expect(second, first);
    expect(first, fixture);
    expect(first['snapshot_id'], 'legacy-chat-v1-${first['snapshot_hash']}');
  });

  test('archive folder metadata is preserved in the frozen snapshot', () async {
    final archive = ArchivedChat(
      id: 'archive-foldered',
      archivedAt: DateTime(2026, 8, 1, 9),
      title: '有分类的窗口',
      folderId: 'folder-work',
      folderName: '工作',
      messages: [
        ChatMessage(
          role: 'user',
          content: '分类消息',
          time: DateTime(2026, 8, 1, 8),
        ),
      ],
    );
    await ChatStore.saveArchives([archive]);
    await ChatStore.save(const []);

    final snapshot = await const HistoryMigrationRepository()
        .createOrLoadSnapshot();
    final windows = snapshot['windows'] as List<dynamic>;
    final metadata = (windows.first as Map<String, dynamic>)['legacy_metadata'];

    expect(metadata, {'folderId': 'folder-work', 'folderName': '工作'});
  });

  test('preview is non-destructive and persists readable state', () async {
    await seedFixtureHistory();
    final chatBefore = await File('${temp.path}/chat.json').readAsString();
    final archivesBefore = await File(
      '${temp.path}/archives.json',
    ).readAsString();
    final api = _FakeHistoryMigrationApi();
    final repository = HistoryMigrationRepository(api: api);

    final preview = await repository.preview();
    final state = await repository.loadState();

    expect(preview['can_import'], isTrue);
    expect(api.previewCalls, 1);
    expect(state?['status'], 'previewed');
    expect(state?['source_retained'], isTrue);
    expect(await File('${temp.path}/chat.json').readAsString(), chatBefore);
    expect(
      await File('${temp.path}/archives.json').readAsString(),
      archivesBefore,
    );
  });

  test(
    'migration snapshot and current writes share one consistency lock',
    () async {
      await seedFixtureHistory();

      final frozenFuture = ChatStore.loadMigrationSourceSnapshot();
      final laterSave = ChatStore.save([
        ChatMessage(
          role: 'user',
          content: '快照之后的新消息',
          time: DateTime(2026, 8, 31, 9),
        ),
      ]);
      final frozen = await frozenFuture;
      await laterSave;

      expect(frozen.current.map((message) => message.content), ['现在', '收到']);
      expect((await ChatStore.load()).single.content, '快照之后的新消息');
    },
  );

  test(
    'archive plus current clear is atomic for migration snapshots',
    () async {
      await seedFixtureHistory();
      final current = await ChatStore.load();

      final archives = await ChatStore.archiveMessagesAndClearCurrent(current);
      final frozen = await ChatStore.loadMigrationSourceSnapshot();

      expect(archives, hasLength(2));
      expect(frozen.archives, hasLength(2));
      expect(frozen.current, isEmpty);
      expect(frozen.archives.first.id, 'archive-1000');
      expect(frozen.archives.last.messages.map((message) => message.content), [
        '现在',
        '收到',
      ]);
    },
  );

  test(
    'restart journal finishes an archive committed before current clear',
    () async {
      await seedFixtureHistory();
      final archivesFile = File('${temp.path}/archives.json');
      final rawArchives = jsonDecode(await archivesFile.readAsString()) as List;
      final interruptedArchive = ArchivedChat(
        id: 'archive-interrupted',
        archivedAt: DateTime(2026, 8, 31, 10),
        title: '中断归档',
        messages: await ChatStore.load(),
      );
      rawArchives.add(interruptedArchive.toJson());
      await archivesFile.writeAsString(jsonEncode(rawArchives), flush: true);
      await File('${temp.path}/chat_archive_transition_v1.json').writeAsString(
        jsonEncode({
          'archiveId': interruptedArchive.id,
          'archive': interruptedArchive.toJson(),
        }),
        flush: true,
      );

      final recoveredCurrent = await ChatStore.load();
      final recoveredArchives = await ChatStore.loadArchives();

      expect(recoveredCurrent, isEmpty);
      expect(recoveredArchives.map((archive) => archive.id), [
        'archive-1000',
        'archive-interrupted',
      ]);
      expect(
        await File('${temp.path}/chat_archive_transition_v1.json').exists(),
        isFalse,
      );
    },
  );

  test('capability mismatch fails before any migration payload POST', () async {
    await seedFixtureHistory();
    final api = _FakeHistoryMigrationApi()
      ..capabilityError = const HistoryMigrationException(
        '当前服务器不支持历史聊天迁移 v1，已安全停止',
      );
    final repository = HistoryMigrationRepository(api: api);

    await expectLater(
      repository.preview(),
      throwsA(isA<HistoryMigrationException>()),
    );

    expect(api.previewCalls, 0);
    expect(api.importCalls, 0);
    expect(await ChatStore.load(), hasLength(2));
    expect(await ChatStore.loadArchives(), hasLength(1));
  });

  test(
    'transport failure retries the frozen snapshot without duplication',
    () async {
      await seedFixtureHistory();
      final api = _FakeHistoryMigrationApi()
        ..importOutcomes.addAll([
          const HistoryMigrationException('connection reset'),
          {
            'ok': true,
            'status': 'complete',
            'window_count': 2,
            'message_count': 4,
            'reused_event_count': 4,
            'new_event_count': 0,
            'conflict_count': 0,
            'anomaly_count': 0,
            'warning_count': 0,
          },
        ]);
      final repository = HistoryMigrationRepository(api: api);

      final report = await repository.import();
      final state = await repository.loadState();

      expect(api.importCalls, 2);
      expect(report['status'], 'complete');
      expect(state?['status'], 'complete');
      expect(state?['source_retained'], isTrue);
      expect(await ChatStore.load(), hasLength(2));
      expect(await ChatStore.loadArchives(), hasLength(1));
    },
  );

  test('process restart resumes from server-complete manifest', () async {
    await seedFixtureHistory();
    final firstApi = _FakeHistoryMigrationApi()
      ..importOutcomes.add(const HistoryMigrationException('offline'));
    final firstRepository = HistoryMigrationRepository(api: firstApi);
    await expectLater(
      firstRepository.import(transportAttempts: 1),
      throwsA(isA<HistoryMigrationException>()),
    );
    expect((await firstRepository.loadState())?['status'], 'importing');

    final snapshot = await firstRepository.createOrLoadSnapshot();
    final report = {
      'ok': true,
      'status': 'complete',
      'snapshot_id': snapshot['snapshot_id'],
      'snapshot_hash': snapshot['snapshot_hash'],
      'message_count': 4,
    };
    final restartedApi = _FakeHistoryMigrationApi()
      ..remoteStatus = {'ok': true, 'status': 'complete', 'report': report};
    final restarted = HistoryMigrationRepository(api: restartedApi);

    expect(await restarted.resume(), report);
    expect(restartedApi.statusCalls, 1);
    expect(restartedApi.importCalls, 0);
    expect((await restarted.loadState())?['status'], 'complete');
    expect(await ChatStore.load(), hasLength(2));
    expect(await ChatStore.loadArchives(), hasLength(1));
  });

  test('preview rejection never calls formal import', () async {
    await seedFixtureHistory();
    final api = _FakeHistoryMigrationApi()
      ..previewError = const HistoryMigrationException(
        'legacy migration snapshot is not lossless',
        statusCode: 400,
      );
    final repository = HistoryMigrationRepository(api: api);

    await expectLater(
      repository.import(),
      throwsA(isA<HistoryMigrationException>()),
    );

    expect(api.importCalls, 0);
    expect(await ChatStore.load(), hasLength(2));
    expect(await ChatStore.loadArchives(), hasLength(1));
  });
}
