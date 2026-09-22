/// 日记条目（diary_entries 表）。
/// AI 助手写、用户只读：App 端只做展示，不做写表单。
/// fromJson 照 mood.dart 写法：全部可选兜底，不因缺字段崩。
class DiaryEntry {
  final int id;
  final String date;
  final String title;
  final String content;
  final String weather;
  final String mood;
  final int? moodScore;
  final String createdAt;

  const DiaryEntry({
    required this.id,
    required this.date,
    required this.title,
    required this.content,
    required this.weather,
    required this.mood,
    required this.moodScore,
    required this.createdAt,
  });

  factory DiaryEntry.fromJson(Map<String, dynamic> j) => DiaryEntry(
    id: (j['id'] as num?)?.toInt() ?? 0,
    date: (j['date'] as String?)?.trim() ?? '',
    title: (j['title'] as String?)?.trim() ?? '',
    content: (j['content'] as String?)?.trim() ?? '',
    weather: (j['weather'] as String?)?.trim() ?? '',
    mood: (j['mood'] as String?)?.trim() ?? '',
    moodScore: (j['mood_score'] as num?)?.toInt(),
    createdAt: (j['created_at'] as String?)?.trim() ?? '',
  );
}

/// 想说的话（whispers 表）。
class Whisper {
  final int id;
  final String content;
  final int pinned;
  final bool consumed;
  final String createdAt;

  const Whisper({
    required this.id,
    required this.content,
    required this.pinned,
    required this.consumed,
    required this.createdAt,
  });

  factory Whisper.fromJson(Map<String, dynamic> j) => Whisper(
    id: (j['id'] as num?)?.toInt() ?? 0,
    content: (j['content'] as String?)?.trim() ?? '',
    pinned: (j['pinned'] as num?)?.toInt() ?? 0,
    consumed:
        j['consumed'] == true ||
        (j['consumed'] is num && (j['consumed'] as num).toInt() != 0),
    createdAt: (j['created_at'] as String?)?.trim() ?? '',
  );

  bool get isPinned => pinned == 1;
}
