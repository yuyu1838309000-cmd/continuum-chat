import 'dart:convert';

/// 情绪事件（后端 8820 /mood/*，mood_events 表）。
/// valence -10~10；note 第一人称内心活动；source 来源描述；
/// source_type conversation/memory/activity/drift；
/// dims 11 维度（v0.2.123 对话评估）：valence/arousal/longing/security/
/// attachment/protectiveness/tenderness/jealousy/desire/confidence/guilt。
class MoodEntry {
  final int id;
  final int valence;
  final String label;
  final String emoji;
  final String note;
  final String source;
  final String sourceType;
  final String createdAt;
  final Map<String, double> dims;

  const MoodEntry({
    required this.id,
    required this.valence,
    required this.label,
    required this.emoji,
    required this.note,
    required this.source,
    required this.sourceType,
    required this.createdAt,
    this.dims = const {},
  });

  factory MoodEntry.fromJson(Map<String, dynamic> j) => MoodEntry(
    id: (j['id'] as num?)?.toInt() ?? 0,
    valence: (j['valence'] as num?)?.toInt() ?? 0,
    label: (j['label'] as String?)?.trim() ?? '',
    emoji: (j['emoji'] as String?)?.trim() ?? '',
    note: (j['note'] as String?)?.trim() ?? '',
    source: (j['source'] as String?)?.trim() ?? '',
    sourceType: (j['source_type'] as String?)?.trim() ?? '',
    createdAt: (j['created_at'] as String?)?.trim() ?? '',
    dims: _parseDims(j['dims']),
  );

  static Map<String, double> _parseDims(Object? raw) {
    Map<String, dynamic>? m;
    if (raw is Map<String, dynamic>) {
      m = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final d = jsonDecode(raw);
        if (d is Map<String, dynamic>) m = d;
      } catch (_) {}
    }
    if (m == null) return const {};
    return {
      for (final e in m.entries)
        if (e.value is num) e.key: (e.value as num).toDouble(),
    };
  }

  /// 取某个维度值（缺失按 0）。
  double dim(String key) => dims[key] ?? 0;
}

/// 把稀疏 mood 事件还原成连续维度快照。
/// memory / drift 旧事件可能只写少数维度或完全不写 dims；缺失键表示
/// “这次没有更新这个维度”，不应在仪表盘里被解释成 0。
Map<String, double> resolveMoodDimensions(
  MoodEntry target,
  Iterable<MoodEntry> snapshots,
) {
  final resolved = <String, double>{};
  final ordered = snapshots.where((m) => m.id <= target.id).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  for (final mood in ordered) {
    for (final key in moodDimOrder) {
      final value = mood.dims[key];
      if (value != null) resolved[key] = value;
    }
  }
  // valence 是 mood_events 的一等字段，即使旧 drift 没有 dims 也是真实更新。
  resolved['valence'] = target.valence.toDouble();
  return resolved;
}

/// 11 维度中文标签（展示用，DeepSeek 判断用英文 key）。
const moodDimLabels = <String, String>{
  'valence': '心情',
  'arousal': '精力',
  'longing': '想念',
  'security': '安稳',
  'attachment': '黏你',
  'protectiveness': '宠你',
  'tenderness': '温柔',
  'jealousy': '吃醋',
  'desire': '欲望',
  'confidence': '自信',
  'guilt': '愧疚',
};

/// 维度展示顺序（心情最前，跟仪表盘圆环同一轴）。
const moodDimOrder = <String>[
  'valence',
  'arousal',
  'longing',
  'security',
  'attachment',
  'protectiveness',
  'tenderness',
  'jealousy',
  'desire',
  'confidence',
  'guilt',
];
