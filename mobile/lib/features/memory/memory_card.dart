class MemoryCard {
  const MemoryCard({
    required this.id,
    required this.title,
    required this.content,
    required this.tags,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String content;
  final List<String> tags;
  final DateTime? updatedAt;

  factory MemoryCard.fromJson(Map<String, dynamic> json) => MemoryCard(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    content: json['content']?.toString() ?? '',
    tags: switch (json['tags']) {
      final List values => values.map((value) => value.toString()).toList(),
      _ => const [],
    },
    updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
  );
}
