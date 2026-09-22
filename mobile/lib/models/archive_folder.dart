/// 归档文件夹（v0.2.161）：归纳已归档的会话。
/// 存 documents 目录 archive_folders.json（archives.json 旁），结构 {id, name, createdAt}。
class ArchiveFolder {
  final String id;
  final String name;
  final DateTime createdAt;

  const ArchiveFolder({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ArchiveFolder.fromJson(Map<String, dynamic> json) => ArchiveFolder(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '文件夹',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}
