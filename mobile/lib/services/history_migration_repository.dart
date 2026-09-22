import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/archived_chat.dart';
import '../models/message.dart';
import 'chat_store.dart';
import 'history_migration_api.dart';

class HistoryMigrationRepository {
  const HistoryMigrationRepository({this.api = const HistoryMigrationApi()});

  final HistoryMigrationApi api;

  static const int migrationVersion = 1;
  static const String snapshotFileName =
      'legacy_chat_migration_snapshot_v1.json';
  static const String stateFileName = 'legacy_chat_migration_state_v1.json';

  Future<Map<String, dynamic>> createOrLoadSnapshot() async {
    final snapshotFile = await _snapshotFile();
    final existing = await _readJson(snapshotFile);
    if (existing != null) return existing;
    if (await snapshotFile.exists()) {
      throw const HistoryMigrationException('本地历史迁移快照损坏，已安全停止');
    }

    final source = await ChatStore.loadMigrationSourceSnapshot();
    final archives = source.archives;
    final current = source.current;
    final createdAt = DateTime.now().toIso8601String();
    final windows = <Map<String, dynamic>>[
      for (var index = 0; index < archives.length; index++)
        _archiveWindow(archives[index], index + 1),
      _activeWindow(current, archives.length + 1, createdAt),
    ];
    final hashMaterial = <String, dynamic>{
      'migration_version': migrationVersion,
      'thread_id': 'main',
      'windows': windows,
    };
    final digest = sha256.convert(utf8.encode(_canonicalJson(hashMaterial)));
    final snapshot = <String, dynamic>{
      ...hashMaterial,
      'snapshot_id': 'legacy-chat-v1-$digest',
      'snapshot_hash': digest.toString(),
    };
    await _writeJsonAtomic(await _snapshotFile(), snapshot);
    await _writeState({
      'migration_version': migrationVersion,
      'snapshot_id': snapshot['snapshot_id'],
      'snapshot_hash': snapshot['snapshot_hash'],
      'status': 'snapshot_ready',
      'source_retained': true,
    });
    return snapshot;
  }

  Future<Map<String, dynamic>> preview() async {
    final snapshot = await createOrLoadSnapshot();
    await api.requireCapability();
    final result = await api.preview(snapshot);
    await _writeState({
      'migration_version': migrationVersion,
      'snapshot_id': snapshot['snapshot_id'],
      'snapshot_hash': snapshot['snapshot_hash'],
      'status': result['can_import'] == true ? 'previewed' : 'preview_failed',
      'source_retained': true,
      'preview': result,
    });
    return result;
  }

