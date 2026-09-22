import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/archive_folder.dart';
import 'package:continuum_chat/models/archived_chat.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/services/history_cutover_reconciler.dart';
import 'package:continuum_chat/services/runtime_history_api.dart';
import 'package:continuum_chat/services/runtime_history_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Local implements HistoryCutoverLocalSource {
  _Local(this.folders, this.archives);

  final List<ArchiveFolder> folders;
  final List<ArchivedChat> archives;

  @override
  Future<List<ArchivedChat>> loadArchives() async => archives;

  @override
  Future<List<ArchiveFolder>> loadFolders() async => folders;
}

class _Marker implements HistoryCutoverMarkerStore {
  _Marker({this.initial});

  final Map<String, dynamic>? initial;
  Map<String, dynamic>? saved;

  @override
  Future<Map<String, dynamic>?> read(String authority) async => initial;

  @override
  Future<void> save(String authority, Map<String, dynamic> payload) async {
    saved = {'authority': authority, ...payload};
  }
}

class _AssignCall {
  const _AssignCall(this.epochIds, this.folderId, this.commandId);
  final List<String> epochIds;
  final String? folderId;
  final String commandId;
}

class _Remote implements HistoryCutoverRemote {
  _Remote({
    required this.mapping,
    required this.catalog,
    this.rawByEpoch = const {},
    this.throwOnAssign = false,
    this.bootstrapCreated = 0,
    this.bootstrapAssigned = 0,
    this.alreadyBootstrapped = false,
    this.bootstrapPayloadMatches = true,
  });

  final Map<String, String> mapping;
  final HistoryCutoverEpochCatalog catalog;
  final Map<String, Set<int>> rawByEpoch;
  final bool throwOnAssign;
  final int bootstrapCreated;
  final int bootstrapAssigned;
  final bool alreadyBootstrapped;
  final bool bootstrapPayloadMatches;
  final calls = <_AssignCall>[];
  int bootstrapCalls = 0;
  int catalogLoads = 0;
  int rawLoads = 0;

  @override
  String get authority => 'test:8816';

  @override
  Future<Map<String, dynamic>> bootstrapFolders(
    List<ArchiveFolder> folders,
  ) async {
    bootstrapCalls += 1;
    return {
      'ok': true,
      'mapping': mapping,
      'revision': catalog.revision,
      'created_count': bootstrapCreated,
      'assigned_count': bootstrapAssigned,
      'already_bootstrapped': alreadyBootstrapped,
      'bootstrap_payload_matches': bootstrapPayloadMatches,
    };
  }

  @override
  Future<HistoryCutoverEpochCatalog> loadClosedEpochs() async {
    catalogLoads += 1;
    return catalog;
  }

  @override
  Future<Set<int>> loadRawEventIds(
    String epochId, {
    int? expectedRevision,
  }) async {
    rawLoads += 1;
    if (expectedRevision != catalog.revision) {
      throw const RuntimeHistoryException(
        'revision mismatch',
        kind: 'revision',
      );
    }
    return rawByEpoch[epochId] ?? const {};
  }

  @override
  Future<Map<String, dynamic>> assignFolder({
    required List<String> epochIds,
    required String? folderId,
    required String commandId,
  }) async {
    if (throwOnAssign) {
      throw const RuntimeHistoryException('assign failed', kind: 'transport');
    }
    calls.add(_AssignCall(List.of(epochIds), folderId, commandId));
    return {'ok': true, 'revision': (catalog.revision ?? 0) + calls.length};
  }
}

ArchiveFolder _folder(String id, String name) =>
    ArchiveFolder(id: id, name: name, createdAt: DateTime.utc(2026, 8, 14));
ArchivedChat _archive(
  String id,
  String folderId, {
  List<ChatMessage> messages = const [],
}) => ArchivedChat(
  id: id,
  archivedAt: DateTime.utc(2026, 9, 1),
  title: id,
  messages: messages,
  folderId: folderId,
  folderName: folderId,
);

HistoryConversationSummary _epoch(
  String id, {
  String? legacyArchiveId,
  String? folderId,
}) => HistoryConversationSummary(
  epochId: id,
  ordinal: 1,
  status: 'closed',
  messageCount: 2,
  legacyArchiveId: legacyArchiveId,
  folderId: folderId,
);

HistoryCutoverReconciler _reconciler(
  _Local local,
  _Remote remote,
  _Marker marker,
) =>
    HistoryCutoverReconciler(local: local, remote: remote, markerStore: marker);

