import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';
import '../utils/plugin_display.dart';
import '../widgets/setting_card.dart';

/// MCP / 命令工具 / Skill 的原有配置页与编辑表单。
/// 统一插件列表复用这些表单，保持原有保存语义。

Map<String, dynamic>? _findConfiguredItem(
  List<Map<String, dynamic>> items,
  Map<String, dynamic> target,
) {
  final targetId = target['id']?.toString() ?? '';
  final targetName = target['name']?.toString() ?? '';
  for (final item in items) {
    final id = item['id']?.toString() ?? '';
    if (targetId.isNotEmpty && id == targetId) return item;
    final name = item['name']?.toString() ?? '';
    if (targetId.isEmpty && targetName.isNotEmpty && name == targetName) {
      return item;
    }
  }
  return null;
}

/// 扩展添加表单的带说明输入框：label + 示例 placeholder + 帮助文字，
/// 字段之间用 padding 隔开，避免挤在一起。
Widget _field({
  required BuildContext context,
  required TextEditingController controller,
  required String label,
  required String hint,
  required String help,
  int maxLines = 1,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: _softInputDecoration(
        context,
        labelText: label,
        hintText: hint,
        helperText: help,
        helperMaxLines: 3,
      ),
    ),
  );
}

InputDecoration _softInputDecoration(
  BuildContext context, {
  required String labelText,
  String? hintText,
  String? helperText,
  int? helperMaxLines,
  bool alignLabelWithHint = false,
}) {
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    helperText: helperText,
    helperMaxLines: helperMaxLines,
    alignLabelWithHint: alignLabelWithHint,
    filled: true,
    fillColor: context.fieldColor,
    isDense: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      borderSide: BorderSide.none,
    ),
  );
}

/// 表单底部的"添加后怎么用"引导卡片，简洁低调。
Widget _guidanceBox(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: context.fieldColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.55,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

Widget _emptyHint(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.6,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class _ManageItemCard extends StatelessWidget {
  final String title;
  final String meta;
  final String detail;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final List<Widget> actions;
  final VoidCallback? onTap;

  const _ManageItemCard({
    required this.title,
    this.meta = '',
    this.detail = '',
    required this.enabled,
    required this.onChanged,
    required this.actions,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SettingCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: onChanged),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(spacing: 4, runSpacing: 4, children: actions),
            ),
          ],
        ],
      ),
    );
  }
}

/// MCP 编辑表单里的 key/value 行（请求头或 stdio env）。
class _McpConfigRow {
  _McpConfigRow(
    this.keyCtrl,
    this.valueCtrl, {
    this.secretConfigured = false,
    this.originalKey = '',
  });

  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;
  final bool secretConfigured;
  final String originalKey;
}

class McpConfigPage extends StatefulWidget {
  const McpConfigPage({super.key, this.initialPlugin});

  /// 从统一插件列表进入时，加载后直接打开该条配置。
  final Map<String, dynamic>? initialPlugin;

  @override
  State<McpConfigPage> createState() => _McpConfigPageState();
}

class _McpConfigPageState extends State<McpConfigPage> {
  List<Map<String, dynamic>> _servers = [];
  bool _loading = true;
  bool _saving = false;
  bool _openedInitialPlugin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // v0.2.153 修复批次：刷新复用 _load（AppBar 刷新按钮），进入先置加载态
    if (mounted) setState(() => _loading = true);
    final cfg = await ExtensionConfigApi.mcp();
    if (!mounted) return;
    setState(() {
      _servers =
          (cfg?['servers'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _loading = false;
    });
    if (widget.initialPlugin != null && !_openedInitialPlugin) {
      _openedInitialPlugin = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialPlugin());
    }
  }

  Future<void> _openInitialPlugin() async {
    if (!mounted) return;
    final target = _findConfiguredItem(_servers, widget.initialPlugin!);
    if (target != null) await _addOrEdit(target);
    if (mounted) Navigator.of(context).pop();
  }

