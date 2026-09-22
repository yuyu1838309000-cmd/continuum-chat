import '../models/message.dart';

int? _jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _jsonTime(Object? value) =>
    DateTime.tryParse(value?.toString() ?? '');

class HistoryConversationSummary {
  const HistoryConversationSummary({
    required this.epochId,
    required this.ordinal,
    required this.status,
    required this.messageCount,
    this.title,
    this.preview,
    this.folderId,
    this.legacyArchiveId,
    this.openedAt,
    this.closedAt,
    this.lastMessageAt,
  });

  final String epochId;
  final int ordinal;
  final String status;
  final int messageCount;
  final String? title;
  final String? preview;
  final String? folderId;
  final String? legacyArchiveId;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final DateTime? lastMessageAt;

  factory HistoryConversationSummary.fromJson(Map<String, dynamic> json) {
    return HistoryConversationSummary(
      epochId: (json['epoch_id'] ?? '').toString(),
      ordinal: _jsonInt(json['ordinal']) ?? 0,
      status: (json['status'] ?? '').toString(),
      messageCount: _jsonInt(json['message_count']) ?? 0,
      title: json['title']?.toString(),
      preview: json['preview']?.toString(),
      folderId: json['folder_id']?.toString(),
      legacyArchiveId: json['legacy_archive_id']?.toString(),
      openedAt: _jsonTime(json['opened_at'] ?? json['created_at']),
      closedAt: _jsonTime(json['closed_at']),
      lastMessageAt: _jsonTime(json['last_message_at']),
    );
  }
}

class LegacyHistoryGroupSummary {
  const LegacyHistoryGroupSummary({
    required this.groupId,
    required this.bucket,
    required this.messageCount,
    required this.firstCreatedAt,
    required this.lastCreatedAt,
    this.preview,
    this.note,
  });

  final String groupId;
  final String bucket;
  final int messageCount;
  final DateTime firstCreatedAt;
  final DateTime lastCreatedAt;
  final String? preview;
  final String? note;

  factory LegacyHistoryGroupSummary.fromJson(Map<String, dynamic> json) {
    return LegacyHistoryGroupSummary(
      groupId: (json['group_id'] ?? '').toString(),
      bucket: (json['bucket'] ?? 'supplemental').toString(),
      messageCount: _jsonInt(json['message_count']) ?? 0,
      firstCreatedAt:
          _jsonTime(json['first_created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      lastCreatedAt:
          _jsonTime(json['last_created_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      preview: json['preview']?.toString(),
      note: json['note']?.toString(),
    );
  }
}

class HistorySearchHit {
  const HistorySearchHit({
    required this.message,
    required this.legacyArchive,
    this.epochId,
    this.legacyGroupId,
    this.groupBucket,
    this.attachmentContentMatch = false,
  });

  final ChatMessage message;
  final bool legacyArchive;
  final String? epochId;
  final String? legacyGroupId;
  final String? groupBucket;
  final bool attachmentContentMatch;
}

class HistoryMessagePage {
  const HistoryMessagePage({
    required this.messages,
    required this.fromCache,
    required this.hasMore,
    this.nextCursor,
    this.revision,
    this.phase = 'single',
  });

  final List<ChatMessage> messages;
  final bool fromCache;
  final bool hasMore;
  final String? nextCursor;
  final int? revision;
  final String phase;
}

class HistoryConversationPage {
  const HistoryConversationPage({
    required this.items,
    required this.fromCache,
    required this.hasMore,
    this.nextBeforeOrdinal,
    this.revision,
  });

  final List<HistoryConversationSummary> items;
  final bool fromCache;
  final bool hasMore;
  final int? nextBeforeOrdinal;
  final int? revision;
}

class HistoryTrashSnapshot {
  const HistoryTrashSnapshot({
    required this.items,
    required this.fromCache,
    this.revision,
  });

  final List<HistoryConversationSummary> items;
  final bool fromCache;
  final int? revision;
}

class LegacyHistoryGroupPage {
  const LegacyHistoryGroupPage({
    required this.items,
    required this.fromCache,
    required this.hasMore,
    this.nextCursor,
  });

  final List<LegacyHistoryGroupSummary> items;
  final bool fromCache;
  final bool hasMore;
  final String? nextCursor;
}

class HistorySearchPage {
  const HistorySearchPage({
    required this.results,
    required this.fromCache,
    required this.hasMore,
    required this.phase,
    this.nextCursor,
    this.revision,
  });

  final List<HistorySearchHit> results;
  final bool fromCache;
  final bool hasMore;
  final String phase;
  final String? nextCursor;
  final int? revision;
}

class HistoryCalendarDay {
  const HistoryCalendarDay({
    required this.date,
    required this.messageCount,
    this.providerUsageCount = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final String date;
  final int messageCount;
  final int providerUsageCount;
  final int inputTokens;
  final int outputTokens;

  bool get hasProviderUsage => providerUsageCount > 0;
}

class HistoryCapabilities {
  const HistoryCapabilities({
    required this.historyProjectionAvailable,
    required this.legacyArchiveAvailable,
    required this.trashRetentionDays,
  });

  final bool historyProjectionAvailable;
  final bool legacyArchiveAvailable;
  final int trashRetentionDays;
}

class HistoryCalendarSnapshot {
  const HistoryCalendarSnapshot({
    required this.days,
    required this.fromCache,
    this.revision,
  });

  final List<HistoryCalendarDay> days;
  final bool fromCache;
  final int? revision;
}

/// A local calendar day's provider-reported token usage.
class HistoryTokenUsageDay {
  const HistoryTokenUsageDay({
    required this.date,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String date;
  final int inputTokens;
  final int outputTokens;

  int get totalTokens => inputTokens + outputTokens;
}

/// Token usage derived only from canonical message `usage` payloads.
class HistoryTokenUsageSnapshot {
  const HistoryTokenUsageSnapshot({
    required this.days,
    required this.fromCache,
  });

  final List<HistoryTokenUsageDay> days;
  final bool fromCache;
}

class HistoryDaySnapshot {
  const HistoryDaySnapshot({
    required this.messages,
    required this.fromCache,
    this.revision,
  });

  final List<ChatMessage> messages;
  final bool fromCache;
  final int? revision;
}

class HistoryFolder {
  const HistoryFolder({
    required this.folderId,
    required this.name,
    this.legacyFolderId,
  });

  final String folderId;
  final String name;
  final String? legacyFolderId;

  factory HistoryFolder.fromJson(Map<String, dynamic> json) => HistoryFolder(
    folderId: (json['folder_id'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    legacyFolderId: json['legacy_folder_id']?.toString(),
  );
}

class HistoryFolderSnapshot {
  const HistoryFolderSnapshot({
    required this.items,
    required this.fromCache,
    this.revision,
  });

  final List<HistoryFolder> items;
  final bool fromCache;
  final int? revision;
}