void main() {
  group('HistoryCutoverReconciler deterministic matching', () {
    test('legacy archive id resolves without raw-event scan', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 7,
          epochs: [_epoch('epoch-1', legacyArchiveId: 'archive-1')],
        ),
        bootstrapCreated: 2,
        bootstrapAssigned: 34,
      );
      final result = await _reconciler(
        _Local([_folder('local-a', 'A')], [_archive('archive-1', 'local-a')]),
        remote,
        marker,
      ).reconcile();

      expect(remote.rawLoads, 0);
      expect(remote.calls.single.epochIds, ['epoch-1']);
      expect(remote.calls.single.folderId, 'server-a');
      expect(result.assignedEpochCount, 1);
      expect(result.bootstrapCreatedCount, 2);
      expect(result.bootstrapAssignedCount, 34);
      expect(result.unresolved, isEmpty);
      expect(marker.saved?['authority'], 'test:8816');
    });

    test('persisted epoch id wins before raw-event fallback', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 9,
          epochs: [_epoch('epoch-2')],
        ),
      );
      final archive = _archive(
        'recent',
        'local-a',
        messages: [ChatMessage(role: 'user', content: 'x', epochId: 'epoch-2')],
      );
      await _reconciler(
        _Local([_folder('local-a', 'A')], [archive]),
        remote,
        marker,
      ).reconcile();

      expect(remote.rawLoads, 0);
      expect(remote.calls.single.epochIds, ['epoch-2']);
    });
    test('raw event ids must all resolve to one closed epoch', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 11,
          epochs: [_epoch('epoch-1'), _epoch('epoch-2')],
        ),
        rawByEpoch: const {
          'epoch-1': {101, 102},
          'epoch-2': {201},
        },
      );
      final archive = _archive(
        'recent',
        'local-a',
        messages: [
          ChatMessage(role: 'user', content: 'a', rawEventId: 101),
          ChatMessage(role: 'assistant', content: 'b', rawEventId: 102),
        ],
      );
      final result = await _reconciler(
        _Local([_folder('local-a', 'A')], [archive]),
        remote,
        marker,
      ).reconcile();

      expect(remote.rawLoads, 2);
      expect(remote.calls.single.epochIds, ['epoch-1']);
      expect(result.unresolved, isEmpty);
    });

    test('raw ids pointing at different epochs stay unresolved', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 12,
          epochs: [_epoch('epoch-1'), _epoch('epoch-2')],
        ),
        rawByEpoch: const {
          'epoch-1': {101},
          'epoch-2': {202},
        },
      );
      final archive = _archive(
        'recent',
        'local-a',
        messages: [
          ChatMessage(role: 'user', content: 'a', rawEventId: 101),
          ChatMessage(role: 'assistant', content: 'b', rawEventId: 202),
        ],
      );
      final result = await _reconciler(
        _Local([_folder('local-a', 'A')], [archive]),
        remote,
        marker,
      ).reconcile();

      expect(remote.calls, isEmpty);
      expect(result.unresolved.single.reason, 'raw_event_epoch_conflict');
    });
    test('server folder conflict is never overwritten', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 13,
          epochs: [
            _epoch(
              'epoch-1',
              legacyArchiveId: 'archive-1',
              folderId: 'server-b',
            ),
          ],
        ),
      );
      final result = await _reconciler(
        _Local([_folder('local-a', 'A')], [_archive('archive-1', 'local-a')]),
        remote,
        marker,
      ).reconcile();

      expect(remote.calls, isEmpty);
      expect(result.unresolved.single.reason, 'server_folder_conflict');
    });

    test('two local folders cannot claim the same epoch', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a', 'local-b': 'server-b'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 14,
          epochs: [_epoch('epoch-1', legacyArchiveId: 'archive-a')],
        ),
      );
      final archives = [
        _archive('archive-a', 'local-a'),
        _archive(
          'archive-b',
          'local-b',
          messages: [
            ChatMessage(role: 'user', content: 'x', epochId: 'epoch-1'),
          ],
        ),
      ];
      final result = await _reconciler(
        _Local([_folder('local-a', 'A'), _folder('local-b', 'B')], archives),
        remote,
        marker,
      ).reconcile();

      expect(remote.calls, isEmpty);
      expect(result.unresolved.map((item) => item.reason).toSet(), {
        'local_folder_conflict',
      });
      expect(result.unresolved.length, 2);
    });
    test(
      'no identity stays unresolved without scanning server messages',
      () async {
        final marker = _Marker();
        final remote = _Remote(
          mapping: const {'local-a': 'server-a'},
          catalog: HistoryCutoverEpochCatalog(
            revision: 15,
            epochs: [_epoch('epoch-1')],
          ),
        );
        final result = await _reconciler(
          _Local([_folder('local-a', 'A')], [_archive('recent', 'local-a')]),
          remote,
          marker,
        ).reconcile();

        expect(remote.rawLoads, 0);
        expect(remote.calls, isEmpty);
        expect(result.unresolved.single.reason, 'no_deterministic_identity');
      },
    );

    test('marker is not written when assignment fails', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: HistoryCutoverEpochCatalog(
          revision: 16,
          epochs: [_epoch('epoch-1', legacyArchiveId: 'archive-1')],
        ),
        throwOnAssign: true,
      );
      final reconciler = _reconciler(
        _Local([_folder('local-a', 'A')], [_archive('archive-1', 'local-a')]),
        remote,
        marker,
      );

      await expectLater(
        reconciler.reconcile(),
        throwsA(isA<RuntimeHistoryException>()),
      );
      expect(marker.saved, isNull);
    });

    test('same plan produces stable command id across retries', () async {
      Future<String> runOnce() async {
        final remote = _Remote(
          mapping: const {'local-a': 'server-a'},
          catalog: HistoryCutoverEpochCatalog(
            revision: 17,
            epochs: [_epoch('epoch-1', legacyArchiveId: 'archive-1')],
          ),
        );
        await _reconciler(
          _Local([_folder('local-a', 'A')], [_archive('archive-1', 'local-a')]),
          remote,
          _Marker(),
        ).reconcile();
        return remote.calls.single.commandId;
      }

      expect(await runOnce(), await runOnce());
    });
  });

  group('History cutover crash safety', () {
    test(
      'completed marker skips local and server work on later starts',
      () async {
        final marker = _Marker(
          initial: {
            'version': 1,
            'folder_mapping': {'local-a': 'server-a'},
            'assigned_epoch_count': 3,
            'unresolved': const [],
            'revision': 22,
            'bootstrap_created_count': 2,
            'bootstrap_assigned_count': 34,
          },
        );
        final remote = _Remote(
          mapping: const {'local-a': 'server-a'},
          catalog: const HistoryCutoverEpochCatalog(epochs: [], revision: 22),
        );
        final result = await _reconciler(
          _Local([_folder('local-a', 'A')], const []),
          remote,
          marker,
        ).reconcile();

        expect(result.alreadyCompleted, isTrue);
        expect(result.assignedEpochCount, 3);
        expect(remote.bootstrapCalls, 0);
        expect(remote.catalogLoads, 0);
        expect(marker.saved, isNull);
      },
    );

    test('changed bootstrap payload stops before catalog or marker', () async {
      final marker = _Marker();
      final remote = _Remote(
        mapping: const {'local-a': 'server-a'},
        catalog: const HistoryCutoverEpochCatalog(epochs: [], revision: 20),
        alreadyBootstrapped: true,
        bootstrapPayloadMatches: false,
      );
      final reconciler = _reconciler(
        _Local([_folder('local-a', 'A')], const []),
        remote,
        marker,
      );

      await expectLater(
        reconciler.reconcile(),
        throwsA(
          isA<RuntimeHistoryException>().having(
            (error) => error.kind,
            'kind',
            'cutover',
          ),
        ),
      );
      expect(marker.saved, isNull);
    });
  });
  group('ArchivedChat runtime identity persistence', () {
    test('round-trip keeps canonical identity for future cutovers', () {
      final original = _archive(
        'archive-new',
        'local-a',
        messages: [
          ChatMessage(
            role: 'assistant',
            content: 'reply',
            rawEventId: 42,
            eventId: 'event-42',
            clientEventId: 'client-42',
            generationId: 'gen-42',
            epochId: 'epoch-42',
            kind: 'message',
            runtimeSeq: 9,
            runtimeStatus: 'completed',
            usage: const MessageUsage(
              promptTokens: 100,
              cacheHit: 80,
              cacheMiss: 20,
              completionTokens: 10,
            ),
          ),
        ],
      );

      final decoded = ArchivedChat.fromJson(original.toJson());
      final message = decoded.messages.single;
      expect(message.rawEventId, 42);
      expect(message.eventId, 'event-42');
      expect(message.clientEventId, 'client-42');
      expect(message.generationId, 'gen-42');
      expect(message.epochId, 'epoch-42');
      expect(message.runtimeSeq, 9);
      expect(message.runtimeStatus, 'completed');
      expect(message.usage?.cacheHit, 80);
    });
  });
  group('RuntimeHistoryApi cutover mutations', () {
    test('bootstrap and assign send exact JSON contracts', () async {
      final seen = <http.Request>[];
      final api = RuntimeHistoryApi(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(
            jsonEncode({'ok': true, 'mapping': const {}, 'revision': 3}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await api.bootstrapFolders([
        {'id': 'legacy-a', 'name': 'A', 'createdAt': '2026-08-14T00:00:00Z'},
      ]);
      await api.assignFolder(
        epochIds: const ['epoch-1'],
        folderId: 'server-a',
        commandId: 'cmd-stable',
      );

      expect(seen.length, 2);
      expect(seen[0].method, 'POST');
      expect(seen[0].url.path, '/runtime/archive-folders/bootstrap');
      expect(jsonDecode(seen[0].body)['folders'][0]['id'], 'legacy-a');
      expect(seen[1].url.path, '/runtime/archive-folders/assign');
      expect(jsonDecode(seen[1].body), {
        'thread_id': 'main',
        'epoch_ids': ['epoch-1'],
        'folder_id': 'server-a',
        'command_id': 'cmd-stable',
      });
    });
  });
}
