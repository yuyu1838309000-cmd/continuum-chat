/// 消息时间戳格式化。
/// 与上一条消息同一天 → [14:30]；跨天 → [08-05 22:10]。
/// 所有日期按设备本地时区（Asia/Shanghai）。
String formatMessageTime(DateTime time, DateTime? prev) {
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(time.hour)}:${two(time.minute)}';
  final sameDay =
      prev != null &&
      prev.year == time.year &&
      prev.month == time.month &&
      prev.day == time.day;
  if (sameDay) return '[$hm]';
  return '[${two(time.month)}-${two(time.day)} $hm]';
}

/// 本地日期键：yyyy-MM-dd，用于日历分组。
String localDateKey(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}
