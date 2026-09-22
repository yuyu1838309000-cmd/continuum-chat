import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/archive_folder.dart';
import '../models/archived_chat.dart';
import 'chat_store.dart';
import 'runtime_history_api.dart';
import 'runtime_history_models.dart';

abstract class HistoryCutoverLocalSource {
  Future<List<ArchiveFolder>> loadFolders();
  Future<List<ArchivedChat>> loadArchives();
}

class ChatStoreHistoryCutoverSource implements HistoryCutoverLocalSource {
  const ChatStoreHistoryCutoverSource();

  @override
  Future<List<ArchivedChat>> loadArchives() => ChatStore.loadArchives();

  @override
  Future<List<ArchiveFolder>> loadFolders() => ChatStore.loadFolders();
}

class HistoryCutoverEpochCatalog {
  const HistoryCutoverEpochCatalog({required this.epochs, this.revision});

  final List<HistoryConversationSummary> epochs;
  final int? revision;
}

abstract class HistoryCutoverRemote {
  Future<Map<String, dynamic>> bootstrapFolders(List<ArchiveFolder> folders);

  Future<HistoryCutoverEpochCatalog> loadClosedEpochs();

  Future<Set<int>> loadRawEventIds(String epochId, {int? expectedRevision});

  Future<Map<String, dynamic>> assignFolder({
    required List<String> epochIds,
    required String? folderId,
    required String commandId,
  });

  String get authority;
}

class RuntimeHistoryCutoverRemote implements HistoryCutoverRemote {
  RuntimeHistoryCutoverRemote({RuntimeHistoryApi? api})
    : api = api ?? RuntimeHistoryApi();

  final RuntimeHistoryApi api;

  @override
  String get authority => api.uriFor('/runtime/capabilities').authority;
  @override
  Future<Map<String, dynamic>> bootstrapFolders(List<ArchiveFolder> folders) =>
      api.bootstrapFolders([for (final folder in folders) folder.toJson()]);

  @override
  Future<HistoryCutoverEpochCatalog> loadClosedEpochs() async {
    final epochs = <HistoryConversationSummary>[];
    int? beforeOrdinal;
    int? revision;
    while (true) {
      final data = await api.epochs(beforeOrdinal: beforeOrdinal, limit: 100);
      final pageRevision = _jsonInt(data['revision']);
      if (revision != null && pageRevision != revision) {
        throw const RuntimeHistoryException(
          '历史列表版本已变化，请重新执行切权',
          kind: 'revision',
        );
      }
      revision ??= pageRevision;
      final raw = data['epochs'];
      for (final item in raw is List ? raw : const []) {
        if (item is! Map) continue;
        final epoch = HistoryConversationSummary.fromJson(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (epoch.status == 'closed') epochs.add(epoch);
      }
      final page = _stringMap(data['page']);
      if (page['has_more'] != true) break;
      final next = _jsonInt(page['next_before_ordinal']);
      if (next == null || next == beforeOrdinal) {
        throw const RuntimeHistoryException('历史列表分页游标无效', kind: 'contract');
      }
      beforeOrdinal = next;
    }
    return HistoryCutoverEpochCatalog(epochs: epochs, revision: revision);
  }

  @override
  Future<Set<int>> loadRawEventIds(
    String epochId, {
    int? expectedRevision,
  }) async {
    final ids = <int>{};
    var afterSeq = 0;
    while (true) {
      final data = await api.epochDetail(
        epochId,
        afterSeq: afterSeq,
        limit: 500,
      );
      final revision = _jsonInt(data['revision']);
      if (expectedRevision != null && revision != expectedRevision) {
        throw const RuntimeHistoryException(
          '历史详情版本已变化，请重新执行切权',
          kind: 'revision',
        );
      }
      final raw = data['messages'];
      for (final item in raw is List ? raw : const []) {
        if (item is! Map) continue;
        final id = _jsonInt(item['raw_event_id']);
        if (id != null) ids.add(id);
      }
      final page = _stringMap(data['page']);
      if (page['has_more'] != true) break;
      final next = _jsonInt(page['next_after_seq']);
      if (next == null || next <= afterSeq) {
        throw const RuntimeHistoryException('历史详情分页游标无效', kind: 'contract');
      }
      afterSeq = next;
    }
    return ids;
  }

  @override
  Future<Map<String, dynamic>> assignFolder({
    required List<String> epochIds,
    required String? folderId,
    required String commandId,
  }) => api.assignFolder(
    epochIds: epochIds,
    folderId: folderId,
    commandId: commandId,
  );
}

abstract class HistoryCutoverMarkerStore {
  Future<Map<String, dynamic>?> read(String authority);
  Future<void> save(String authority, Map<String, dynamic> payload);
}

class PreferencesHistoryCutoverMarkerStore
    implements HistoryCutoverMarkerStore {
  const PreferencesHistoryCutoverMarkerStore();

  @override
  Future<Map<String, dynamic>?> read(String authority) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('history_cutover_v1_$authority');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  @override
  Future<void> save(String authority, Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('history_cutover_v1_$authority', jsonEncode(payload));
  }
}

class HistoryCutoverUnresolved {
  const HistoryCutoverUnresolved({
    required this.archiveId,
    required this.reason,
  });

