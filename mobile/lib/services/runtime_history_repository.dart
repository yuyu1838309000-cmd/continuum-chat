import 'dart:math';

import '../models/message.dart';
import 'api_cache.dart';
import 'canonical_history_message_mapper.dart';
import 'history_index_item.dart';
import 'runtime_history_api.dart';
import 'runtime_history_models.dart';

int _historyCommandSequence = 0;

String _newHistoryCommandId(String scope) =>
    'history-ui-$scope-${DateTime.now().microsecondsSinceEpoch}-${_historyCommandSequence++}';

abstract class RuntimeHistoryCache {
  Future<Object?> read(String key);
  Future<void> write(String key, Object value);
}

class ApiRuntimeHistoryCache implements RuntimeHistoryCache {
  const ApiRuntimeHistoryCache();

  @override
  Future<Object?> read(String key) => ApiCache.read(key);

  @override
  Future<void> write(String key, Object value) => ApiCache.write(key, value);
}

class RuntimeHistoryRepository {
  RuntimeHistoryRepository({
    RuntimeHistoryApi? api,
    this.cache = const ApiRuntimeHistoryCache(),
  }) : api = api ?? RuntimeHistoryApi();

  final RuntimeHistoryApi api;
  final RuntimeHistoryCache cache;
  DateTime? _legacyCutoffUtc;

  void close() => api.close();
  bool? _legacyAvailable;

