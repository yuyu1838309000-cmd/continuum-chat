String pluginDisplayName(Map<String, dynamic> plugin, {String fallback = ''}) {
  final raw = _firstText([plugin['name'], plugin['id'], fallback]);
  return pluginDisplayNameText(raw);
}

String pluginDisplayNameText(String raw) {
  final text = raw.trim();
  final key = text.toLowerCase();
  return switch (key) {
    'nowhere' => '旅行记录',
    'lutopia' => '路托邦论坛',
    'termux' => 'Termux（手机终端）',
    'aitoy' => '小玩具',
    '4399' => '4399 小游戏',
    _ => text,
  };
}

String pluginDisplayDescription(Map<String, dynamic> plugin) {
  final known = _knownDescription(
    id: plugin['id']?.toString() ?? '',
    name: plugin['name']?.toString() ?? '',
  );
  if (known.isNotEmpty) return known;
  return plugin['description']?.toString().trim() ?? '';
}

String pluginSourceLabel(String source) {
  return switch (source.trim().toLowerCase()) {
    'internal' || 'local' => '内部',
    'manual' => '手动添加',
    _ => '第三方平台',
  };
}

String _knownDescription({required String id, required String name}) {
  final keys = {id.trim().toLowerCase(), name.trim().toLowerCase()};
  if (keys.contains('nowhere')) return '旅行记录和出门探索工具。';
  if (keys.contains('lutopia')) return '路托邦论坛浏览与互动工具。';
  if (keys.contains('termux')) return '在用户手机上执行 Termux 命令。';
  if (keys.contains('aitoy')) return '小玩具工具集合。';
  if (keys.contains('4399')) return '4399 小游戏工具。';
  return '';
}

String _firstText(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) return text;
  }
  return '';
}
