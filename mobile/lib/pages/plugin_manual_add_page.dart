import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';

/// 添加页里的次级动作：手动添加 MCP，或通过现有 /skills API 导入
/// SKILL.md 内容。服务端没有通用插件文件导入 API，因此不展示伪入口。
/// 保存复用现有接口：MCP → POST /mcp-config（先读再合并），
/// Skill → POST /skills {action:add}。
class PluginManualAddPage extends StatefulWidget {
  const PluginManualAddPage({super.key, this.initialType = 'mcp'})
    : assert(initialType == 'mcp' || initialType == 'skill');

  final String initialType;

  @override
  State<PluginManualAddPage> createState() => _PluginManualAddPageState();
}

class _ManualConfigRow {
  _ManualConfigRow()
    : keyCtrl = TextEditingController(),
      valueCtrl = TextEditingController();

  final TextEditingController keyCtrl;
  final TextEditingController valueCtrl;

  void dispose() {
    keyCtrl.dispose();
    valueCtrl.dispose();
  }
}

class _PluginManualAddPageState extends State<PluginManualAddPage> {
  late final String _type;
  bool _saving = false;

  // MCP 表单
  final TextEditingController _mcpNameCtrl = TextEditingController();
  final TextEditingController _mcpIdCtrl = TextEditingController();
  final TextEditingController _mcpUrlCtrl = TextEditingController();
  final TextEditingController _mcpCmdCtrl = TextEditingController();
  final TextEditingController _mcpArgsCtrl = TextEditingController();
  String _mcpConn = 'remote';
  final List<_ManualConfigRow> _headerRows = [_ManualConfigRow()];
  final List<_ManualConfigRow> _envRows = [_ManualConfigRow()];

