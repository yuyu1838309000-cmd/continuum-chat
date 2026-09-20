class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.reasoning = '',
    this.createdAt,
    this.providerUsage = const {},
    this.isStreaming = false,
  });

  final String id;
  final String role;
  final String content;
  final String reasoning;
  final DateTime? createdAt;
  final Map<String, dynamic> providerUsage;
  final bool isStreaming;

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id']?.toString() ?? '',
    role: json['role']?.toString() ?? 'assistant',
    content: json['content']?.toString() ?? '',
    reasoning: json['reasoning']?.toString() ?? '',
    createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    providerUsage: json['provider_usage'] is Map<String, dynamic>
        ? json['provider_usage'] as Map<String, dynamic>
        : const {},
  );

  ChatMessage copyWith({
    String? id,
    String? content,
    String? reasoning,
    bool? isStreaming,
  }) => ChatMessage(
    id: id ?? this.id,
    role: role,
    content: content ?? this.content,
    reasoning: reasoning ?? this.reasoning,
    createdAt: createdAt,
    providerUsage: providerUsage,
    isStreaming: isStreaming ?? this.isStreaming,
  );
}
