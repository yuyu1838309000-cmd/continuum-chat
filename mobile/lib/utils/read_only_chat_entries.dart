import '../models/message.dart';
import 'time_format.dart';

enum ReadOnlyChatEntryType { date, message }

class ReadOnlyChatEntry {
  const ReadOnlyChatEntry._({
    required this.type,
    this.label,
    this.messageIndex,
  });

  final ReadOnlyChatEntryType type;
  final String? label;
  final int? messageIndex;

  const ReadOnlyChatEntry.date(String label)
    : this._(type: ReadOnlyChatEntryType.date, label: label);

  const ReadOnlyChatEntry.message(int messageIndex)
    : this._(type: ReadOnlyChatEntryType.message, messageIndex: messageIndex);
}

List<ReadOnlyChatEntry> buildReadOnlyChatEntries(List<ChatMessage> messages) {
  final entries = <ReadOnlyChatEntry>[];
  var lastDateKey = '';
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final dateKey = localDateKey(message.time);
    if (dateKey != lastDateKey) {
      entries.add(ReadOnlyChatEntry.date(readOnlyDateLabel(message.time)));
      lastDateKey = dateKey;
    }
    entries.add(ReadOnlyChatEntry.message(i));
  }
  return entries;
}

int? resolveReadOnlyFocusMessageIndex(
  List<ChatMessage> messages, {
  String? focusEventId,
  int? focusRawEventId,
  int? focusIndex,
}) {
  if (focusEventId != null && focusEventId.isNotEmpty) {
    final byEventId = messages.indexWhere(
      (message) => message.eventId == focusEventId,
    );
    if (byEventId >= 0) return byEventId;
  }
  if (focusRawEventId != null) {
    final byId = messages.indexWhere(
      (message) => message.rawEventId == focusRawEventId,
    );
    if (byId >= 0) return byId;
  }
  if (focusIndex != null && focusIndex >= 0 && focusIndex < messages.length) {
    return focusIndex;
  }
  return null;
}

int? readOnlyEntryIndexForMessageIndex(
  List<ReadOnlyChatEntry> entries,
  int? messageIndex,
) {
  if (messageIndex == null) return null;
  final index = entries.indexWhere(
    (entry) =>
        entry.type == ReadOnlyChatEntryType.message &&
        entry.messageIndex == messageIndex,
  );
  return index >= 0 ? index : null;
}

String readOnlyDateLabel(DateTime date) {
  final weekday = switch (date.weekday) {
    DateTime.monday => '周一',
    DateTime.tuesday => '周二',
    DateTime.wednesday => '周三',
    DateTime.thursday => '周四',
    DateTime.friday => '周五',
    DateTime.saturday => '周六',
    _ => '周日',
  };
  return '${date.year}年${date.month}月${date.day}日 $weekday';
}
