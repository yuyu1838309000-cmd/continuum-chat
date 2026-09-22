/// 自我提示（v0.2.124）：AI 助手的身份认知 + 平时想放的记忆。
/// 读写 8816 GET/POST /self-prompt（~/self_prompt.json），App 只做展示/编辑。
class SelfPrompt {
  String systemPrompt;
  List<String> memories;

  SelfPrompt({this.systemPrompt = '', List<String>? memories})
    : memories = memories ?? [];

  factory SelfPrompt.fromJson(Map<String, dynamic> json) => SelfPrompt(
    systemPrompt: json['system_prompt'] as String? ?? '',
    memories: [
      for (final m in json['memories'] as List<dynamic>? ?? [])
        if (m is String && m.trim().isNotEmpty) m.trim(),
    ],
  );

  Map<String, dynamic> toJson() => {
    'system_prompt': systemPrompt,
    'memories': memories,
  };
}
