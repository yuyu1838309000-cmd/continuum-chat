/// 记忆库卡片模型（Continuum Chat记忆库 8820）。
/// /cards 和 /days 返回的字段不完全一致（/days 精简字段），
/// 解析时全部容错，缺字段用默认值。
class MemoryCard {
  final int id;
  final String title;
  final String content;
  final double importance;
  final String tags;
  final String keywords;
  final String? happenedAt;
  final String createdAt;
  final String latestActivityAt;
  final String latestActivityContent;
  final String latestActivityKind;
  final int? currentRevisionId;
  final String status;
  final int pinned;
  final int hits;
  final String freshness;

  const MemoryCard({
    required this.id,
    required this.title,
    required this.content,
    this.importance = 0,
    this.tags = '',
    this.keywords = '',
    this.happenedAt,
    this.createdAt = '',
    this.latestActivityAt = '',
    this.latestActivityContent = '',
    this.latestActivityKind = '',
    this.currentRevisionId,
    this.status = '',
    this.pinned = 0,
    this.hits = 0,
    this.freshness = '',
  });

  /// 日期卡：title 是 yyyy-MM-dd 格式。
  bool get isDateCard => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(title);

  factory MemoryCard.fromJson(Map<String, dynamic> j) => MemoryCard(
    id: (j['id'] as num?)?.toInt() ?? 0,
    title: j['title']?.toString() ?? '',
    content: j['content']?.toString() ?? '',
    importance: (j['importance'] as num?)?.toDouble() ?? 0,
    tags: j['tags']?.toString() ?? '',
    keywords: j['keywords']?.toString() ?? '',
    happenedAt: j['happened_at']?.toString(),
    createdAt: j['created_at']?.toString() ?? '',
    latestActivityAt: j['latest_activity_at']?.toString() ?? '',
    latestActivityContent: j['latest_activity_content']?.toString() ?? '',
    latestActivityKind: j['latest_activity_kind']?.toString() ?? '',
    currentRevisionId: (j['current_revision_id'] as num?)?.toInt(),
    status: j['status']?.toString() ?? '',
    pinned: (j['pinned'] as num?)?.toInt() ?? 0,
    hits: (j['hits'] as num?)?.toInt() ?? 0,
    freshness: j['freshness']?.toString() ?? '',
  );
}

/// 年轮：卡片历次更新的记录。
class MemoryRing {
  final String content;
  final String createdAt;
  final String by;

  const MemoryRing({
    required this.content,
    required this.createdAt,
    this.by = '',
  });

  factory MemoryRing.fromJson(Map<String, dynamic> j) => MemoryRing(
    content: j['content']?.toString() ?? '',
    createdAt: j['created_at']?.toString() ?? '',
    by: j['by']?.toString() ?? '',
  );
}

/// 卡片详情：完整正文 + 年轮列表（GET /card/{id}）。
class MemoryDetail {
  final MemoryCard card;
  final List<MemoryRing> rings;
  final bool reproducible;

  const MemoryDetail({
    required this.card,
    required this.rings,
    this.reproducible = false,
  });
}