  Future<HistoryConversationPage> conversations({
    int? beforeOrdinal,
    int limit = 50,
    int? expectedRevision,
  }) async {
    final key = _cacheKey(
      'runtime/epochs?before=${beforeOrdinal ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.epochs(beforeOrdinal: beforeOrdinal, limit: limit),
    );
    _requireRevision(expectedRevision, loaded.data);
    final raw = loaded.data['epochs'];
    final items = <HistoryConversationSummary>[
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          HistoryConversationSummary.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    final page = _map(loaded.data['page']);
    return HistoryConversationPage(
      items: items,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextBeforeOrdinal: _int(page['next_before_ordinal']),
      revision: _int(loaded.data['revision']),
    );
  }

  Future<LegacyHistoryGroupPage> legacyGroups({
    String? cursor,
    int limit = 50,
  }) async {
    final key = _cacheKey('legacy/groups?cursor=${cursor ?? ''}&limit=$limit');
    final loaded = await _load(
      key,
      () => api.legacyGroups(cursor: cursor, limit: limit),
    );
    final raw = loaded.data['groups'];
    final items = <LegacyHistoryGroupSummary>[
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          LegacyHistoryGroupSummary.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    final page = _map(loaded.data['page']);
    return LegacyHistoryGroupPage(
      items: items,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextCursor: page['next_cursor']?.toString(),
    );
  }

  Future<List<HistoryIndexItem>> historyIndex() async {
    final runtime = <HistoryIndexItem>[];
    int? beforeOrdinal;
    int? revision;
    do {
      final page = await conversations(
        beforeOrdinal: beforeOrdinal,
        limit: 50,
        expectedRevision: revision,
      );
      revision ??= page.revision;
      runtime.addAll(page.items.map(HistoryIndexItem.runtime));
      if (!page.hasMore || page.nextBeforeOrdinal == null) break;
      beforeOrdinal = page.nextBeforeOrdinal;
    } while (true);

    await _ensureLegacyState();
    final legacy = <HistoryIndexItem>[];
    if (_legacyAvailable == true) {
      String? cursor;
      do {
        final page = await legacyGroups(cursor: cursor, limit: 100);
        legacy.addAll(
          page.items
              .where((group) => group.bucket == 'windowed')
              .map(HistoryIndexItem.legacy),
        );
        if (!page.hasMore || page.nextCursor == null) break;
        cursor = page.nextCursor;
      } while (true);
    }

    final items = [...runtime, ...legacy]
      ..sort((a, b) => b.archivedAt.compareTo(a.archivedAt));
    return items;
  }

  Future<HistoryMessagePage> epochMessages(
    String epochId, {
    int afterSeq = 0,
    int limit = 200,
    int? expectedRevision,
  }) async {
    final key = _cacheKey(
      'runtime/epoch/$epochId?after=$afterSeq&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.epochDetail(epochId, afterSeq: afterSeq, limit: limit),
    );
    _requireRevision(expectedRevision, loaded.data);
    final raw = loaded.data['messages'];
    final messages = [
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          CanonicalHistoryMessageMapper.fromRuntime(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    final page = _map(loaded.data['page']);
    return HistoryMessagePage(
      messages: messages,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextCursor: page['next_after_seq']?.toString(),
      revision: _int(loaded.data['revision']),
    );
  }

  Future<HistoryMessagePage> legacyGroupMessages(
    String groupId, {
    int afterId = 0,
    int limit = 200,
  }) async {
    final key = _cacheKey('legacy/group/$groupId?after=$afterId&limit=$limit');
    final loaded = await _load(
      key,
      () => api.legacyGroupDetail(groupId, afterId: afterId, limit: limit),
    );
    final raw = loaded.data['messages'];
    final messages = [
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          CanonicalHistoryMessageMapper.fromLegacyArchive(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    final page = _map(loaded.data['page']);
    return HistoryMessagePage(
      messages: messages,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextCursor: page['next_after_id']?.toString(),
    );
  }

  Future<List<ChatMessage>> completeConversationMessages(
    HistoryIndexItem item, {
    int pageSize = 200,
  }) {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    if (item.legacyArchive) {
      final groupId = item.legacyGroupId;
      if (groupId == null || groupId.isEmpty) {
        throw const RuntimeHistoryException('旧历史缺少 group id');
      }
      return _completeLegacyGroupMessages(groupId, pageSize: pageSize);
    }
    final epochId = item.epochId;
    if (epochId == null || epochId.isEmpty) {
      throw const RuntimeHistoryException('Runtime 历史缺少 epoch id');
    }
    return _completeEpochMessages(epochId, pageSize: pageSize);
  }

  Future<List<ChatMessage>> completeSearchHitMessages(
    HistorySearchHit hit, {
    int pageSize = 200,
  }) {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    if (hit.legacyArchive) {
      if (hit.groupBucket != 'windowed') {
        return Future.value([hit.message]);
      }
      final groupId = hit.legacyGroupId;
      if (groupId == null || groupId.isEmpty) {
        throw const RuntimeHistoryException('旧历史缺少 group id');
      }
      return _completeLegacyGroupMessages(groupId, pageSize: pageSize);
    }
    final epochId = hit.epochId;
    if (epochId == null || epochId.isEmpty) {
      throw const RuntimeHistoryException('Runtime 历史缺少 epoch id');
    }
    return _completeEpochMessages(epochId, pageSize: pageSize);
  }

  Future<List<ChatMessage>> _completeEpochMessages(
    String epochId, {
    required int pageSize,
  }) async {
    final messages = <ChatMessage>[];
    var afterSeq = 0;
    int? revision;
    while (true) {
      final page = await epochMessages(
        epochId,
        afterSeq: afterSeq,
        limit: pageSize,
        expectedRevision: revision,
      );
      revision ??= page.revision;
      messages.addAll(page.messages);
      if (!page.hasMore) return messages;
      afterSeq = _nextIntegerCursor(
        page.nextCursor,
        current: afterSeq,
        name: 'next_after_seq',
      );
    }
  }

  Future<List<ChatMessage>> _completeLegacyGroupMessages(
    String groupId, {
    required int pageSize,
  }) async {
    final messages = <ChatMessage>[];
    var afterId = 0;
    while (true) {
      final page = await legacyGroupMessages(
        groupId,
        afterId: afterId,
        limit: pageSize,
      );
      messages.addAll(page.messages);
      if (!page.hasMore) return messages;
      afterId = _nextIntegerCursor(
        page.nextCursor,
        current: afterId,
        name: 'next_after_id',
      );
    }
  }

  int _nextIntegerCursor(
    String? raw, {
    required int current,
    required String name,
  }) {
    final next = int.tryParse(raw ?? '');
    if (next == null || next <= current) {
      throw RuntimeHistoryException('历史分页返回了无效的 $name');
    }
    return next;
  }

  Future<HistorySearchPage> search(
    String query, {
    String phase = 'runtime',
    String? cursor,
    int limit = 30,
    int? expectedRevision,
  }) async {
    if (phase == 'legacy') {
      await _ensureLegacyState();
      if (_legacyAvailable != true) {
        return const HistorySearchPage(
          results: [],
          fromCache: false,
          hasMore: false,
          phase: 'done',
        );
      }
      return _searchLegacy(query, cursor: cursor, limit: limit);
    }
    if (phase != 'runtime') {
      throw ArgumentError.value(phase, 'phase', 'must be runtime or legacy');
    }
    final key = _cacheKey(
      'runtime/search?q=$query&cursor=${cursor ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.search(query, cursor: cursor, limit: limit),
    );
    _requireRevision(expectedRevision, loaded.data);
    final revision = _int(loaded.data['revision']);
    final hits = _runtimeHits(loaded.data, query);
    final page = _map(loaded.data['page']);
    final runtimeHasMore = page['has_more'] == true;
    if (runtimeHasMore) {
      return HistorySearchPage(
        results: hits,
        fromCache: loaded.fromCache,
        hasMore: true,
        phase: 'runtime',
        nextCursor: page['next_cursor']?.toString(),
        revision: revision,
      );
    }
    await _ensureLegacyState();
    if (_legacyAvailable != true) {
      return HistorySearchPage(
        results: hits,
        fromCache: loaded.fromCache,
        hasMore: false,
        phase: 'done',
        revision: revision,
      );
    }
    if (hits.length >= limit) {
      return HistorySearchPage(
        results: hits,
        fromCache: loaded.fromCache,
        hasMore: true,
        phase: 'legacy',
        revision: revision,
      );
    }
    final legacy = await _searchLegacy(
      query,
      limit: max(1, limit - hits.length),
    );
    return HistorySearchPage(
      results: [...hits, ...legacy.results],
      fromCache: loaded.fromCache || legacy.fromCache,
      hasMore: legacy.hasMore,
      phase: legacy.hasMore ? 'legacy' : 'done',
      nextCursor: legacy.nextCursor,
      revision: revision,
    );
  }

  Future<HistorySearchPage> _searchLegacy(
    String query, {
    String? cursor,
    int limit = 30,
  }) async {
    final key = _cacheKey(
      'legacy/search?q=$query&cursor=${cursor ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.legacySearch(query, cursor: cursor, limit: limit),
    );
    final raw = loaded.data['results'];
    final hits = <HistorySearchHit>[
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          _legacyHit(item.map((key, value) => MapEntry(key.toString(), value))),
    ];
    final page = _map(loaded.data['page']);
    return HistorySearchPage(
      results: hits,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      phase: page['has_more'] == true ? 'legacy' : 'done',
      nextCursor: page['next_cursor']?.toString(),
    );
  }

  List<HistorySearchHit> _runtimeHits(Map<String, dynamic> data, String query) {
    final raw = data['results'];
    return [
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          _runtimeHit(
            item.map((key, value) => MapEntry(key.toString(), value)),
            query,
          ),
    ];
  }

  HistorySearchHit _runtimeHit(Map<String, dynamic> row, String query) {
    final message = CanonicalHistoryMessageMapper.fromRuntime(row);
    final normalizedQuery = query.toLowerCase();
    final providerContent = (row['content'] ?? '').toString().toLowerCase();
    final visibleContent = message.content.toLowerCase();
    final attachmentOnly =
        normalizedQuery.isNotEmpty &&
        !visibleContent.contains(normalizedQuery) &&
        providerContent.contains(normalizedQuery);
    return HistorySearchHit(
      message: message,
      legacyArchive: false,
      epochId: row['epoch_id']?.toString(),
      attachmentContentMatch: attachmentOnly,
    );
  }

  HistorySearchHit _legacyHit(Map<String, dynamic> row) {
    return HistorySearchHit(
      message: CanonicalHistoryMessageMapper.fromLegacyArchive(row),
      legacyArchive: true,
      legacyGroupId: row['group_id']?.toString(),
      groupBucket: row['group_bucket']?.toString(),
    );
  }

  Future<HistoryCapabilities> capabilities() async {
    final key = _cacheKey('runtime/capabilities');
    final loaded = await _load(key, api.capabilities);
    final projection = _map(loaded.data['history_projection']);
    if (projection['version'] != 1 ||
        projection['canonical_search'] != true ||
        projection['calendar_ranges'] != true) {
      throw const RuntimeHistoryException('当前服务器不支持 History Projection v1');
    }
    final legacy = _map(loaded.data['legacy_history_archive']);
    _legacyAvailable = legacy['available'] == true;
    _legacyCutoffUtc = DateTime.tryParse(
      legacy['cutoff_exclusive']?.toString() ?? '',
    )?.toUtc();
    return HistoryCapabilities(
      historyProjectionAvailable: true,
      legacyArchiveAvailable: _legacyAvailable == true,
      trashRetentionDays: _int(projection['trash_retention_days']) ?? 7,
    );
  }

  Future<HistoryFolderSnapshot> folders({int? expectedRevision}) async {
    final key = _cacheKey('runtime/folders');
    final loaded = await _load(key, api.folders);
    _requireRevision(expectedRevision, loaded.data);
    final raw = loaded.data['folders'];
    final items = <HistoryFolder>[
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          HistoryFolder.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    return HistoryFolderSnapshot(
      items: items,
      fromCache: loaded.fromCache,
      revision: _int(loaded.data['revision']),
    );
  }

  Future<HistoryFolder> createFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RuntimeHistoryException('文件夹名字不能为空');
    }
    final data = await api.createFolder(
      name: trimmed,
      commandId: _newHistoryCommandId('folder-create'),
    );
    return HistoryFolder.fromJson(_map(data['folder']));
  }

  Future<HistoryFolder> renameFolder(String folderId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const RuntimeHistoryException('文件夹名字不能为空');
    }
    final data = await api.renameFolder(
      folderId: folderId,
      name: trimmed,
      commandId: _newHistoryCommandId('folder-rename'),
    );
    return HistoryFolder.fromJson(_map(data['folder']));
  }

  Future<void> deleteFolder(String folderId) async {
    await api.deleteFolder(
      folderId: folderId,
      commandId: _newHistoryCommandId('folder-delete'),
    );
  }

  Future<void> assignFolder(List<String> epochIds, String? folderId) async {
    final ids = epochIds.where((id) => id.isNotEmpty).toSet().toList()..sort();
    if (ids.isEmpty) return;
    await api.assignFolder(
      epochIds: ids,
      folderId: (folderId == null || folderId.isEmpty) ? null : folderId,
      commandId: _newHistoryCommandId('folder-assign'),
    );
  }

  Future<void> deleteConversation(String epochId) async {
    await api.deleteEpoch(
      epochId: epochId,
      commandId: _newHistoryCommandId('epoch-delete'),
    );
  }

  Future<void> restoreConversation(String epochId) async {
    await api.restoreEpoch(
      epochId: epochId,
      commandId: _newHistoryCommandId('epoch-restore'),
    );
  }

  Future<HistoryConversationPage> trash({
    int? beforeOrdinal,
    int limit = 50,
    int? expectedRevision,
  }) async {
    final key = _cacheKey(
      'runtime/trash?before=${beforeOrdinal ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.trash(beforeOrdinal: beforeOrdinal, limit: limit),
    );
    _requireRevision(expectedRevision, loaded.data);
    final raw = loaded.data['epochs'];
    final items = <HistoryConversationSummary>[
      for (final item in raw is List ? raw : const [])
        if (item is Map)
          HistoryConversationSummary.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
    final page = _map(loaded.data['page']);
    return HistoryConversationPage(
      items: items,
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextBeforeOrdinal: _int(page['next_before_ordinal']),
      revision: _int(loaded.data['revision']),
    );
  }

  Future<HistoryTrashSnapshot> completeTrash({int pageSize = 50}) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }

    final items = <HistoryConversationSummary>[];
    int? beforeOrdinal;
    int? revision;
    var fromCache = false;
    final visitedCursors = <int?>{};
    do {
      if (!visitedCursors.add(beforeOrdinal)) {
        throw const RuntimeHistoryException('最近删除分页游标无效');
      }
      final page = await trash(
        beforeOrdinal: beforeOrdinal,
        limit: pageSize,
        expectedRevision: revision,
      );
      final pageRevision = page.revision;
      if (pageRevision == null) {
        throw const RuntimeHistoryException('最近删除缺少历史数据版本', kind: 'contract');
      }
      revision ??= pageRevision;
      fromCache = fromCache || page.fromCache;
      items.addAll(page.items);
      if (!page.hasMore) break;
      final nextCursor = page.nextBeforeOrdinal;
      if (nextCursor == null) {
        throw const RuntimeHistoryException('最近删除分页游标无效');
      }
      beforeOrdinal = nextCursor;
    } while (true);

    return HistoryTrashSnapshot(
      items: items,
      fromCache: fromCache,
      revision: revision,
    );
  }

  Future<HistoryCalendarSnapshot> calendar({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
    int? expectedRevision,
  }) async {
    await _ensureLegacyState();
    final cutoff = _legacyCutoffUtc;
    final useLegacy =
        _legacyAvailable == true &&
        cutoff != null &&
        start.toUtc().isBefore(cutoff);
    final useRuntime = cutoff == null || end.toUtc().isAfter(cutoff);
    final pieces = <_Loaded>[];
    if (useLegacy) {
      final key = _cacheKey(
        'legacy/calendar?start=${start.toUtc().toIso8601String()}&end=${end.toUtc().toIso8601String()}&tz=$timezoneOffsetMinutes',
      );
      pieces.add(
        await _load(
          key,
          () => api.legacyCalendar(
            start: start,
            end: end,
            timezoneOffsetMinutes: timezoneOffsetMinutes,
          ),
        ),
      );
    }
    int? runtimeRevision;
    if (useRuntime) {
      final key = _cacheKey(
        'runtime/calendar?start=${start.toUtc().toIso8601String()}&end=${end.toUtc().toIso8601String()}&tz=$timezoneOffsetMinutes',
      );
      final runtime = await _load(
        key,
        () => api.calendar(
          start: start,
          end: end,
          timezoneOffsetMinutes: timezoneOffsetMinutes,
        ),
      );
      _requireRevision(expectedRevision, runtime.data);
      runtimeRevision = _int(runtime.data['revision']);
      pieces.add(runtime);
    }
    final totals =
        <String, ({int messages, int usageCount, int input, int output})>{};
    for (final piece in pieces) {
      final rawDays = piece.data['days'];
      for (final raw in rawDays is List ? rawDays : const []) {
        if (raw is! Map) continue;
        final row = raw.map((key, value) => MapEntry(key.toString(), value));
        final date = (row['date'] ?? '').toString();
        if (date.isEmpty) continue;
        final current =
            totals[date] ?? (messages: 0, usageCount: 0, input: 0, output: 0);
        totals[date] = (
          messages: current.messages + (_int(row['message_count']) ?? 0),
          usageCount:
              current.usageCount + (_int(row['provider_usage_count']) ?? 0),
          input: current.input + (_int(row['input_tokens']) ?? 0),
          output: current.output + (_int(row['output_tokens']) ?? 0),
        );
      }
    }
    final days =
        totals.entries
            .map(
              (entry) => HistoryCalendarDay(
                date: entry.key,
                messageCount: entry.value.messages,
                providerUsageCount: entry.value.usageCount,
                inputTokens: entry.value.input,
                outputTokens: entry.value.output,
              ),
            )
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    return HistoryCalendarSnapshot(
      days: days,
      fromCache: pieces.any((piece) => piece.fromCache),
      revision: runtimeRevision,
    );
  }

  Future<HistoryMessagePage> dayMessages({
    required DateTime start,
    required DateTime end,
    String phase = 'auto',
    String? cursor,
    int limit = 200,
    int? expectedRevision,
  }) async {
    await _ensureLegacyState();
    final cutoff = _legacyCutoffUtc;
    final legacyRelevant =
        _legacyAvailable == true &&
        cutoff != null &&
        start.toUtc().isBefore(cutoff);
    final runtimeRelevant = cutoff == null || end.toUtc().isAfter(cutoff);
    var currentPhase = phase;
    if (currentPhase == 'auto') {
      currentPhase = legacyRelevant ? 'legacy' : 'runtime';
    }
    if (currentPhase == 'legacy' && !legacyRelevant) currentPhase = 'runtime';
    if (currentPhase != 'legacy' && currentPhase != 'runtime') {
      throw ArgumentError.value(
        phase,
        'phase',
        'must be auto, legacy or runtime',
      );
    }
    if (currentPhase == 'legacy') {
      final legacy = await _legacyDayPage(
        start: start,
        end: end,
        cursor: cursor,
        limit: limit,
      );
      if (legacy.hasMore) return legacy;
      if (!runtimeRelevant) {
        return HistoryMessagePage(
          messages: legacy.messages,
          fromCache: legacy.fromCache,
          hasMore: false,
          phase: 'done',
        );
      }
      final remaining = limit - legacy.messages.length;
      if (remaining <= 0) {
        return HistoryMessagePage(
          messages: legacy.messages,
          fromCache: legacy.fromCache,
          hasMore: true,
          phase: 'runtime',
        );
      }
      final runtime = await _runtimeDayPage(
        start: start,
        end: end,
        limit: remaining,
        expectedRevision: expectedRevision,
      );
      return HistoryMessagePage(
        messages: [...legacy.messages, ...runtime.messages],
        fromCache: legacy.fromCache || runtime.fromCache,
        hasMore: runtime.hasMore,
        nextCursor: runtime.nextCursor,
        revision: runtime.revision,
        phase: runtime.hasMore ? 'runtime' : 'done',
      );
    }
    if (!runtimeRelevant) {
      return const HistoryMessagePage(
        messages: [],
        fromCache: false,
        hasMore: false,
        phase: 'done',
      );
    }
    return _runtimeDayPage(
      start: start,
      end: end,
      cursor: cursor,
      limit: limit,
      expectedRevision: expectedRevision,
    );
  }

  Future<HistoryDaySnapshot> completeDayMessages({
    required DateTime start,
    required DateTime end,
    int pageSize = 200,
  }) async {
    if (!start.isBefore(end)) {
      throw ArgumentError.value(end, 'end', 'must be after start');
    }
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }

    final messages = <ChatMessage>[];
    var phase = 'auto';
    String? cursor;
    int? revision;
    var fromCache = false;
    final visitedPages = <String>{};
    do {
      final pageKey = '$phase:${cursor ?? ''}';
      if (!visitedPages.add(pageKey)) {
        throw const RuntimeHistoryException('历史分页游标无效');
      }
      final page = await dayMessages(
        start: start,
        end: end,
        phase: phase,
        cursor: cursor,
        limit: pageSize,
        expectedRevision: revision,
      );
      messages.addAll(page.messages);
      fromCache = fromCache || page.fromCache;
      revision ??= page.revision;
      if (!page.hasMore) break;
      phase = page.phase;
      cursor = page.nextCursor;
    } while (true);

    messages.sort((a, b) => a.time.compareTo(b.time));
    return HistoryDaySnapshot(
      messages: messages,
      fromCache: fromCache,
      revision: revision,
    );
  }

  /// Aggregates provider-reported usage from the calendar summary endpoint.
  ///
  /// The server already owns canonical `usage_json`, so token charts must not
  /// download and decode every full message just to add two integers. Legacy
  /// archive days without real Provider usage remain absent; no estimates are
  /// synthesized from text length or UI cache.
  Future<HistoryTokenUsageSnapshot> tokenUsage({
    required DateTime start,
    required DateTime end,
    required int timezoneOffsetMinutes,
    int pageSize = 200,
  }) async {
    if (!start.isBefore(end)) {
      throw ArgumentError.value(end, 'end', 'must be after start');
    }
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'must be positive');
    }
    final totals = <String, ({int input, int output})>{};
    var fromCache = false;
    var chunkStart = start;
    const maxCalendarRange = Duration(days: 62);
    while (chunkStart.isBefore(end)) {
      final proposedEnd = chunkStart.add(maxCalendarRange);
      final chunkEnd = proposedEnd.isBefore(end) ? proposedEnd : end;
      final snapshot = await calendar(
        start: chunkStart,
        end: chunkEnd,
        timezoneOffsetMinutes: timezoneOffsetMinutes,
      );
      fromCache = fromCache || snapshot.fromCache;
      for (final day in snapshot.days) {
        if (!day.hasProviderUsage) continue;
        final current = totals[day.date] ?? (input: 0, output: 0);
        totals[day.date] = (
          input: current.input + day.inputTokens,
          output: current.output + day.outputTokens,
        );
      }
      chunkStart = chunkEnd;
    }
    final days =
        totals.entries
            .map(
              (entry) => HistoryTokenUsageDay(
                date: entry.key,
                inputTokens: entry.value.input,
                outputTokens: entry.value.output,
              ),
            )
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    return HistoryTokenUsageSnapshot(days: days, fromCache: fromCache);
  }