  List<Map<String, dynamic>> _serversSnapshot() => [
    for (final s in _servers) Map<String, dynamic>.from(s),
  ];

  Future<bool> _save(List<Map<String, dynamic>> before) async {
    if (_saving) return false;
    if (mounted) setState(() => _saving = true);
    try {
      final cfg = await ExtensionConfigApi.saveMcp(List.of(_servers));
      if (!mounted) return true;
      final saved = (cfg?['servers'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .toList();
      setState(() {
        if (saved != null) _servers = saved;
        _saving = false;
      });
      return true;
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _servers = before;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('保存失败，已还原')));
      return false;
    }
  }

  int _headersCount(Map<String, dynamic> s) {
    final h = s['headers'];
    if (h is Map) return h.length;
    if (h is List) return h.length;
    return 0;
  }

  int _envCount(Map<String, dynamic> s) {
    final env = s['env'];
    if (env is Map) return env.length;
    if (env is List) return env.length;
    return 0;
  }

  int _secretCount(Map<String, dynamic> s) {
    final fields = s['_secret_fields'];
    if (fields is! Map) return 0;
    var count = 0;
    for (final value in fields.values) {
      if (value is List) count += value.length;
    }
    return count;
  }

  List<_McpConfigRow> _rowsFromConfig(Object? raw) {
    final rows = <_McpConfigRow>[];
    void addRow(Object? rawKey, Object? rawValue) {
      final key = rawKey?.toString() ?? '';
      final value = rawValue?.toString() ?? '';
      final configured = ExtensionConfigApi.isSecretConfiguredValue(value);
      rows.add(
        _McpConfigRow(
          TextEditingController(text: key),
          TextEditingController(text: configured ? '' : value),
          secretConfigured: configured,
          originalKey: key,
        ),
      );
    }

    if (raw is Map) {
      raw.forEach(addRow);
    } else if (raw is List) {
      for (final row in raw) {
        if (row is Map) addRow(row['key'], row['value']);
      }
    }
    if (rows.isEmpty) {
      rows.add(_McpConfigRow(TextEditingController(), TextEditingController()));
    }
    return rows;
  }

  Map<String, String> _rowsToMap(List<_McpConfigRow> rows) {
    final out = <String, String>{};
    for (final row in rows) {
      final key = row.keyCtrl.text.trim();
      if (key.isEmpty) continue;
      final value = row.valueCtrl.text.trim();
      if (row.secretConfigured && value.isEmpty && key == row.originalKey) {
        out[key] = ExtensionConfigApi.mcpSecretConfiguredValue;
      } else {
        out[key] = value;
      }
    }
    return out;
  }

  void _disposeRows(List<_McpConfigRow> rows) {
    for (final row in rows) {
      row.keyCtrl.dispose();
      row.valueCtrl.dispose();
    }
  }

