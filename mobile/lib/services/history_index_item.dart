import 'runtime_history_models.dart';

class HistoryIndexItem {
  const HistoryIndexItem({
    required this.id,
    required this.messageCount,
    required this.archivedAt,
    required this.legacyArchive,
    this.epochId,
    this.legacyGroupId,
    this.title,
    this.preview,
    this.folderId,
  });

  final String id;
  final int messageCount;
  final DateTime archivedAt;
  final bool legacyArchive;
  final String? epochId;
  final String? legacyGroupId;
  final String? title;
  final String? preview;
  final String? folderId;

  bool get mutable => !legacyArchive && (epochId ?? '').isNotEmpty;
  factory HistoryIndexItem.runtime(HistoryConversationSummary summary) {
    final at =
        summary.lastMessageAt ??
        summary.closedAt ??
        summary.openedAt ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return HistoryIndexItem(
      id: 'runtime:${summary.epochId}',
      epochId: summary.epochId,
      messageCount: summary.messageCount,
      archivedAt: at.toLocal(),
      legacyArchive: false,
      title: summary.title,
      preview: summary.preview,
      folderId: summary.folderId,
    );
  }

  factory HistoryIndexItem.legacy(LegacyHistoryGroupSummary group) {
    return HistoryIndexItem(
      id: 'legacy:${group.groupId}',
      legacyGroupId: group.groupId,
      messageCount: group.messageCount,
      archivedAt: group.lastCreatedAt.toLocal(),
      legacyArchive: true,
      preview: group.preview,
    );
  }
}