  Future<Map<String, dynamic>> import({int transportAttempts = 2}) async {
    final snapshot = await createOrLoadSnapshot();
    await api.requireCapability();
    final previewResult = await api.preview(snapshot);
    if (previewResult['can_import'] != true) {
      await _writeState({
        'migration_version': migrationVersion,
        'snapshot_id': snapshot['snapshot_id'],
        'snapshot_hash': snapshot['snapshot_hash'],
        'status': 'preview_failed',
        'source_retained': true,
        'preview': previewResult,
      });
      throw const HistoryMigrationException('历史聊天预演未通过，正式迁移已停止');
    }
    await _writeState({
      'migration_version': migrationVersion,
      'snapshot_id': snapshot['snapshot_id'],
      'snapshot_hash': snapshot['snapshot_hash'],
      'status': 'importing',
      'source_retained': true,
      'preview': previewResult,
    });

    Object? lastError;
    final attempts = transportAttempts < 1 ? 1 : transportAttempts;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final result = await api.importSnapshot(snapshot);
        await _writeState({
          'migration_version': migrationVersion,
          'snapshot_id': snapshot['snapshot_id'],
          'snapshot_hash': snapshot['snapshot_hash'],
          'status': 'complete',
          'source_retained': true,
          'preview': previewResult,
          'report': result,
        });
        return result;
      } on HistoryMigrationException catch (error) {
        lastError = error;
        if (error.statusCode != null || attempt + 1 >= attempts) rethrow;
      } on IOException catch (error) {
        lastError = error;
        if (attempt + 1 >= attempts) rethrow;
      } on TimeoutException catch (error) {
        lastError = error;
        if (attempt + 1 >= attempts) rethrow;
      } on http.ClientException catch (error) {
        lastError = error;
        if (attempt + 1 >= attempts) rethrow;
      }
    }
    throw HistoryMigrationException(lastError?.toString() ?? '历史聊天迁移失败');
  }

  Future<Map<String, dynamic>> resume() async {
    final snapshot = await createOrLoadSnapshot();
    await api.requireCapability();
    final remote = await api.status(snapshot['snapshot_id'].toString());
    final report = remote?['report'];
    if (remote?['status'] == 'complete' && report is Map) {
      final normalized = report.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      await _writeState({
        'migration_version': migrationVersion,
        'snapshot_id': snapshot['snapshot_id'],
        'snapshot_hash': snapshot['snapshot_hash'],
        'status': 'complete',
        'source_retained': true,
        'report': normalized,
      });
      return normalized;
    }
    return import();
  }

  Future<Map<String, dynamic>?> loadState() async =>
      _readJson(await _stateFile());

  Future<String> readableReport() async {
    final state = await loadState();
    final report = state?['report'];
    final previewResult = state?['preview'];
    final data = report is Map
        ? report
        : previewResult is Map
        ? previewResult
        : null;
    if (data == null) return '尚无历史聊天迁移报告';
    String value(String key, [Object? fallback = 0]) =>
        (data[key] ?? fallback).toString();
    return [
      '源快照：${value('snapshot_hash', '')}',
      '窗口：${value('window_count')}（归档 ${value('archive_window_count')} / 当前 ${value('active_window_count')}）',
      '消息：${value('message_count')}（复用 ${value('reused_event_count')} / 新增 ${value('new_event_count')} / 冲突 ${value('conflict_count')}）',
      '异常：${value('anomaly_count')}，警告：${value('warning_count')}',
      '状态：${state?['status'] ?? 'unknown'}',
      '回滚源：手机 ChatStore / ArchivedChat 仍保留',
    ].join('\n');
  }

  Map<String, dynamic> _archiveWindow(ArchivedChat archive, int ordinal) {
    final sourceId = 'legacy-archive:${archive.id}';
    return {
      'source_id': sourceId,
      'kind': 'archive',
      'ordinal': ordinal,
      'legacy_archive_id': archive.id,
      'title': archive.title,
      'opened_at': _openedAt(archive.messages, archive.archivedAt),
      'closed_at': archive.archivedAt.toIso8601String(),
      if ((archive.folderId ?? '').isNotEmpty ||
          (archive.folderName ?? '').isNotEmpty)
        'legacy_metadata': {
          if ((archive.folderId ?? '').isNotEmpty) 'folderId': archive.folderId,
          if ((archive.folderName ?? '').isNotEmpty)
            'folderName': archive.folderName,
        },
      'messages': [
        for (var index = 0; index < archive.messages.length; index++)
          _message(
            archive.messages[index],
            '$sourceId:message:${index + 1}',
            index + 1,
          ),
      ],
    };
  }

  Map<String, dynamic> _activeWindow(
    List<ChatMessage> messages,
    int ordinal,
    String createdAt,
  ) {
    const sourceId = 'legacy-current-v1';
    return {
      'source_id': sourceId,
      'kind': 'active',
      'ordinal': ordinal,
      'legacy_archive_id': null,
      'title': '',
      'opened_at': _openedAt(messages, DateTime.parse(createdAt)),
      'closed_at': null,
      'messages': [
        for (var index = 0; index < messages.length; index++)
          _message(
            messages[index],
            '$sourceId:message:${index + 1}',
            index + 1,
          ),
      ],
    };
  }

  String _openedAt(List<ChatMessage> messages, DateTime fallback) {
    if (messages.isEmpty) return fallback.toIso8601String();
    return messages
        .map((message) => message.time)
        .reduce((a, b) => a.isBefore(b) ? a : b)
        .toIso8601String();
  }

  Map<String, dynamic> _message(
    ChatMessage message,
    String sourceId,
    int ordinal,
  ) => {
    'source_id': sourceId,
    'ordinal': ordinal,
    'role': message.role,
    'content': message.content,
    'created_at': message.time.toIso8601String(),
    'raw_event_id': message.rawEventId,
    'parts': message.parts.map((part) => part.toJson()).toList(),
    'attachments': _attachments(message),
    'legacy_metadata': {
      if (message.reasoning.isNotEmpty) 'reasoning': message.reasoning,
      if (message.reasonings.isNotEmpty) 'reasonings': message.reasonings,
      if (message.toolDoneRounds.isNotEmpty)
        'toolDoneRounds': message.toolDoneRounds,
      if ((message.eventId ?? '').isNotEmpty) 'eventId': message.eventId,
      if ((message.clientEventId ?? '').isNotEmpty)
        'clientEventId': message.clientEventId,
      if ((message.generationId ?? '').isNotEmpty)
        'generationId': message.generationId,
      if ((message.epochId ?? '').isNotEmpty) 'epochId': message.epochId,
      if ((message.kind ?? '').isNotEmpty) 'kind': message.kind,
      if (message.runtimeSeq != null) 'runtimeSeq': message.runtimeSeq,
      if ((message.runtimeStatus ?? '').isNotEmpty)
        'runtimeStatus': message.runtimeStatus,
      if ((message.ocrText ?? '').isNotEmpty) 'ocrText': message.ocrText,
      if (message.imageOcrTexts.isNotEmpty)
        'imageOcrTexts': message.imageOcrTexts,
      if ((message.fileExtractedText ?? '').isNotEmpty)
        'fileExtractedText': message.fileExtractedText,
      if (message.searchDone) 'searchDone': true,
      if (message.searchResults.isNotEmpty)
        'searchResults': message.searchResults
            .map((result) => result.toJson())
            .toList(),
      if (message.sendFailed) 'sendFailed': true,
      if ((message.sendError ?? '').isNotEmpty) 'sendError': message.sendError,
      if (message.usage != null) 'usage': message.usage!.toJson(),
    },
  };

  List<Map<String, dynamic>> _attachments(ChatMessage message) => [
    if ((message.imageUrl ?? '').isNotEmpty)
      _attachment('image', message.imageUrl!),
    for (final imageUrl in message.imageUrls) _attachment('image', imageUrl),
    if ((message.fileUrl ?? '').isNotEmpty)
      {
        ..._attachment('file', message.fileUrl!),
        if ((message.fileName ?? '').isNotEmpty) 'name': message.fileName,
        if (message.fileSize != null) 'size': message.fileSize,
        if ((message.fileType ?? '').isNotEmpty) 'media_type': message.fileType,
      },
  ];

  Map<String, dynamic> _attachment(String kind, String locator) {
    final uri = Uri.tryParse(locator);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return {
        'kind': kind,
        'locator_type': 'remote_url',
        'resource_url': locator,
      };
    }
    if (locator.startsWith('/') ||
        locator.startsWith('file://') ||
        locator.startsWith('content://')) {
      return {
        'kind': kind,
        'locator_type': 'local_private',
        'local_private_path': locator,
      };
    }
    return {
      'kind': kind,
      'locator_type': 'metadata_only',
      'legacy_locator': locator,
    };
  }

  Future<File> _snapshotFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$snapshotFileName');
  }

  Future<File> _stateFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$stateFileName');
  }

  Future<void> _writeState(Map<String, dynamic> state) async {
    await _writeJsonAtomic(await _stateFile(), state);
  }

  Future<Map<String, dynamic>?> _readJson(File file) async {
    final candidate = await file.exists() ? file : File('${file.path}.tmp');
    if (!await candidate.exists()) return null;
    try {
      final decoded = jsonDecode(await candidate.readAsString());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _writeJsonAtomic(File file, Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

String _canonicalJson(Object? value) {
  Object? normalize(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(item[key])};
    }
    if (item is List) return item.map(normalize).toList();
    return item;
  }

  return jsonEncode(normalize(value));
}