  Widget _configRowsSection({
    required BuildContext ctx,
    required List<_McpConfigRow> rows,
    required String title,
    required String keyHint,
    required String valueHint,
    required StateSetter setDialogState,
  }) {
    final theme = Theme.of(ctx);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => setDialogState(() {
                rows.add(
                  _McpConfigRow(
                    TextEditingController(),
                    TextEditingController(),
                  ),
                );
              }),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final keyField = TextField(
                  controller: rows[i].keyCtrl,
                  decoration: _softInputDecoration(
                    ctx,
                    labelText: '键',
                    hintText: keyHint,
                  ),
                );
                final valueField = ValueListenableBuilder<TextEditingValue>(
                  valueListenable: rows[i].keyCtrl,
                  builder: (context, keyValue, _) {
                    final secret = ExtensionConfigApi.isSecretConfigKey(
                      keyValue.text,
                    );
                    final configured =
                        rows[i].secretConfigured &&
                        rows[i].keyCtrl.text.trim() == rows[i].originalKey;
                    return TextField(
                      controller: rows[i].valueCtrl,
                      obscureText: secret,
                      decoration: _softInputDecoration(
                        ctx,
                        labelText: secret ? '密钥' : '值',
                        hintText: configured
                            ? '已配置，不填会保留'
                            : secret
                            ? '保存后只显示已配置'
                            : valueHint,
                      ),
                    );
                  },
                );
                final removeButton = IconButton(
                  icon: const Icon(LucideIcons.x, size: 18),
                  tooltip: '删除这一行',
                  onPressed: rows.length == 1
                      ? null
                      : () => setDialogState(() {
                          final row = rows.removeAt(i);
                          row.keyCtrl.dispose();
                          row.valueCtrl.dispose();
                        }),
                );
                if (constraints.maxWidth < 300) {
                  return Column(
                    children: [
                      keyField,
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: valueField),
                          removeButton,
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: keyField),
                    const SizedBox(width: 8),
                    Expanded(flex: 3, child: valueField),
                    removeButton,
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _addOrEdit([Map<String, dynamic>? old]) async {
    // 配置加载完成前不允许打开添加/编辑表单，避免选中态先用默认值渲染。
    if (_loading) return;
    final idCtrl = TextEditingController(text: old?['id']?.toString() ?? '');
    final nameCtrl = TextEditingController(
      text: old?['name']?.toString() ?? '',
    );
    final urlCtrl = TextEditingController(text: old?['url']?.toString() ?? '');
    final cmdCtrl = TextEditingController(
      text: old?['command']?.toString() ?? '',
    );
    final argsCtrl = TextEditingController(
      text: (old?['args'] as List<dynamic>? ?? []).join(' '),
    );
    // 后端会把密钥值返回为 marker；编辑时留空代表保留旧值。
    final headerRows = _rowsFromConfig(old?['headers']);
    final envRows = _rowsFromConfig(old?['env']);
    // 用已加载配置里的真实 type 一次性初始化；旧数据缺 type 才回退 remote。
    final rawType = old?['type']?.toString() ?? 'remote';
    final typeNotifier = ValueNotifier<String>(
      rawType == 'stdio' ? 'stdio' : 'remote',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(old == null ? '添加 MCP 工具' : '编辑 MCP 工具'),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(
                    context: ctx,
                    controller: idCtrl,
                    label: '唯一 ID',
                    hint: '例如 weather-mcp',
                    help: '留空会自动用名称。用于区分同名工具。',
                  ),
                  _field(
                    context: ctx,
                    controller: nameCtrl,
                    label: '名称',
                    hint: '例如：天气查询',
                    help: '给工具起一个好认的名字，模型调用时也用这个名字。',
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '连接方式',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  ValueListenableBuilder<String>(
                    valueListenable: typeNotifier,
                    builder: (context, type, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChoiceChip(
                          label: const Text('HTTP 服务'),
                          selected: type == 'remote',
                          onSelected: (selected) {
                            if (selected) typeNotifier.value = 'remote';
                          },
                        ),
                        const SizedBox(height: 8),
                        ChoiceChip(
                          label: const Text('本地命令（stdio）'),
                          selected: type == 'stdio',
                          onSelected: (selected) {
                            if (selected) typeNotifier.value = 'stdio';
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: typeNotifier,
                    builder: (context, type, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (type == 'remote') ...[
                          _field(
                            context: ctx,
                            controller: urlCtrl,
                            label: 'HTTP 地址',
                            hint: 'https://example.com/mcp',
                            help: '8816 会向这里 POST JSON-RPC 的 tools/call 请求。',
                          ),
                          _configRowsSection(
                            ctx: ctx,
                            rows: headerRows,
                            title: '请求头（可选，Authorization / x-api-key 会按密钥保存）',
                            keyHint: 'Authorization',
                            valueHint: 'Bearer ...',
                            setDialogState: setDialogState,
                          ),
                        ],
                        if (type == 'stdio') ...[
                          _field(
                            context: ctx,
                            controller: cmdCtrl,
                            label: '启动命令',
                            hint: '例如 npx 或 /path/to/mcp-server',
                            help: '8816 会启动这个命令，并通过 stdin/stdout 跟它通信。',
                          ),
                          _field(
                            context: ctx,
                            controller: argsCtrl,
                            label: '启动参数',
                            hint:
                                '空格分隔，例如 -y @modelcontextprotocol/server-everything',
                            help: '可选；按空格拆成多个参数。',
                          ),
                          _configRowsSection(
                            ctx: ctx,
                            rows: envRows,
                            title: '环境变量（可选，TOKEN / API_KEY 会按密钥保存）',
                            keyHint: 'API_KEY',
                            valueHint: '按 MCP 文档填写',
                            setDialogState: setDialogState,
                          ),
                        ],
                        const SizedBox(height: 14),
                        _guidanceBox(
                          context,
                          '添加后怎么用：添加后直接跟AI 助手说人话就能用，不用学任何标记，'
                          '结果他会自然地告诉你。',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final selectedType = typeNotifier.value;
    typeNotifier.dispose();
    if (saved != true) {
      _disposeRows(headerRows);
      _disposeRows(envRows);
      return;
    }
    final fallbackId = nameCtrl.text.trim();
    final headers = selectedType == 'remote'
        ? _rowsToMap(headerRows)
        : <String, String>{};
    final env = selectedType == 'stdio'
        ? _rowsToMap(envRows)
        : <String, String>{};
    final item = <String, dynamic>{
      'id': idCtrl.text.trim().isEmpty ? fallbackId : idCtrl.text.trim(),
      'name': nameCtrl.text.trim(),
      'type': selectedType,
      'url': urlCtrl.text.trim(),
      'command': cmdCtrl.text.trim(),
      'args': argsCtrl.text
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(),
      'enabled': old?['enabled'] ?? true,
      'source': old?['source'] ?? 'manual',
      'trust_level': old?['trust_level'] ?? 'manual',
      'trust_reason': old?['trust_reason'] ?? '手动添加来源默认仅手动使用。',
    };
    if (headers.isNotEmpty) item['headers'] = headers;
    if (env.isNotEmpty) item['env'] = env;
    // 工具级列表暂不做 UI，由配置接口/手动改 json 维护；编辑时原样保留不丢。
    if (old?['tools'] is List) item['tools'] = old!['tools'];
    _disposeRows(headerRows);
    _disposeRows(envRows);
    final before = _serversSnapshot();
    setState(() {
      if (old == null) {
        _servers.add(item);
      } else {
        _servers[_servers.indexOf(old)] = item;
      }
    });
    await _save(before);
  }

  Future<void> _toggle(Map<String, dynamic> s, bool v) async {
    final before = _serversSnapshot();
    setState(() => s['enabled'] = v);
    await _save(before);
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final before = _serversSnapshot();
    setState(() => _servers.remove(s));
    await _save(before);
  }

  String _serverMetaText(Map<String, dynamic> s) {
    final parts = <String>[
      if (_headersCount(s) > 0) '${_headersCount(s)} 个请求头',
      if (_envCount(s) > 0) '${_envCount(s)} 个环境变量',
      if (_secretCount(s) > 0) '${_secretCount(s)} 个密钥',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 工具'),
        actions: [
          // v0.2.153 修复批次：刷新按钮，重新 GET /mcp-config 拉最新配置
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refresh_ccw),
            tooltip: '刷新',
            onPressed: _loading || _saving ? null : _load,
          ),
          IconButton(
            icon: const Icon(LucideIcons.plus),
            onPressed: _loading || _saving ? null : _addOrEdit,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                if (_servers.isEmpty)
                  _emptyHint(context, '还没有 MCP 工具')
                else
                  for (final s in _servers) _serverCard(s),
              ],
            ),
    );
  }

  Widget _serverCard(Map<String, dynamic> s) {
    final detail = s['url']?.toString().isNotEmpty == true
        ? s['url'].toString()
        : s['command']?.toString() ?? '';
    return _ManageItemCard(
      title: pluginDisplayName(s, fallback: '未命名'),
      meta: _serverMetaText(s),
      detail: detail,
      enabled: s['enabled'] == true,
      onChanged: _saving ? null : (v) => _toggle(s, v),
      actions: [
        IconButton(
          tooltip: '编辑',
          icon: const Icon(LucideIcons.pencil),
          onPressed: _saving ? null : () => _addOrEdit(s),
        ),
        IconButton(
          tooltip: '删除',
          icon: const Icon(LucideIcons.trash_2),
          onPressed: _saving ? null : () => _delete(s),
        ),
      ],
    );
  }
}

class PluginConfigPage extends StatefulWidget {
  const PluginConfigPage({super.key, this.initialPlugin});

  /// 从统一插件列表进入时，加载后直接打开该条配置。
  final Map<String, dynamic>? initialPlugin;

  @override
  State<PluginConfigPage> createState() => _PluginConfigPageState();
}

class _PluginConfigPageState extends State<PluginConfigPage> {
  List<Map<String, dynamic>> _plugins = [];
  bool _loading = true;
  bool _saving = false;
  bool _openedInitialPlugin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await ExtensionConfigApi.plugins();
    if (!mounted) return;
    setState(() {
      _plugins =
          (cfg?['plugins'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _loading = false;
    });
    if (widget.initialPlugin != null && !_openedInitialPlugin) {
      _openedInitialPlugin = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openInitialPlugin());
    }
  }

  Future<void> _openInitialPlugin() async {
    if (!mounted) return;
    final target = _findConfiguredItem(_plugins, widget.initialPlugin!);
    if (target != null) await _addOrEdit(target);
    if (mounted) Navigator.of(context).pop();
  }

  List<Map<String, dynamic>> _pluginsSnapshot() => [
    for (final p in _plugins) Map<String, dynamic>.from(p),
  ];

  Future<bool> _save(List<Map<String, dynamic>> before) async {
    if (_saving) return false;
    if (mounted) setState(() => _saving = true);
    try {
      final cfg = await ExtensionConfigApi.savePlugins(List.of(_plugins));
      if (!mounted) return true;
      final saved = (cfg?['plugins'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .toList();
      setState(() {
        if (saved != null) _plugins = saved;
        _saving = false;
      });
      return true;
    } catch (_) {
      if (!mounted) return false;
      setState(() {
        _plugins = before;
        _saving = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('保存失败，已还原')));
      return false;
    }
  }

  Future<void> _addOrEdit([Map<String, dynamic>? old]) async {
    final idCtrl = TextEditingController(text: old?['id']?.toString() ?? '');
    final nameCtrl = TextEditingController(
      text: old?['name']?.toString() ?? '',
    );
    final descCtrl = TextEditingController(
      text: old?['description']?.toString() ?? '',
    );
    final cmdCtrl = TextEditingController(
      text: old?['command']?.toString() ?? '',
    );
    final argsCtrl = TextEditingController(
      text: (old?['args'] as List<dynamic>? ?? []).join(' '),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(old == null ? '添加命令工具' : '编辑命令工具'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _field(
                  context: ctx,
                  controller: idCtrl,
                  label: '唯一 ID',
                  hint: '例如 local-weather',
                  help: '留空会自动用名称。用于区分同名命令工具。',
                ),
                _field(
                  context: ctx,
                  controller: nameCtrl,
                  label: '名称',
                  hint: '例如：本地天气',
                  help: '给命令工具起一个好认的名字，模型调用时也用这个名字。',
                ),
                _field(
                  context: ctx,
                  controller: descCtrl,
                  label: '描述 / 用途',
                  hint: '例如：查本地天气并返回一段简短文字',
                  help: '告诉AI 助手这个命令工具能做什么、什么时候该用。',
                  maxLines: 2,
                ),
                _field(
                  context: ctx,
                  controller: cmdCtrl,
                  label: '执行命令',
                  hint: '例如 python3 /path/to/plugin.py',
                  help: '可选。填了之后，AI 助手调用命令工具时会执行这个命令。',
                ),
                _field(
                  context: ctx,
                  controller: argsCtrl,
                  label: '启动参数',
                  hint: '空格分隔；可用 {input} 代表调用时传来的参数',
                  help: '可选。例如 --query {input}；不写 {input} 时参数会追加在命令末尾。',
                ),
                const SizedBox(height: 14),
                _guidanceBox(
                  ctx,
                  '添加后怎么用：添加后直接跟AI 助手说人话就能用，不用学任何标记，'
                  '结果他会自然地告诉你。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final fallbackId = nameCtrl.text.trim();
    final item = {
      'id': idCtrl.text.trim().isEmpty ? fallbackId : idCtrl.text.trim(),
      'name': nameCtrl.text.trim(),
      'description': descCtrl.text.trim(),
      'command': cmdCtrl.text.trim(),
      'args': argsCtrl.text
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(),
      'enabled': old?['enabled'] ?? true,
      'installed': old?['installed'] ?? true,
      'source': old?['source'] ?? 'manual',
      'trust_level': old?['trust_level'] ?? 'manual',
      'trust_reason': old?['trust_reason'] ?? '手动添加来源默认仅手动使用。',
    };
    final before = _pluginsSnapshot();
    setState(() {
      if (old == null) {
        _plugins.add(item);
      } else {
        _plugins[_plugins.indexOf(old)] = item;
      }
    });
    await _save(before);
  }

  Future<void> _toggle(Map<String, dynamic> p, bool v) async {
    final before = _pluginsSnapshot();
    setState(() => p['enabled'] = v);
    await _save(before);
  }

  Future<void> _delete(Map<String, dynamic> p) async {
    final before = _pluginsSnapshot();
    setState(() => _plugins.remove(p));
    await _save(before);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('命令工具'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            onPressed: _loading || _saving ? null : () => _addOrEdit(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                if (_plugins.isEmpty)
                  _emptyHint(context, '还没有命令工具')
                else
                  for (final p in _plugins) _commandCard(p),
              ],
            ),
    );
  }

  Widget _commandCard(Map<String, dynamic> p) {
    return _ManageItemCard(
      title: pluginDisplayName(p),
      detail: pluginDisplayDescription(p),
      enabled: p['enabled'] == true,
      onChanged: _saving ? null : (v) => _toggle(p, v),
      actions: [
        IconButton(
          tooltip: '编辑',
          icon: const Icon(LucideIcons.pencil),
          onPressed: _saving ? null : () => _addOrEdit(p),
        ),
        IconButton(
          tooltip: '删除',
          icon: const Icon(LucideIcons.trash_2),
          onPressed: _saving ? null : () => _delete(p),
        ),
      ],
    );
  }
}

class SkillListPage extends StatefulWidget {
  const SkillListPage({super.key});

  @override
  State<SkillListPage> createState() => _SkillListPageState();
}

class _SkillListPageState extends State<SkillListPage> {
  List<Map<String, dynamic>> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await ExtensionConfigApi.skills();
    if (!mounted) return;
    setState(() {
      _skills =
          (cfg?['skills'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _loading = false;
    });
  }

  Future<void> _add() async {
    final nameCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text('添加技能'),
          content: SizedBox(
            width: 430,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: _softInputDecoration(ctx, labelText: '技能名称'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: contentCtrl,
                    maxLines: 8,
                    decoration: _softInputDecoration(
                      ctx,
                      labelText: 'SKILL.md 内容',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (saved != true) return;
      final name = nameCtrl.text.trim();
      final content = contentCtrl.text;
      await ExtensionConfigApi.addSkill(name, content);
      await _load();
    } finally {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          nameCtrl.dispose();
          contentCtrl.dispose();
        }),
      );
    }
  }

  Future<void> _toggle(Map<String, dynamic> s, bool v) async {
    setState(() => s['enabled'] = v);
    await ExtensionConfigApi.setSkillEnabled(s['id']?.toString() ?? '', v);
  }

  Future<void> _openDetail(Map<String, dynamic> s) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SkillDetailPage(skill: s)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('技能'),
        actions: [
          IconButton(icon: const Icon(LucideIcons.plus), onPressed: _add),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                if (_skills.isEmpty)
                  _emptyHint(context, '还没有 Skill')
                else
                  for (final s in _skills) _skillCard(s),
              ],
            ),
    );
  }

  Widget _skillCard(Map<String, dynamic> s) {
    return _ManageItemCard(
      onTap: () => _openDetail(s),
      title: pluginDisplayName(s),
      detail: pluginDisplayDescription(s),
      enabled: s['enabled'] == true,
      onChanged: (v) => _toggle(s, v),
      actions: [
        IconButton(
          tooltip: '查看内容',
          icon: const Icon(LucideIcons.chevron_right),
          onPressed: () => _openDetail(s),
        ),
      ],
    );
  }
}

/// Skill 详情页（v0.2.153，借鉴 RikkaHub SkillDetailPage）：
/// 名称/描述/frontmatter 内容展示 + 启停开关 + 删除。
/// 内容读 GET /skills/{name}（SKILL.md 全文），启停写 PUT /skills/{name}，
/// 删除复用 POST /skills {action: delete}。基准简洁卡片风。
class SkillDetailPage extends StatefulWidget {
  final Map<String, dynamic> skill;

  const SkillDetailPage({super.key, required this.skill});

  @override
  State<SkillDetailPage> createState() => _SkillDetailPageState();
}

class _SkillDetailPageState extends State<SkillDetailPage> {
  late Map<String, dynamic> _skill;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _skill = widget.skill;
    _load();
  }

  Future<void> _load() async {
    final detail = await ExtensionConfigApi.skillDetail(
      widget.skill['id']?.toString() ?? '',
    );
    if (!mounted) return;
    setState(() {
      if (detail != null) {
        _skill = detail;
      } else {
        // 详情拉不到（旧包/临时网络问题）：列表数据兜底
        _skill['content'] = _skill['content'] ?? '';
      }
      _loading = false;
    });
  }

  Future<void> _toggle(bool v) async {
    setState(() => _skill['enabled'] = v);
    await ExtensionConfigApi.setSkillEnabled(_skill['id']?.toString() ?? '', v);
  }

  Future<void> _delete() async {
    final id = _skill['id']?.toString() ?? '';
    final name = pluginDisplayName(_skill, fallback: id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除「$name」？删掉后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ExtensionConfigApi.deleteSkill(id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = pluginDisplayName(_skill);
    final desc = pluginDisplayDescription(_skill);
    final content = _skill['content']?.toString() ?? '';
    final enabled = _skill['enabled'] == true;

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                SettingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Switch(value: enabled, onChanged: _toggle),
                        ],
                      ),
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          desc,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (content.isNotEmpty)
                  SettingCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SKILL.md',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        SelectableText(
                          content,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: _delete,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: const StadiumBorder(),
                      foregroundColor: theme.colorScheme.error,
                      side: BorderSide(
                        color: theme.colorScheme.error.withValues(alpha: 0.5),
                      ),
                    ),
                    icon: const Icon(LucideIcons.trash_2, size: 18),
                    label: const Text('删除'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
    );
  }
}