  final String archiveId;
  final String reason;

  factory HistoryCutoverUnresolved.fromJson(Map<String, dynamic> json) =>
      HistoryCutoverUnresolved(
        archiveId: (json['archive_id'] ?? '').toString(),
        reason: (json['reason'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'archive_id': archiveId, 'reason': reason};
}

class HistoryCutoverResult {
  const HistoryCutoverResult({
    required this.folderMapping,
    required this.assignedEpochCount,
    required this.unresolved,
    required this.revision,
    required this.bootstrapCreatedCount,
    required this.bootstrapAssignedCount,
    this.alreadyCompleted = false,
  });

  final Map<String, String> folderMapping;
  final int assignedEpochCount;
  final List<HistoryCutoverUnresolved> unresolved;
  final int? revision;
  final int bootstrapCreatedCount;
  final int bootstrapAssignedCount;
  final bool alreadyCompleted;

  factory HistoryCutoverResult.fromJson(
    Map<String, dynamic> json, {
    bool alreadyCompleted = false,
  }) {
    final unresolvedRaw = json['unresolved'];
    return HistoryCutoverResult(
      folderMapping: _stringMapping(json['folder_mapping']),
      assignedEpochCount: _jsonInt(json['assigned_epoch_count']) ?? 0,
      unresolved: [
        for (final item in unresolvedRaw is List ? unresolvedRaw : const [])
          if (item is Map)
            HistoryCutoverUnresolved.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
      ],
      revision: _jsonInt(json['revision']),
      bootstrapCreatedCount: _jsonInt(json['bootstrap_created_count']) ?? 0,
      bootstrapAssignedCount: _jsonInt(json['bootstrap_assigned_count']) ?? 0,
      alreadyCompleted: alreadyCompleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'folder_mapping': folderMapping,
    'assigned_epoch_count': assignedEpochCount,
    'unresolved': unresolved.map((item) => item.toJson()).toList(),
    'revision': revision,
    'bootstrap_created_count': bootstrapCreatedCount,
    'bootstrap_assigned_count': bootstrapAssignedCount,
  };
}

class HistoryCutoverCoordinator {
  HistoryCutoverCoordinator._();

  static final HistoryCutoverCoordinator instance =
      HistoryCutoverCoordinator._();
  Future<HistoryCutoverResult>? _inflight;

  Future<HistoryCutoverResult> ensure() {
    final active = _inflight;
    if (active != null) return active;
    late final Future<HistoryCutoverResult> operation;
    operation = HistoryCutoverReconciler().reconcile().whenComplete(() {
      if (identical(_inflight, operation)) _inflight = null;
    });
    _inflight = operation;
    return operation;
  }
}

class HistoryCutoverReconciler {
  HistoryCutoverReconciler({
    this.local = const ChatStoreHistoryCutoverSource(),
    HistoryCutoverRemote? remote,
    this.markerStore = const PreferencesHistoryCutoverMarkerStore(),
  }) : remote = remote ?? RuntimeHistoryCutoverRemote();

  final HistoryCutoverLocalSource local;
  final HistoryCutoverRemote remote;
  final HistoryCutoverMarkerStore markerStore;

  Future<HistoryCutoverResult> reconcile() async {
    final completed = await markerStore.read(remote.authority);
    if (completed != null && completed['version'] == 1) {
      return HistoryCutoverResult.fromJson(completed, alreadyCompleted: true);
    }

    final folders = await local.loadFolders();
    final archives = await local.loadArchives();
    final bootstrap = await remote.bootstrapFolders(folders);
    if (bootstrap['already_bootstrapped'] == true &&
        bootstrap['bootstrap_payload_matches'] != true) {
      throw const RuntimeHistoryException(
        '历史文件夹切权期间本地清单发生变化，已安全停止',
        kind: 'cutover',
      );
    }
    final mapping = _stringMapping(bootstrap['mapping']);
    final catalog = await remote.loadClosedEpochs();

    final byLegacyArchive = <String, List<HistoryConversationSummary>>{};
    final byEpoch = <String, HistoryConversationSummary>{};
    for (final epoch in catalog.epochs) {
      byEpoch[epoch.epochId] = epoch;
      final legacyId = (epoch.legacyArchiveId ?? '').trim();
      if (legacyId.isNotEmpty) {
        (byLegacyArchive[legacyId] ??= []).add(epoch);
      }
    }

    final relevant = archives
        .where((archive) => (archive.folderId ?? '').trim().isNotEmpty)
        .toList(growable: false);
    final plans = <_ArchivePlan>[];
    final needsRawLookup = <_ArchivePlan>[];
    for (final archive in relevant) {
      final localFolderId = archive.folderId!.trim();
      final serverFolderId = mapping[localFolderId];
      if (serverFolderId == null || serverFolderId.isEmpty) {
        plans.add(_ArchivePlan.unresolved(archive, 'folder_mapping_missing'));
        continue;
      }

      final direct = byLegacyArchive[archive.id] ?? const [];
      if (direct.length == 1) {
        plans.add(
          _ArchivePlan.resolved(archive, serverFolderId, direct.single),
        );
        continue;
      }
      if (direct.length > 1) {
        plans.add(
          _ArchivePlan.unresolved(archive, 'legacy_archive_id_ambiguous'),
        );
        continue;
      }

      final epochIds = archive.messages
          .map((message) => (message.epochId ?? '').trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      if (epochIds.length == 1) {
        final epoch = byEpoch[epochIds.single];
        if (epoch != null && epoch.status == 'closed') {
          plans.add(_ArchivePlan.resolved(archive, serverFolderId, epoch));
          continue;
        }
      } else if (epochIds.length > 1) {
        plans.add(_ArchivePlan.unresolved(archive, 'epoch_id_conflict'));
        continue;
      }
      final rawIds = archive.messages
          .map((message) => message.rawEventId)
          .whereType<int>()
          .toSet();
      if (rawIds.isEmpty) {
        plans.add(
          _ArchivePlan.unresolved(archive, 'no_deterministic_identity'),
        );
        continue;
      }
      final plan = _ArchivePlan.pendingRaw(archive, serverFolderId);
      plans.add(plan);
      needsRawLookup.add(plan);
    }

    if (needsRawLookup.isNotEmpty) {
      final reverse = <int, Set<String>>{};
      for (final epoch in catalog.epochs) {
        final rawIds = await remote.loadRawEventIds(
          epoch.epochId,
          expectedRevision: catalog.revision,
        );
        for (final rawId in rawIds) {
          (reverse[rawId] ??= <String>{}).add(epoch.epochId);
        }
      }
      for (final plan in needsRawLookup) {
        final rawIds = plan.archive.messages
            .map((message) => message.rawEventId)
            .whereType<int>()
            .toSet();
        if (rawIds.isEmpty) {
          plan.fail('no_deterministic_identity');
          continue;
        }
        final resolvedEpochs = <String>{};
        var failed = false;
        for (final rawId in rawIds) {
          final candidates = reverse[rawId] ?? const <String>{};
          if (candidates.isEmpty) {
            plan.fail('raw_event_unresolved');
            failed = true;
            break;
          }
          if (candidates.length != 1) {
            plan.fail('raw_event_ambiguous');
            failed = true;
            break;
          }
          resolvedEpochs.add(candidates.single);
        }
        if (failed) continue;
        if (resolvedEpochs.length != 1) {
          plan.fail('raw_event_epoch_conflict');
          continue;
        }
        final epoch = byEpoch[resolvedEpochs.single];
        if (epoch == null || epoch.status != 'closed') {
          plan.fail('target_epoch_not_closed');
          continue;
        }
        plan.resolve(epoch);
      }
    }

    final desiredFolders = <String, Set<String>>{};
    for (final plan in plans) {
      final epoch = plan.epoch;
      final folderId = plan.serverFolderId;
      if (epoch == null || folderId == null || plan.reason != null) continue;
      (desiredFolders[epoch.epochId] ??= <String>{}).add(folderId);
    }
    for (final plan in plans) {
      final epoch = plan.epoch;
      if (epoch == null || plan.reason != null) continue;
      if ((desiredFolders[epoch.epochId]?.length ?? 0) > 1) {
        plan.fail('local_folder_conflict');
        continue;
      }
      final existing = (epoch.folderId ?? '').trim();
      if (existing.isNotEmpty && existing != plan.serverFolderId) {
        plan.fail('server_folder_conflict');
      }
    }

    final assignments = <String, Set<String>>{};
    for (final plan in plans) {
      final epoch = plan.epoch;
      final folderId = plan.serverFolderId;
      if (epoch == null || folderId == null || plan.reason != null) continue;
      if (epoch.folderId == folderId) continue;
      (assignments[folderId] ??= <String>{}).add(epoch.epochId);
    }
    var assignedCount = 0;
    var revision = _jsonInt(bootstrap['revision']) ?? catalog.revision;
    final folderIds = assignments.keys.toList()..sort();
    for (final folderId in folderIds) {
      final epochIds = assignments[folderId]!.toList()..sort();
      final response = await remote.assignFolder(
        epochIds: epochIds,
        folderId: folderId,
        commandId: _stableCommandId(folderId, epochIds),
      );
      assignedCount += epochIds.length;
      revision =
          _jsonInt(response['revision']) ??
          _jsonInt(_stringMap(response['canonical_state'])['revision']) ??
          revision;
    }

    final unresolved = [
      for (final plan in plans)
        if (plan.reason != null)
          HistoryCutoverUnresolved(
            archiveId: plan.archive.id,
            reason: plan.reason!,
          ),
    ];
    final result = HistoryCutoverResult(
      folderMapping: mapping,
      assignedEpochCount: assignedCount,
      unresolved: unresolved,
      revision: revision,
      bootstrapCreatedCount: _jsonInt(bootstrap['created_count']) ?? 0,
      bootstrapAssignedCount: _jsonInt(bootstrap['assigned_count']) ?? 0,
    );
    await markerStore.save(remote.authority, {
      'version': 1,
      'completed_at': DateTime.now().toUtc().toIso8601String(),
      ...result.toJson(),
    });
    return result;
  }
}

class _ArchivePlan {
  _ArchivePlan._(this.archive, {this.serverFolderId, this.epoch, this.reason});

  factory _ArchivePlan.resolved(
    ArchivedChat archive,
    String serverFolderId,
    HistoryConversationSummary epoch,
  ) => _ArchivePlan._(archive, serverFolderId: serverFolderId, epoch: epoch);

  factory _ArchivePlan.pendingRaw(
    ArchivedChat archive,
    String serverFolderId,
  ) => _ArchivePlan._(archive, serverFolderId: serverFolderId);
  factory _ArchivePlan.unresolved(ArchivedChat archive, String reason) =>
      _ArchivePlan._(archive, reason: reason);

  final ArchivedChat archive;
  final String? serverFolderId;
  HistoryConversationSummary? epoch;
  String? reason;

  void resolve(HistoryConversationSummary value) {
    epoch = value;
    reason = null;
  }

  void fail(String value) {
    epoch = null;
    reason = value;
  }
}

Map<String, dynamic> _stringMap(Object? raw) {
  if (raw is! Map) return const {};
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

Map<String, String> _stringMapping(Object? raw) {
  final map = _stringMap(raw);
  return {for (final entry in map.entries) entry.key: entry.value.toString()};
}

int? _jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String _stableCommandId(String folderId, List<String> epochIds) {
  final payload = '$folderId|${epochIds.join('|')}';
  final first = _stableHash32(payload, 0x811c9dc5);
  final second = _stableHash32(payload, 0x9e3779b9);
  return 'history-cutover-v1-'
      '${first.toRadixString(16).padLeft(8, '0')}'
      '${second.toRadixString(16).padLeft(8, '0')}';
}

int _stableHash32(String value, int seed) {
  var hash = seed & 0xffffffff;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}
