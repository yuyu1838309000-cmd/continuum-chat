/// Chat Content V2: conversation-facing copy for reasoning/tool process UI.
///
/// This file is presentation-only. It must never alter canonical tool names,
/// statuses, round ids, payloads, or Runtime lifecycle semantics.
String chatToolDisplayName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '';
  return switch (name) {
    'search' => '搜索',
    'get_time' => '时间',
    'participanting' => '钓鱼',
    'market' => '市场',
    'music' => '音乐',
    'music_like' => '红心',
    'memory' => '记忆',
    'memory_list' => '记忆库',
    'memory_update' => '改记忆',
    'memory_delete' => '删记忆',
    'send_image' => '发图',
    'gen_image' => '画图',
    'termux' => '手机操作',
    'ask' => '提问',
    'contemplate' => '沉思',
    'whisper' => '悄悄话',
    _ => name,
  };
}

String chatFormatToolNames(List<String> names) {
  if (names.isEmpty) return '';
  final unique = <String>[];
  for (final name in names) {
    final clean = name.trim();
    if (clean.isNotEmpty && !unique.contains(clean)) unique.add(clean);
  }
  if (unique.isEmpty) return '';
  final head = unique.take(3).join('、');
  return unique.length > 3 ? '$head 等${unique.length}个' : head;
}

String chatProcessSectionLabel({
  required bool failed,
  required bool active,
  required bool hasTool,
  required int stepCount,
  List<String> toolNames = const [],
}) {
  if (failed) return stepCount > 0 ? '这段没做完 · $stepCount步' : '这段没做完';
  if (active) {
    return hasTool ? '正在处理…' : '在想…';
  }
  final names = chatFormatToolNames(toolNames);
  if (names.isNotEmpty) return '处理过 · $names';
  return stepCount > 1 ? '想过 · $stepCount步' : '想过';
}

String chatToolStepLabel({
  required String status,
  required bool running,
  required bool deviceRunning,
  List<String> toolNames = const [],
}) {
  final names = chatFormatToolNames(toolNames);
  if (status == 'failed') {
    return names.isEmpty ? '这一步没做完' : '$names没做完';
  }
  if (running) {
    if (deviceRunning) return '正在操作手机…';
    return names.isEmpty ? '正在处理…' : '正在处理 · $names';
  }
  return names.isEmpty ? '处理好了' : '处理好了 · $names';
}

String chatBusyLabel({required bool deviceRunning}) =>
    deviceRunning ? '正在操作手机…' : '正在处理…';

String chatToolDoneDisplayLabel(String? storedLabel) {
  final text = storedLabel?.trim() ?? '';
  if (text.isEmpty || text == '✓ 搞定了！') return '处理好了';
  return text;
}
