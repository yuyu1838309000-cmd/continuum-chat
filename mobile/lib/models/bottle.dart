/// 提问瓶（v0.2.151）数据模型。
/// 数据源：8820 /bottle/questions（dimensions 统计 + 最新未答 + 最近已答）。
class BottleDimension {
  final String name;
  final int total; // 已问问题数
  final int unanswered;

  const BottleDimension({
    required this.name,
    this.total = 0,
    this.unanswered = 0,
  });

  factory BottleDimension.fromJson(Map<String, dynamic> j) => BottleDimension(
    name: j['dimension']?.toString() ?? '',
    total: (j['total'] as num?)?.toInt() ?? 0,
    unanswered: (j['unanswered'] as num?)?.toInt() ?? 0,
  );
}

class BottleQuestion {
  final int id;
  final String dimension;
  final String question;
  final String answer;
  final String status;
  final String createdAt;
  final String answeredAt;

  const BottleQuestion({
    required this.id,
    this.dimension = '',
    this.question = '',
    this.answer = '',
    this.status = '',
    this.createdAt = '',
    this.answeredAt = '',
  });

  factory BottleQuestion.fromJson(Map<String, dynamic> j) => BottleQuestion(
    id: (j['id'] as num?)?.toInt() ?? 0,
    dimension: j['dimension']?.toString() ?? '',
    question: j['question']?.toString() ?? '',
    answer: j['answer']?.toString() ?? '',
    status: j['status']?.toString() ?? '',
    createdAt: j['created_at']?.toString() ?? '',
    answeredAt: j['answered_at']?.toString() ?? '',
  );
}

class BottleData {
  final List<BottleDimension> dimensions;
  final String dimension;
  final BottleQuestion? latestUnanswered;
  final List<BottleQuestion> answeredRecent;
  final List<BottleQuestion> unansweredList;
  final List<BottleQuestion> answeredList;
  final List<BottleQuestion> questions;

  const BottleData({
    this.dimensions = const [],
    this.dimension = '',
    this.latestUnanswered,
    this.answeredRecent = const [],
    this.unansweredList = const [],
    this.answeredList = const [],
    this.questions = const [],
  });

  factory BottleData.fromJson(Map<String, dynamic> j) {
    final dims = <BottleDimension>[];
    final rawDims = j['dimensions'];
    if (rawDims is List) {
      for (final d in rawDims) {
        if (d is Map<String, dynamic>) dims.add(BottleDimension.fromJson(d));
      }
    }
    final recent = <BottleQuestion>[];
    final rawRecent = j['answered_recent'];
    if (rawRecent is List) {
      for (final r in rawRecent) {
        if (r is Map<String, dynamic>) recent.add(BottleQuestion.fromJson(r));
      }
    }
    List<BottleQuestion> parseList(String key) {
      final out = <BottleQuestion>[];
      final raw = j[key];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            out.add(BottleQuestion.fromJson(item));
          }
        }
      }
      return out;
    }

    final latest = j['latest_unanswered'];
    return BottleData(
      dimensions: dims,
      dimension: j['dimension']?.toString() ?? '',
      latestUnanswered: latest is Map<String, dynamic>
          ? BottleQuestion.fromJson(latest)
          : null,
      answeredRecent: recent,
      unansweredList: parseList('unanswered_list'),
      answeredList: parseList('answered_list'),
      questions: parseList('questions'),
    );
  }
}
