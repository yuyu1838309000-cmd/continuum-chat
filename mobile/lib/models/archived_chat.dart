import 'message.dart';

const int _summaryTitleMaxCharacters = 48;

/// 归档会话：每次"开始新对话"重置时，把当前窗口快照存成一条带时间戳的记录。
/// 结构参考 Operit 的 OperitArchivedChat（id / title / messages / createdAt），
/// 咱们简化成 id（归档时间戳）+ title（带时间）+ messages（完整消息）。
/// 归档只进手机本地（shared_preferences），不删历史，搜索/日历能查到。
/// v0.2.161 加可选 folderId/folderName：空 = 未分类，兼容旧数据（缺字段不崩）。
class ArchivedChat {
  final String id;
  final DateTime archivedAt;
  final String title;
  final List<ChatMessage> messages;
  final String? folderId;
  final String? folderName;

  ArchivedChat({
    required this.id,
    required this.archivedAt,
    required this.title,
    required this.messages,
    this.folderId,
    this.folderName,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'archivedAt': archivedAt.toIso8601String(),
    'title': title,
    if (folderId != null && folderId!.isNotEmpty) 'folderId': folderId,
    if (folderName != null && folderName!.isNotEmpty) 'folderName': folderName,
    'messages': messages
        .map(
          (m) => {
            'role': m.role,
            'content': m.content,
            'time': m.time.toIso8601String(),
            if (m.reasoning.isNotEmpty) 'reasoning': m.reasoning,
            if (m.reasonings.isNotEmpty) 'reasonings': m.reasonings,
            if (m.toolDoneRounds.isNotEmpty) 'toolDoneRounds': m.toolDoneRounds,
            if (m.rawEventId != null) 'rawEventId': m.rawEventId,
            if ((m.eventId ?? '').isNotEmpty) 'eventId': m.eventId,
            if ((m.clientEventId ?? '').isNotEmpty)
              'clientEventId': m.clientEventId,
            if ((m.generationId ?? '').isNotEmpty)
              'generationId': m.generationId,
            if ((m.epochId ?? '').isNotEmpty) 'epochId': m.epochId,
            if ((m.kind ?? '').isNotEmpty) 'kind': m.kind,
            if (m.runtimeSeq != null) 'runtimeSeq': m.runtimeSeq,
            if ((m.runtimeStatus ?? '').isNotEmpty)
              'runtimeStatus': m.runtimeStatus,
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
            if (m.parts.isNotEmpty)
              'parts': m.parts.map((e) => e.toJson()).toList(),
            if (m.usage != null) 'usage': m.usage!.toJson(),
            if (m.sendFailed) 'sendFailed': m.sendFailed,
            if (m.sendError != null) 'sendError': m.sendError,
          },
        )
        .toList(),
  };

  factory ArchivedChat.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'] as List<dynamic>? ?? [];
    return ArchivedChat(
      id: json['id'] as String? ?? '',
      archivedAt:
          DateTime.tryParse(json['archivedAt'] as String? ?? '') ??
          DateTime.now(),
      title: json['title'] as String? ?? '归档会话',
      folderId: json['folderId'] as String?,
      folderName: json['folderName'] as String?,
      messages: rawMessages.map((e) {
        final map = e as Map<String, dynamic>;
        return ChatMessage(
          role: map['role'] as String? ?? 'user',
          content: map['content'] as String? ?? '',
          reasoning: map['reasoning'] as String? ?? '',
          reasonings: (map['reasonings'] as List<dynamic>? ?? [])
              .whereType<String>()
              .toList(),
          toolDoneRounds: (map['toolDoneRounds'] as List<dynamic>? ?? [])
              .whereType<num>()
              .map((e) => e.toInt())
              .toList(),
          time:
              DateTime.tryParse(map['time'] as String? ?? '') ?? DateTime.now(),
          rawEventId: (map['rawEventId'] as num?)?.toInt(),
          eventId: map['eventId']?.toString(),
          clientEventId: map['clientEventId']?.toString(),
          generationId: map['generationId']?.toString(),
          epochId: map['epochId']?.toString(),
          kind: map['kind']?.toString(),
          runtimeSeq: (map['runtimeSeq'] as num?)?.toInt(),
          runtimeStatus: map['runtimeStatus']?.toString(),
          imageUrl: map['imageUrl'] as String?,
          ocrText: map['ocrText'] as String?,
          imageUrls: (map['imageUrls'] as List<dynamic>? ?? [])
              .whereType<String>()
              .toList(),
          imageOcrTexts: (map['imageOcrTexts'] as List<dynamic>? ?? [])
              .whereType<String>()
              .toList(),
          fileUrl: map['fileUrl'] as String?,
          fileName: map['fileName'] as String?,
          fileSize: map['fileSize'] as int?,
          fileType: map['fileType'] as String?,
          fileExtractedText: map['fileExtractedText'] as String?,
          parts: (map['parts'] as List<dynamic>? ?? [])
              .whereType<Map>()
              .map(
                (e) => ChatMessagePart.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList(),
          usage: map['usage'] is Map
              ? MessageUsage.fromJson(
                  (map['usage'] as Map).map(
                    (key, value) => MapEntry(key.toString(), value),
                  ),
                )
              : null,
          sendFailed: map['sendFailed'] as bool? ?? false,
          sendError: map['sendError'] as String?,
        );
      }).toList(),
    );
  }

  /// 换/清空文件夹（folderId 传 null = 移回未分类），返回新实例。
  ArchivedChat withFolder(String? folderId, String? folderName) => ArchivedChat(
    id: id,
    archivedAt: archivedAt,
    title: title,
    messages: messages,
    folderId: folderId,
    folderName: folderName,
  );
}

/// 历史列表用轻量摘要：不持有 messages，避免进列表时反序列化所有正文。
class ArchivedChatSummary {
  final String id;
  final String title;
  final DateTime archivedAt;
  final String? folderId;
  final String? folderName;
  final int messageCount;

