/// 共读小屋 · 书模型（read_data.json，key=书名，与 read-mcp 8812 同源）。
/// 全部字段防御式解析，缺字段不崩；ratings 按人（用户/AI 助手）分开记。
class ReadingBook {
  final String title;
  final String author;
  final String status; // 未读 / 正在看 / 已读
  final String updated;
  final String summary; // 读完总结
  final String participantLastChapter;
  final String assistantLastChapter;
  final List<ReadingProgress> progress;
  final List<ReadingNote> notes;
  final Map<String, ReadingRating> ratings; // key: 用户 / AI 助手

  const ReadingBook({
    required this.title,
    required this.author,
    required this.status,
    required this.updated,
    required this.summary,
    required this.participantLastChapter,
    required this.assistantLastChapter,
    required this.progress,
    required this.notes,
    required this.ratings,
  });

  factory ReadingBook.fromJson(Map<String, dynamic> j) {
    final title = (j['title'] as String? ?? '').trim();
    final ratings = <String, ReadingRating>{};
    final rawRatings = j['ratings'];
    if (rawRatings is Map) {
      rawRatings.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          ratings[k.toString()] = ReadingRating.fromJson(v);
        }
      });
    }
    return ReadingBook(
      title: title.isEmpty ? (j.keys.isNotEmpty ? j.keys.first : '') : title,
      author: (j['author'] as String? ?? '').trim(),
      status: (j['status'] as String? ?? '未读').trim(),
      updated: (j['updated'] as String? ?? '').trim(),
      summary: _summaryOf(j),
      participantLastChapter: (j['用户_last_chapter'] as String? ?? '').trim(),
      assistantLastChapter: (j['AI 助手_last_chapter'] as String? ?? '').trim(),
      progress: _listOf(j['progress'], ReadingProgress.fromJson),
      notes: _listOf(j['notes'], ReadingNote.fromJson),
      ratings: ratings,
    );
  }

  static String _summaryOf(Map<String, dynamic> j) {
    final s = j['summary'];
    if (s is Map<String, dynamic>) {
      return (s['text'] as String? ?? '').trim();
    }
    if (s is String) return s.trim();
    return '';
  }

  static List<T> _listOf<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (raw is! List) return const [];
    final out = <T>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) out.add(parse(e));
    }
    return out;
  }

  int get progressCount => progress.length;
  int get noteCount => notes.length;
  ReadingRating? get participantRating => ratings['用户'];
  ReadingRating? get assistantRating => ratings['AI 助手'];
}

/// 进度一条（时间线）。
class ReadingProgress {
  final String time;
  final String who;
  final String chapter;
  final String text;

  const ReadingProgress({
    required this.time,
    required this.who,
    required this.chapter,
    required this.text,
  });

  factory ReadingProgress.fromJson(Map<String, dynamic> j) => ReadingProgress(
    time: (j['time'] as String? ?? '').trim(),
    who: (j['who'] as String? ?? '').trim(),
    chapter: (j['chapter'] as String? ?? '').trim(),
    text: (j['text'] as String? ?? '').trim(),
  );
}

/// 感想一条。
class ReadingNote {
  final String time;
  final String who;
  final String text;

  const ReadingNote({
    required this.time,
    required this.who,
    required this.text,
  });

  factory ReadingNote.fromJson(Map<String, dynamic> j) => ReadingNote(
    time: (j['time'] as String? ?? '').trim(),
    who: (j['who'] as String? ?? '').trim(),
    text: (j['text'] as String? ?? '').trim(),
  );
}

/// 一个人的评分（打星 + 情绪 emoji + 短评 + 时间）。
class ReadingRating {
  final int score; // 0 = 未打分
  final String mood;
  final String comment;
  final String time;

  const ReadingRating({
    required this.score,
    required this.mood,
    required this.comment,
    required this.time,
  });

  factory ReadingRating.fromJson(Map<String, dynamic> j) => ReadingRating(
    score: (j['score'] as num?)?.toInt() ?? 0,
    mood: (j['mood'] as String? ?? '').trim(),
    comment: (j['comment'] as String? ?? '').trim(),
    time: (j['time'] as String? ?? '').trim(),
  );

  bool get hasScore => score >= 1 && score <= 5;
  bool get hasMood => mood.isNotEmpty;
  bool get hasComment => comment.isNotEmpty;
}

/// 可选的阅读情绪 emoji（与 read-mcp RATING_EMOJIS 一致）。
const List<String> readingMoodEmojis = [
  '😭',
  '🥹',
  '😌',
  '🥰',
  '🤯',
  '😂',
  '😤',
  '💔',
  '😱',
  '🔥',
  '🌙',
  '🤔',
  '😴',
  '😄',
  '😢',
];
