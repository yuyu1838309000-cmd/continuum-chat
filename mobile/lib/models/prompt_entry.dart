/// 系统记忆两级结构：四大分区 + 区内条目
class PromptItem {
  String title;
  String content;

  PromptItem({required this.title, this.content = ''});

  factory PromptItem.fromJson(Map<String, dynamic> json) => PromptItem(
    title: json['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'title': title, 'content': content};
}

class PromptSection {
  String title;
  List<PromptItem> items;

  PromptSection({required this.title, required this.items});

  factory PromptSection.fromJson(Map<String, dynamic> json) => PromptSection(
    title: json['title'] as String? ?? '',
    items: (json['items'] as List<dynamic>? ?? [])
        .map((e) => PromptItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'items': items.map((e) => e.toJson()).toList(),
  };
}