  const ArchivedChatSummary({
    required this.id,
    required this.title,
    required this.archivedAt,
    required this.messageCount,
    this.folderId,
    this.folderName,
  });

  factory ArchivedChatSummary.fromArchive(ArchivedChat chat) =>
      ArchivedChatSummary(
        id: chat.id,
        title: _summaryTitleFor(chat),
        archivedAt: chat.archivedAt,
        folderId: chat.folderId,
        folderName: chat.folderName,
        messageCount: chat.messages.length,
      );

  factory ArchivedChatSummary.fromJson(Map<String, dynamic> json) =>
      ArchivedChatSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '历史片段',
        archivedAt:
            DateTime.tryParse(json['archivedAt'] as String? ?? '') ??
            DateTime.now(),
        folderId: json['folderId'] as String?,
        folderName: json['folderName'] as String?,
        messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'archivedAt': archivedAt.toIso8601String(),
    if (folderId != null && folderId!.isNotEmpty) 'folderId': folderId,
    if (folderName != null && folderName!.isNotEmpty) 'folderName': folderName,
    'messageCount': messageCount,
  };

  ArchivedChatSummary withFolder(String? folderId, String? folderName) =>
      ArchivedChatSummary(
        id: id,
        title: title,
        archivedAt: archivedAt,
        messageCount: messageCount,
        folderId: folderId,
        folderName: folderName,
      );
}

String _summaryTitleFor(ArchivedChat chat) {
  final body = _firstEffectiveArchiveBody(chat);
  if (body != null) return _truncateSummaryTitle(body);
  final fallback = _normalizeArchivePreviewText(chat.title);
  final title = fallback.isEmpty ? '历史片段' : fallback;
  return _truncateSummaryTitle(title);
}

String? _firstEffectiveArchiveBody(ArchivedChat chat) {
  for (final message in chat.messages) {
    final body = _effectiveMessageBody(message);
    if (body != null) return body;
  }
  return null;
}

String? _effectiveMessageBody(ChatMessage message) {
  if (message.isActivity || message.isToolDone) return null;

  final content = _normalizeArchivePreviewText(message.content);
  if (content.isNotEmpty) return content;

  for (final part in message.parts) {
    if (part.type != ChatMessagePartType.text) continue;
    final text = _normalizeArchivePreviewText(part.text);
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _normalizeArchivePreviewText(String raw) {
  final text = raw
      .replaceAll('\u200b', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text == '[图片]' || text == '[文件]') return '';
  return text;
}

String _truncateSummaryTitle(String text) {
  final runes = text.runes.toList(growable: false);
  if (runes.length <= _summaryTitleMaxCharacters) return text;
  return '${String.fromCharCodes(runes.take(_summaryTitleMaxCharacters)).trimRight()}...';
}
