import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/archived_chat.dart';
import '../models/archive_folder.dart';
import '../models/message.dart';

List<ArchivedChat> _decodeArchivedChatList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return decoded
      .whereType<Map>()
      .map(
        (entry) => ArchivedChat.fromJson(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        ),
      )
      .toList();
}

List<ArchivedChatSummary> _decodeArchiveSummaryList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) {
    throw const FormatException('Archive index must be a list');
  }
  return [
    for (final entry in decoded)
      if (entry is Map)
        ArchivedChatSummary.fromJson(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        )
      else
        throw const FormatException('Archive index item must be a map'),
  ];
}

ArchivedChat? _decodeArchivedChatRecord(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return null;
  return ArchivedChat.fromJson(
    decoded.map((key, value) => MapEntry(key.toString(), value)),
  );
}

List<ChatMessage> _decodeCurrentChatList(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return decoded.whereType<Map>().map((entry) {
    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    return ChatMessage(
      role: map['role'] as String? ?? 'user',
      content: map['content'] as String? ?? '',
      reasoning: map['reasoning'] as String? ?? '',
      reasonings: (map['reasonings'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      toolDoneRounds: (map['toolDoneRounds'] as List<dynamic>? ?? const [])
          .whereType<num>()
          .map((e) => e.toInt())
          .toList(),
      time: DateTime.tryParse(map['time'] as String? ?? '') ?? DateTime.now(),
      rawEventId: (map['rawEventId'] as num?)?.toInt(),
      eventId: map['eventId'] as String?,
      clientEventId: map['clientEventId'] as String?,
      generationId: map['generationId'] as String?,
      epochId: map['epochId'] as String?,
      kind: map['kind'] as String?,
      runtimeSeq: (map['runtimeSeq'] as num?)?.toInt(),
      runtimeStatus: map['runtimeStatus'] as String?,
      imageUrl: map['imageUrl'] as String?,
      ocrText: map['ocrText'] as String?,
      imageUrls: (map['imageUrls'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      imageOcrTexts: (map['imageOcrTexts'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      fileUrl: map['fileUrl'] as String?,
      fileName: map['fileName'] as String?,
      fileSize: (map['fileSize'] as num?)?.toInt(),
      fileType: map['fileType'] as String?,
      fileExtractedText: map['fileExtractedText'] as String?,
      searchDone: map['searchDone'] as bool? ?? false,
      searchResults: (map['searchResults'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (entry) => SearchResult.fromJson(
              entry.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(),
      parts: (map['parts'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (entry) => ChatMessagePart.fromJson(
              entry.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(),
      sendFailed: map['sendFailed'] as bool? ?? false,
      sendError: map['sendError'] as String?,
      usage: map['usage'] is Map
          ? MessageUsage.fromJson(
              (map['usage'] as Map).map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            )
          : null,
    );
  }).toList();
}

Map<String, Object?> _buildArchiveFastStoreData(String raw) {
  final archives = _decodeArchivedChatList(raw);
  final summaries = [
    for (final archive in archives) ArchivedChatSummary.fromArchive(archive),
  ];
  return {
    'indexJson': jsonEncode([
      for (final summary in summaries) summary.toJson(),
    ]),
    'summaries': [for (final summary in summaries) summary.toJson()],
    'bodyJsonById': <String, String>{
      for (final archive in archives) archive.id: jsonEncode(archive.toJson()),
    },
  };
}

/// 聊天消息本地持久化（v2：SharedPreferences → documents 本地文件）。
/// - 当前窗口存 chat.json，归档列表存 archives.json（documents 目录）
/// - 迁移：读取时检测文件不存在 → 从 SharedPreferences 读一次，先备份原始 JSON
///   到 `<key>.backup.json` 再写主文件；迁移后 prefs 旧值保留不删（双重保险）
/// - SharedPreferences 存大列表慢、容量受限，文件读写快、容量大，历史消息秒显
class ChatStore {
  static const String _key = 'chat_messages_v1';
  static const String _archivesKey = 'chat_archives_v1';
  static const String _file = 'chat.json';
  static const String _archivesFileName = 'archives.json';
  static const String _archiveIndexFileName = 'archive_index.json';
  static const String _archiveBodiesDirName = 'archive_bodies';
  static const String _foldersFileName = 'archive_folders.json';
  static const String _archiveTransitionFileName =
      'chat_archive_transition_v1.json';
  static Future<void> _historyChain = Future<void>.value();

  /// 仅测试用：统计 [save] 实际被调用次数，用于验证流式节流后的真实写盘频率。
  @visibleForTesting
  static int saveCallCount = 0;

  static Future<T> _withHistoryLock<T>(Future<T> Function() action) {
    final result = _historyChain.then((_) => action());
    _historyChain = result
        .then<void>((_) {})
        .catchError((Object _, StackTrace _) {});
    return result;
  }

  static Future<File> _chatFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_file');
  }

  static Future<File> _archivesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_archivesFileName');
  }

  static Future<File> _foldersFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_foldersFileName');
  }

  static Future<File> _archiveIndexFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_archiveIndexFileName');
  }

  static Future<File> _archiveTransitionFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_archiveTransitionFileName');
  }

  static Future<Directory> _archiveBodiesDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/$_archiveBodiesDirName');
  }

  static Future<File> _archiveBodyFile(String id) async {
    final dir = await _archiveBodiesDir();
    return File('${dir.path}/${_archiveBodyFileName(id)}');
  }

  static String _archiveBodyFileName(String id) =>
      '${Uri.encodeComponent(id)}.json';

  static Future<void> _writeArchiveBody(ArchivedChat archive) async {
    final file = await _archiveBodyFile(archive.id);
    await _replaceFileWithString(file, jsonEncode(archive.toJson()));
  }

  static Future<void> _replaceFileWithString(File file, String content) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      // Android/Linux replaces atomically above; this is a non-POSIX fallback.
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }
  }

  static Future<void> _invalidateArchiveIndex() async {
    try {
      final indexFile = await _archiveIndexFile();
      if (await indexFile.exists()) {
        await indexFile.delete();
      }
    } catch (_) {
      // best-effort invalidation; canonical archives.json remains untouched.
    }
  }

  /// archives.json 仍是兼容/回滚源；index + bodies 只是可重建的快速读取层。
  static Future<List<ArchivedChatSummary>> _syncArchiveFastStoreFromRaw(
    String raw,
  ) async {
    final data = await Isolate.run(() => _buildArchiveFastStoreData(raw));
    await _writeArchiveFastStoreData(data);
    return _summariesFromFastStoreData(data);
  }

  static Future<void> _writeArchiveFastStoreData(
    Map<String, Object?> data,
  ) async {
    try {
      await _invalidateArchiveIndex();
      final bodyDir = await _archiveBodiesDir();
      await bodyDir.create(recursive: true);

      final bodyJsonById = data['bodyJsonById'];
      if (bodyJsonById is! Map) {
        throw const FormatException('Archive body data must be a map');
      }

      final liveNames = <String>{};
      for (final entry in bodyJsonById.entries) {
        final id = entry.key.toString();
        final bodyJson = entry.value;
        if (bodyJson is! String) {
          throw const FormatException('Archive body json must be a string');
        }
        final fileName = _archiveBodyFileName(id);
        liveNames.add(fileName);
        final bodyFile = File('${bodyDir.path}/$fileName');
        // 已归档正文是不可变快照；移动文件夹等只改 index，不重复重写旧 body。
        if (!await bodyFile.exists()) {
          await _replaceFileWithString(bodyFile, bodyJson);
        }
      }

      await for (final entity in bodyDir.list()) {
        if (entity is File &&
            entity.path.endsWith('.json') &&
            !liveNames.contains(entity.uri.pathSegments.last)) {
          await entity.delete();
        }
      }

      final indexJson = data['indexJson'];
      if (indexJson is! String) {
        throw const FormatException('Archive index json must be a string');
      }
      final indexFile = await _archiveIndexFile();
      // 索引最后写：body 全部完成后才暴露新快速层。
      await _replaceFileWithString(indexFile, indexJson);
    } catch (_) {
      await _invalidateArchiveIndex();
      rethrow;
    }
  }

  static List<ArchivedChatSummary> _summariesFromFastStoreData(
    Map<String, Object?> data,
  ) {
    final raw = data['summaries'];
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          ArchivedChatSummary.fromJson(
            entry.map((key, value) => MapEntry(key.toString(), value)),
          ),
    ];
  }

  static Future<String?> _readFileOrNull(File f) async {
    try {
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 迁移：prefs 旧数据 → 先备份原始 JSON 到 `<key>.backup.json`，再写主文件。
  /// 迁移后 prefs 旧值保留不删（文件损坏时可从备份/prefs 找回）。
  static Future<void> _migrateFromPrefs(String prefsKey, File file) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return;
      final dir = await getApplicationDocumentsDirectory();
      await dir.create(recursive: true);
      // 先备份再动
      final bak = File('${dir.path}/$prefsKey.backup.json');
      if (!await bak.exists()) {
        await bak.writeAsString(raw, flush: true);
      }
      await file.writeAsString(raw, flush: true);
    } catch (_) {
      // 迁移失败不致命，下次再迁
    }
  }

  /// 启动动画期间预加载缓存：SplashPage 动效播放时并行读好，进聊天界面秒显。
  static List<ChatMessage>? cache;
  static Future<List<ChatMessage>>? _warmUpFuture;

  /// 启动预热：全 App 只允许一份 current-chat 读取/解析任务。Splash、
  /// Runtime supervisor、ChatPage 会同时启动，不能各自再解一遍长聊天。
  static Future<List<ChatMessage>> warmUp() {
    final ready = cache;
    if (ready != null) return Future.value(ready);
    final active = _warmUpFuture;
    if (active != null) return active;

    late final Future<List<ChatMessage>> operation;
    operation = load()
        .then((loaded) {
          cache = loaded;
          return loaded;
        })
        .whenComplete(() {
          if (identical(_warmUpFuture, operation)) _warmUpFuture = null;
        });
    _warmUpFuture = operation;
    return operation;
  }

  static Future<String?> _readArchivesRaw() async {
    final file = await _archivesFile();
    var raw = await _readFileOrNull(file);
    if (raw == null) {
      await _migrateFromPrefs(_archivesKey, file);
      raw = await _readFileOrNull(file);
    }
    return raw;
  }

  /// 读取当前窗口历史消息。文件优先，无文件走迁移（prefs 旧数据）。
  /// 解析失败/无数据返回空列表，不抛异常。
  static Future<List<ChatMessage>> load() async {
    try {
      await _recoverArchiveTransitionIfNeeded();
      final file = await _chatFile();
      var raw = await _readFileOrNull(file);
      if (raw == null) {
        await _migrateFromPrefs(_key, file);
        raw = await _readFileOrNull(file);
      }
      if (raw == null || raw.isEmpty) return [];
      final payload = raw;
      // Long sessions can contain thousands of messages plus reasoning/tool parts.
      // JSON decode + model construction must not run on the UI isolate during
      // splash/cold start. Archive loading already follows the same pattern.
      return await Isolate.run(() => _decodeCurrentChatList(payload));
    } catch (_) {
      return [];
    }
  }

  /// 把当前窗口消息整体序列化写入文件。失败静默，不让 App 崩。
  static Future<void> save(List<ChatMessage> messages) {
    saveCallCount += 1;
    // Freeze the serialized payload at save-call time. ChatMessage is mutable,
    // so a shallow List copy is not a real checkpoint snapshot.
    final encoded = _encodeMessages(messages);
    final write = _withHistoryLock(() => _writeEncodedMessages(encoded));
    return write;
  }

  /// 冻结迁移源时与 current/archive 写入互斥，避免“归档已追加、current 尚未清空”
  /// 这类跨文件撕裂快照。返回的是模型副本；不会改写任何原始历史文件。
  static Future<({List<ArchivedChat> archives, List<ChatMessage> current})>
  loadMigrationSourceSnapshot() => _withHistoryLock(() async {
    final archives = await loadArchives();
    final current = await load();
    return (archives: archives, current: current);
  });

  static String _encodeMessages(List<ChatMessage> messages) {
    final data = messages
        .where((m) => m.imageSendStatus == null && m.fileSendStatus == null)
        .map(
          (m) => {
            'role': m.role,
            'content': m.content,
            'time': m.time.toIso8601String(),
            if (m.reasoning.isNotEmpty) 'reasoning': m.reasoning,
            if (m.reasonings.isNotEmpty) 'reasonings': m.reasonings,
            if (m.toolDoneRounds.isNotEmpty) 'toolDoneRounds': m.toolDoneRounds,
            if (m.rawEventId != null) 'rawEventId': m.rawEventId,
            if (m.eventId != null) 'eventId': m.eventId,
            if (m.clientEventId != null) 'clientEventId': m.clientEventId,
            if (m.generationId != null) 'generationId': m.generationId,
            if (m.epochId != null) 'epochId': m.epochId,
            if (m.kind != null) 'kind': m.kind,
            if (m.runtimeSeq != null) 'runtimeSeq': m.runtimeSeq,
            if (m.runtimeStatus != null) 'runtimeStatus': m.runtimeStatus,
            if (m.imageUrl != null) 'imageUrl': m.imageUrl,
            if (m.ocrText != null) 'ocrText': m.ocrText,
            if (m.imageUrls.isNotEmpty) 'imageUrls': m.imageUrls,
            if (m.imageOcrTexts.isNotEmpty) 'imageOcrTexts': m.imageOcrTexts,
            if (m.fileUrl != null) 'fileUrl': m.fileUrl,
            if (m.fileName != null) 'fileName': m.fileName,
            if (m.fileSize != null) 'fileSize': m.fileSize,
            if (m.fileType != null) 'fileType': m.fileType,
            if (m.fileExtractedText != null)
              'fileExtractedText': m.fileExtractedText,
            if (m.searchDone) 'searchDone': m.searchDone,
            if (m.searchResults.isNotEmpty)
              'searchResults': m.searchResults.map((e) => e.toJson()).toList(),
            if (m.parts.isNotEmpty)
              'parts': m.parts.map((e) => e.toJson()).toList(),
            if (m.sendFailed) 'sendFailed': m.sendFailed,
            if (m.sendError != null) 'sendError': m.sendError,
            if (m.usage != null) 'usage': m.usage!.toJson(),
          },
        )
        .toList();
    return jsonEncode(data);
  }

  static Future<void> _writeEncodedMessages(
    String encoded, {
    bool strict = false,
  }) async {
    try {
      final file = await _chatFile();
      await file.parent.create(recursive: true);
      await _replaceFileWithString(file, encoded);
    } catch (_) {
      if (strict) rethrow;
      // 落盘失败不致命，下次还有机会
    }
  }

  static Future<void> _writeMessages(
    List<ChatMessage> messages, {
    bool strict = false,
  }) => _writeEncodedMessages(_encodeMessages(messages), strict: strict);

  /// 读取完整归档列表。Search/Calendar 等需要全量正文的旧调用继续走这里；
  /// JSON + ChatMessage 构造放到 worker isolate，避免大文件解析直接卡 UI isolate。
  static Future<List<ArchivedChat>> loadArchives() async {
    try {
      final raw = await _readArchivesRaw();
      if (raw == null || raw.isEmpty) return [];
      return await Isolate.run(() => _decodeArchivedChatList(raw));
    } catch (_) {
      return [];
    }
  }

  /// 历史列表专用：只读取轻量 index，不构造任何 ChatMessage。
  /// 首次升级或 index 损坏时从旧 archives.json 一次性重建；旧文件永久保留作回滚源。
  static Future<List<ArchivedChatSummary>> loadArchiveSummaries() async {
    try {
      final indexFile = await _archiveIndexFile();
      final raw = await _readFileOrNull(indexFile);
      if (raw != null && raw.isNotEmpty) {
        return await Isolate.run(() => _decodeArchiveSummaryList(raw));
      }
    } catch (_) {
      await _invalidateArchiveIndex();
    }

    try {
      final raw = await _readArchivesRaw();
      if (raw == null || raw.isEmpty) {
        return await _syncArchiveFastStoreFromRaw('[]');
      }
      return await _syncArchiveFastStoreFromRaw(raw);
    } catch (_) {
      await _invalidateArchiveIndex();
      return [];
    }
  }

  /// 点开单条历史时才读取对应正文文件；解析放到 worker isolate。
  /// body 缺失/损坏时从 canonical archives.json 找回并修复派生文件。
  static Future<ArchivedChat?> loadArchiveById(String id) async {
    try {
      final bodyFile = await _archiveBodyFile(id);
      final raw = await _readFileOrNull(bodyFile);
      if (raw != null && raw.isNotEmpty) {
        final archive = await Isolate.run(() => _decodeArchivedChatRecord(raw));
        if (archive != null && archive.id == id) return archive;
      }
    } catch (_) {
      // 继续走 canonical fallback。
    }

    final archives = await loadArchives();
    for (final archive in archives) {
      if (archive.id != id) continue;
      try {
        await _writeArchiveBody(archive);
      } catch (_) {}
      return archive;
    }
    return null;
  }

  /// 把整个归档列表写回 canonical 文件，同时刷新可重建的 index/body 快速层。
  static Future<void> saveArchives(List<ArchivedChat> archives) async {
    final snapshot = List<ArchivedChat>.from(archives);
    await _withHistoryLock(() => _writeArchives(snapshot));
  }

  static Future<void> _writeArchives(
    List<ArchivedChat> archives, {
    bool strict = false,
  }) async {
    try {
      final file = await _archivesFile();
      await file.parent.create(recursive: true);
      final raw = jsonEncode(archives.map((a) => a.toJson()).toList());
      await _replaceFileWithString(file, raw);
      try {
        await _syncArchiveFastStoreFromRaw(raw);
      } catch (_) {
        await _invalidateArchiveIndex();
      }
    } catch (_) {
      if (strict) rethrow;
      // 归档落盘失败不致命
    }
  }

  /// 删除一条归档会话（按 id 精确删，本地移除）。返回删除后的归档列表，失败返回 null。
  static Future<List<ArchivedChat>?> deleteArchive(String id) async {
    try {
      final archives = await loadArchives();
      archives.removeWhere((a) => a.id == id);
      await saveArchives(archives);
      return archives;
    } catch (_) {
      return null;
    }
  }

  /// 把当前窗口消息归档成一条新会话（追加到归档列表末尾）并落盘。
  /// [folderId]/[folderName] 空 = 未分类（旧行为）。
  /// 返回新的归档列表，失败返回 null。
  static Future<List<ArchivedChat>?> archiveMessages(
    List<ChatMessage> messages, {
    String? folderId,
    String? folderName,
  }) async {
    return _withHistoryLock(() async {
      try {
        final archives = await loadArchives();
        final chat = _newArchive(
          messages,
          folderId: folderId,
          folderName: folderName,
        );
        archives.add(chat);
        await _writeArchives(archives);
        return archives;
      } catch (_) {
        return null;
      }
    });
  }

  /// “开始新对话”的本地原子边界：先把旧窗口追加进 canonical archives，
  /// 同一历史锁内再把 current 落盘为空。迁移快照只能看到操作前或操作后。
  static Future<List<ArchivedChat>?> archiveMessagesAndClearCurrent(
    List<ChatMessage> messages, {
    String? folderId,
    String? folderName,
  }) => _withHistoryLock(() async {
    try {
      final archives = await loadArchives();
      final archive = _newArchive(
        messages,
        folderId: folderId,
        folderName: folderName,
      );
      archives.add(archive);
      final transitionFile = await _archiveTransitionFile();
      await _replaceFileWithString(
        transitionFile,
        jsonEncode({'archiveId': archive.id, 'archive': archive.toJson()}),
      );
      await _writeArchives(archives, strict: true);
      await _writeMessages(const [], strict: true);
      if (await transitionFile.exists()) await transitionFile.delete();
      return archives;
    } catch (_) {
      return null;
    }
  });

  static Future<void> _recoverArchiveTransitionIfNeeded() async {
    try {
      final transitionFile = await _archiveTransitionFile();
      final transitionRaw = await _readFileOrNull(transitionFile);
      if (transitionRaw == null || transitionRaw.isEmpty) return;
      final transition = jsonDecode(transitionRaw);
      final archiveId = transition is Map
          ? transition['archiveId']?.toString()
          : null;
      final expectedArchive = transition is Map ? transition['archive'] : null;
      if (archiveId == null || archiveId.isEmpty) return;
      final archivesRaw = await _readFileOrNull(await _archivesFile());
      if (archivesRaw == null) {
        await transitionFile.delete();
        return;
      }
      final archives = _decodeArchivedChatList(archivesRaw);
      if (archives.any(
        (archive) =>
            archive.id == archiveId &&
            expectedArchive is Map &&
            jsonEncode(archive.toJson()) == jsonEncode(expectedArchive),
      )) {
        await _replaceFileWithString(await _chatFile(), '[]');
      }
      if (await transitionFile.exists()) await transitionFile.delete();
    } catch (_) {
      // Keep current history and the marker so the next load can retry safely.
    }
  }

  static ArchivedChat _newArchive(
    List<ChatMessage> messages, {
    String? folderId,
    String? folderName,
  }) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return ArchivedChat(
      id: now.millisecondsSinceEpoch.toString(),
      archivedAt: now,
      title:
          '会话 ${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}',
      messages: List.of(messages),
      folderId: (folderId == null || folderId.isEmpty) ? null : folderId,
      folderName: (folderName == null || folderName.isEmpty)
          ? null
          : folderName,
    );
  }

  /// 读取归档文件夹列表。解析失败/无数据返回空列表。
  static Future<List<ArchiveFolder>> loadFolders() async {
    try {
      final file = await _foldersFile();
      final raw = await _readFileOrNull(file);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => ArchiveFolder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 把整个文件夹列表序列化写入文件。失败静默。
  static Future<void> saveFolders(List<ArchiveFolder> folders) async {
    try {
      final file = await _foldersFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(folders.map((f) => f.toJson()).toList()),
        flush: true,
      );
    } catch (_) {
      // 落盘失败不致命
    }
  }

  /// 新建文件夹（name 空则拒绝）。返回新文件夹列表，失败返回 null。
  static Future<List<ArchiveFolder>?> createFolder(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final folders = await loadFolders();
      folders.add(
        ArchiveFolder(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: trimmed,
          createdAt: DateTime.now(),
        ),
      );
      await saveFolders(folders);
      return folders;
    } catch (_) {
      return null;
    }
  }

  /// 重命名文件夹（name 空则拒绝）。返回新文件夹列表，失败返回 null。
  static Future<List<ArchiveFolder>?> renameFolder(
    String id,
    String name,
  ) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final folders = await loadFolders();
      final idx = folders.indexWhere((f) => f.id == id);
      if (idx < 0) return null;
      final old = folders[idx];
      folders[idx] = ArchiveFolder(
        id: old.id,
        name: trimmed,
        createdAt: old.createdAt,
      );
      await saveFolders(folders);
      return folders;
    } catch (_) {
      return null;
    }
  }

  /// 删除文件夹：文件夹本身删掉，里面会话移回未分类（不删会话）。
  /// 返回 (folders, archives)；archives 只有发生迁移时才非 null，失败两个都 null。
  static Future<({List<ArchiveFolder>? folders, List<ArchivedChat>? archives})>
  deleteFolder(String id) async {
    try {
      final folders = await loadFolders();
      folders.removeWhere((f) => f.id == id);
      final archives = await loadArchives();
      var moved = false;
      for (var i = 0; i < archives.length; i++) {
        if (archives[i].folderId == id) {
          archives[i] = archives[i].withFolder(null, null);
          moved = true;
        }
      }
      await saveFolders(folders);
      if (moved) await saveArchives(archives);
      return (folders: folders, archives: moved ? archives : null);
    } catch (_) {
      return (folders: null, archives: null);
    }
  }

  /// 批量把归档会话移入/移出文件夹（v0.2.161 归档页多选）。
  /// [ids] 精确匹配；[folderId] 空 = 移回未分类。一次 saveArchives。
  /// 返回更新后的归档列表，失败返回 null。
  static Future<List<ArchivedChat>?> batchMoveArchives(
    List<String> ids,
    String? folderId,
  ) async {
    if (ids.isEmpty) return null;
    try {
      final archives = await loadArchives();
      final target = (folderId == null || folderId.isEmpty) ? null : folderId;
      var targetName = '';
      if (target != null) {
        final folders = await loadFolders();
        for (final f in folders) {
          if (f.id == target) {
            targetName = f.name;
            break;
          }
        }
      }
      final idSet = ids.toSet();
      var changed = false;
      for (var i = 0; i < archives.length; i++) {
        if (idSet.contains(archives[i].id)) {
          archives[i] = archives[i].withFolder(
            target,
            targetName.isEmpty ? null : targetName,
          );
          changed = true;
        }
      }
      if (changed) await saveArchives(archives);
      return archives;
    } catch (_) {
      return null;
    }
  }
}
