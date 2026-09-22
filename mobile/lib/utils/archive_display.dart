import '../models/archived_chat.dart';
import '../models/message.dart';
import 'time_format.dart';

const String archiveFilterAll = '__all__';
const String archiveFilterUncategorized = '__uncategorized__';
const int archiveDisplayTitleMaxCharacters = 48;

class ArchiveDateGroup {
  const ArchiveDateGroup({required this.dateKey, required this.items});

  final String dateKey;
  final List<ArchivedChat> items;

  DateTime get date => items.first.archivedAt;
}

List<ArchivedChat> filterArchives(List<ArchivedChat> archives, String filter) =>
    switch (filter) {
      archiveFilterUncategorized =>
        archives.where((archive) => (archive.folderId ?? '').isEmpty).toList(),
      archiveFilterAll => archives,
      final folderId =>
        archives.where((archive) => archive.folderId == folderId).toList(),
    };

List<ArchiveDateGroup> groupArchivesByArchivedDate(
  List<ArchivedChat> archives,
) {
  final groups = <ArchiveDateGroup>[];
  var currentKey = '';
  var currentItems = <ArchivedChat>[];

  void flush() {
    if (currentItems.isEmpty) return;
    groups.add(
      ArchiveDateGroup(
        dateKey: currentKey,
        items: List<ArchivedChat>.unmodifiable(currentItems),
      ),
    );
    currentItems = <ArchivedChat>[];
  }

  for (final archive in archives) {
    final key = localDateKey(archive.archivedAt);
    if (currentItems.isNotEmpty && key != currentKey) {
      flush();
    }
    currentKey = key;
    currentItems.add(archive);
  }
  flush();
  return groups;
}

String archiveDisplayTitle(
  ArchivedChat chat, {
  int maxCharacters = archiveDisplayTitleMaxCharacters,
}) {
  final body = firstEffectiveArchiveBody(chat);
  if (body != null) {
    return truncateArchivePreviewText(body, maxCharacters: maxCharacters);
  }
  final fallback = normalizeArchivePreviewText(chat.title);
  final title = fallback.isEmpty ? '历史片段' : fallback;
  return truncateArchivePreviewText(title, maxCharacters: maxCharacters);
}

String? firstEffectiveArchiveBody(ArchivedChat chat) {
  for (final message in chat.messages) {
    final body = _effectiveMessageBody(message);
    if (body != null) return body;
  }
  return null;
}

String archiveDateHeaderLabel(DateTime date, {DateTime? now}) {
  final localNow = now ?? DateTime.now();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final day = DateTime(date.year, date.month, date.day);
  if (day == today) return '今天';
  if (day == today.subtract(const Duration(days: 1))) return '昨天';
  if (date.year == localNow.year) return '${date.month}月${date.day}日';
  return '${date.year}年${date.month}月${date.day}日';
}

String archiveCardTimeLabel(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}';

String archiveMetaLine({
  required DateTime archivedAt,
  required int messageCount,
  required String? folderName,
}) {
  final folder = folderName == null || folderName.isEmpty ? '未分类' : folderName;
  return '${archiveCardTimeLabel(archivedAt)} · $messageCount 条 · $folder';
}

bool shouldExitArchiveSelectionOnBlockedPop({
  required bool didPop,
  required bool inSelection,
}) => !didPop && inSelection;

String normalizeArchivePreviewText(String raw) {
  final text = raw
      .replaceAll('\u200b', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text == '[图片]' || text == '[文件]') return '';
  return text;
}

String truncateArchivePreviewText(
  String text, {
  int maxCharacters = archiveDisplayTitleMaxCharacters,
}) {
  if (maxCharacters <= 0) return '';
  final runes = text.runes.toList(growable: false);
  if (runes.length <= maxCharacters) return text;
  return '${String.fromCharCodes(runes.take(maxCharacters)).trimRight()}...';
}

String? _effectiveMessageBody(ChatMessage message) {
  if (message.isActivity || message.isToolDone) return null;

  final content = normalizeArchivePreviewText(message.content);
  if (content.isNotEmpty) return content;

  for (final part in message.parts) {
    if (part.type != ChatMessagePartType.text) continue;
    final text = normalizeArchivePreviewText(part.text);
    if (text.isNotEmpty) return text;
  }
  return null;
}

String _two(int value) => value.toString().padLeft(2, '0');