  // Skill 表单
  final TextEditingController _skillNameCtrl = TextEditingController();
  final TextEditingController _skillContentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    _mcpNameCtrl.dispose();
    _mcpIdCtrl.dispose();
    _mcpUrlCtrl.dispose();
    _mcpCmdCtrl.dispose();
    _mcpArgsCtrl.dispose();
    _skillNameCtrl.dispose();
    _skillContentCtrl.dispose();
    for (final row in [..._headerRows, ..._envRows]) {
      row.dispose();
    }
    super.dispose();
  }

  Map<String, String> _rowsToMap(List<_ManualConfigRow> rows) {
    final out = <String, String>{};
    for (final row in rows) {
      final key = row.keyCtrl.text.trim();
      if (key.isEmpty) continue;
      out[key] = row.valueCtrl.text.trim();
    }
    return out;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (_type == 'mcp') {
        final name = _mcpNameCtrl.text.trim();
        if (name.isEmpty) {
          _toast('MCP 名称不能为空');
          return;
        }
        if (_mcpConn == 'remote' && _mcpUrlCtrl.text.trim().isEmpty) {
          _toast('HTTP 地址不能为空');
          return;
        }
        if (_mcpConn == 'stdio' && _mcpCmdCtrl.text.trim().isEmpty) {
          _toast('启动命令不能为空');
          return;
        }
        final cfg = await ExtensionConfigApi.mcp();
        final servers =
            (cfg?['servers'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            [];
        final id = _mcpIdCtrl.text.trim().isEmpty
            ? name
            : _mcpIdCtrl.text.trim();
        final item = <String, dynamic>{
          'id': id,
          'name': name,
          'type': _mcpConn,
          'url': _mcpUrlCtrl.text.trim(),
          'command': _mcpCmdCtrl.text.trim(),
          'args': _mcpArgsCtrl.text
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .toList(),
          'enabled': true,
          'source': 'manual',
          'trust_level': 'manual',
          'trust_reason': '手动添加来源默认仅手动使用。',
        };
        if (_mcpConn == 'remote') {
          final headers = _rowsToMap(_headerRows);
          if (headers.isNotEmpty) item['headers'] = headers;
        } else {
          final env = _rowsToMap(_envRows);
          if (env.isNotEmpty) item['env'] = env;
        }
        servers.removeWhere((s) {
          final serverId = s['id']?.toString().trim() ?? '';
          final serverName = s['name']?.toString().trim() ?? '';
          return serverId == id || serverName == name;
        });
        servers.add(item);
        await ExtensionConfigApi.saveMcp(servers);
      } else {
        final name = _skillNameCtrl.text.trim();
        final content = _skillContentCtrl.text.trim();
        if (name.isEmpty || content.isEmpty) {
          _toast('Skill 名称和内容都不能为空');
          return;
        }
        // 没有 frontmatter 时自动包一层，保证「我的插件」里能正常显示名字
        final body = content.startsWith('---')
            ? content
            : '---\nname: $name\ndescription: $name 技能\n---\n\n$content';
        await ExtensionConfigApi.addSkill(name, body);
      }
      if (!mounted) return;
      Navigator.of(context).pop({
        'type': _type,
        'message': _type == 'mcp' ? 'MCP 已保存' : 'Skill 已导入',
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_type == 'mcp' ? '手动添加 MCP' : '导入 Skill')),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          if (_type == 'mcp')
            ..._mcpForm(Theme.of(context))
          else
            ..._skillForm(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                shape: const StadiumBorder(),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.plus, size: 18),
              label: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _mcpForm(ThemeData theme) {
    return [
      _field(_mcpNameCtrl, '名称', '例如：天气查询', '给工具起一个好认的名字。'),
      _field(_mcpIdCtrl, '唯一 ID（可选）', '例如 weather-mcp', '留空自动用名称，用于区分同名工具。'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('HTTP 服务'),
              selected: _mcpConn == 'remote',
              onSelected: (_) => setState(() => _mcpConn = 'remote'),
            ),
            ChoiceChip(
              label: const Text('本地命令'),
              selected: _mcpConn == 'stdio',
              onSelected: (_) => setState(() => _mcpConn = 'stdio'),
            ),
          ],
        ),
      ),
      if (_mcpConn == 'remote') ...[
        _field(
          _mcpUrlCtrl,
          'HTTP 地址',
          'https://example.com/mcp',
          'AI 助手会向这里发工具调用请求。',
        ),
        _configRowsSection(
          theme: theme,
          title: '请求头（可选，Authorization / x-api-key 会按密钥保存）',
          rows: _headerRows,
          keyHint: 'Authorization',
          valueHint: 'Bearer ...',
        ),
      ] else ...[
        _field(
          _mcpCmdCtrl,
          '启动命令',
          '例如 npx 或 /path/to/mcp-server',
          'AI 助手会启动这个命令，通过 stdin/stdout 跟它通信。',
        ),
        _field(
          _mcpArgsCtrl,
          '启动参数',
          '空格分隔，例如 -y @modelcontextprotocol/server-everything',
          '可选；按空格拆成多个参数。',
        ),
        _configRowsSection(
          theme: theme,
          title: '环境变量（可选，TOKEN / API_KEY 会按密钥保存）',
          rows: _envRows,
          keyHint: 'API_KEY',
          valueHint: '按 MCP 文档填写',
        ),
      ],
    ];
  }

  List<Widget> _skillForm() {
    return [
      _field(_skillNameCtrl, '名称', '例如：ui-taste', '文件夹名，只含字母/数字/._-。'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: TextField(
          controller: _skillContentCtrl,
          minLines: 8,
          maxLines: 18,
          decoration: _inputDecoration(
            labelText: 'SKILL.md 内容',
            hintText: '写清楚这个技能是什么、什么时候用、怎么做…',
            alignLabelWithHint: true,
          ),
        ),
      ),
    ];
  }

  Widget _configRowsSection({
    required ThemeData theme,
    required String title,
    required List<_ManualConfigRow> rows,
    required String keyHint,
    required String valueHint,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
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
                onPressed: () => setState(() => rows.add(_ManualConfigRow())),
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
                    decoration: _inputDecoration(
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
                      return TextField(
                        controller: rows[i].valueCtrl,
                        obscureText: secret,
                        decoration: _inputDecoration(
                          labelText: secret ? '密钥' : '值',
                          hintText: secret ? '保存后只显示已配置' : valueHint,
                        ),
                      );
                    },
                  );
                  final removeButton = IconButton(
                    icon: const Icon(LucideIcons.x, size: 18),
                    tooltip: '删除这一行',
                    onPressed: rows.length == 1
                        ? null
                        : () => setState(() {
                            final row = rows.removeAt(i);
                            row.dispose();
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
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint,
    String help,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: controller,
        decoration: _inputDecoration(
          labelText: label,
          hintText: hint,
          helperText: help,
          helperMaxLines: 2,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String labelText,
    required String hintText,
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
}