  Future<HistoryMessagePage> _legacyDayPage({
    required DateTime start,
    required DateTime end,
    String? cursor,
    required int limit,
  }) async {
    final key = _cacheKey(
      'legacy/messages?start=${start.toUtc().toIso8601String()}'
      '&end=${end.toUtc().toIso8601String()}&cursor=${cursor ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.legacyMessages(
        start: start,
        end: end,
        cursor: cursor,
        limit: limit,
      ),
    );
    final page = _map(loaded.data['page']);
    return HistoryMessagePage(
      messages: _legacyMessages(loaded.data['messages']),
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextCursor: page['next_cursor']?.toString(),
      phase: page['has_more'] == true ? 'legacy' : 'done',
    );
  }

  Future<HistoryMessagePage> _runtimeDayPage({
    required DateTime start,
    required DateTime end,
    String? cursor,
    required int limit,
    int? expectedRevision,
  }) async {
    final key = _cacheKey(
      'runtime/messages?start=${start.toUtc().toIso8601String()}'
      '&end=${end.toUtc().toIso8601String()}&cursor=${cursor ?? ''}&limit=$limit',
    );
    final loaded = await _load(
      key,
      () => api.messages(start: start, end: end, cursor: cursor, limit: limit),
    );
    _requireRevision(expectedRevision, loaded.data);
    final page = _map(loaded.data['page']);
    return HistoryMessagePage(
      messages: _runtimeMessages(loaded.data['messages']),
      fromCache: loaded.fromCache,
      hasMore: page['has_more'] == true,
      nextCursor: page['next_cursor']?.toString(),
      revision: _int(loaded.data['revision']),
      phase: page['has_more'] == true ? 'runtime' : 'done',
    );
  }

  List<ChatMessage> _runtimeMessages(Object? raw) => [
    for (final item in raw is List ? raw : const [])
      if (item is Map)
        CanonicalHistoryMessageMapper.fromRuntime(
          item.map((key, value) => MapEntry(key.toString(), value)),
        ),
  ];

  List<ChatMessage> _legacyMessages(Object? raw) => [
    for (final item in raw is List ? raw : const [])
      if (item is Map)
        CanonicalHistoryMessageMapper.fromLegacyArchive(
          item.map((key, value) => MapEntry(key.toString(), value)),
        ),
  ];

  Future<void> _ensureLegacyState() async {
    if (_legacyAvailable != null) return;
    await capabilities();
  }

  String _cacheKey(String scope) {
    final authority = api.uriFor('/runtime/capabilities').authority;
    return 'history-cache://$authority/$scope';
  }

  Future<_Loaded> _load(
    String key,
    Future<Map<String, dynamic>> Function() network,
  ) async {
    try {
      final data = await network();
      await cache.write(key, data);
      return _Loaded(data, false);
    } on RuntimeHistoryException catch (error) {
      if (error.kind != 'transport') rethrow;
      final cached = await cache.read(key);
      if (cached is Map) {
        return _Loaded(
          cached.map((key, value) => MapEntry(key.toString(), value)),
          true,
        );
      }
      rethrow;
    }
  }

  Map<String, dynamic> _map(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void _requireRevision(int? expectedRevision, Map<String, dynamic> data) {
    if (expectedRevision == null) return;
    final actualRevision = _int(data['revision']);
    if (actualRevision != expectedRevision) {
      throw const RuntimeHistoryException(
        '历史数据版本已经变化，请刷新后重试',
        kind: 'revision',
      );
    }
  }
}

class _Loaded {
  const _Loaded(this.data, this.fromCache);

  final Map<String, dynamic> data;
  final bool fromCache;
}
