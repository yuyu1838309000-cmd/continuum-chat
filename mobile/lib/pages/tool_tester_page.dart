import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 工具测试器（v0.2.153，借鉴 Operit ToolTester）：
/// 选一个已配置的 MCP server（读 mcp_config）+ 填工具名和参数 JSON →
/// 8816 POST /mcp/test 真实调用一次（复用 remote/stdio MCP 调用，不落库不注入对话），
/// 结果原样展示。纯测试，不改任何配置。
/// 基准简洁卡片：圆角 20 + 柔和阴影 + cardColor 底。
class ToolTesterPage extends StatefulWidget {
  /// 打开时就选中的 MCP server（「我的插件」里按插件直接带进来测试），
  /// 空则默认选列表第一个，和旧行为一致。
  final String? initialServerName;

  const ToolTesterPage({super.key, this.initialServerName});

  @override
  State<ToolTesterPage> createState() => _ToolTesterPageState();
}

class _ToolTesterPageState extends State<ToolTesterPage> {
  List<Map<String, dynamic>> _servers = [];
  List<Map<String, dynamic>> _skills = [];
  List<Map<String, dynamic>> _commands = [];
  String? _serverName;
  String? _skillName;
  String? _commandName;
  // v0.2.153 修复批次：工具名改为下拉（选 server 后自动拉 tools/list），
  // 修复手填 server 名导致的「Unknown tool」
  List<Map<String, dynamic>> _tools = [];
  String? _toolName;
  bool _toolsLoading = false;
  String? _toolsError;
  final TextEditingController _argsCtrl = TextEditingController(text: '{}');
  final TextEditingController _commandArgsCtrl = TextEditingController(
    text: '{}',
  );
  bool _loading = true;
  bool _testing = false;
  bool _skillLoading = false;
  bool _commandTesting = false;
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _commandResult;
  String _skillContent = '';
  String? _resultError;
  String? _commandError;
  int _loadRequestId = 0;
  int _toolsRequestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _argsCtrl.dispose();
    _commandArgsCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_loadRequestId;
    if (mounted) setState(() => _loading = true);
    final results = await Future.wait([
      ExtensionConfigApi.mcp(),
      ExtensionConfigApi.skills(),
      ExtensionConfigApi.plugins(),
    ]);
    if (!mounted || requestId != _loadRequestId) return;
    final cfg = results[0];
    final servers =
        (cfg?['servers'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    final skills =
        (results[1]?['skills'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    final commands =
        (results[2]?['plugins'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    final wanted = widget.initialServerName;
    final nextServerName =
        wanted != null && servers.any((s) => s['name']?.toString() == wanted)
        ? wanted
        : servers.isNotEmpty
        ? servers.first['name']?.toString()
        : null;
    final nextSkillName = skills.isNotEmpty
        ? skills.first['id']?.toString()
        : null;
    final nextCommandName = commands.isNotEmpty
        ? commands.first['name']?.toString()
        : null;
    setState(() {
      _servers = servers;
      _skills = skills;
      _commands = commands;
      _serverName = nextServerName;
      _skillName = nextSkillName;
      _commandName = nextCommandName;
      _tools = [];
      _toolName = null;
      _toolsError = null;
      _result = null;
      _resultError = null;
      _loading = false;
    });
    unawaited(_loadToolsFor(nextServerName));
    if (nextSkillName != null) unawaited(_loadSkillDetail());
  }

  void _onServerChanged(String? name) {
    setState(() {
      _serverName = name;
      _tools = [];
      _toolName = null;
      _toolsError = null;
      _result = null;
      _resultError = null;
    });
    unawaited(_loadToolsFor(name));
  }

  /// 选 server 后自动拉工具列表（GET /mcp/tools），失败显示可读错误。
  Future<void> _loadTools() => _loadToolsFor(_serverName);

  Future<void> _loadToolsFor(String? serverName) async {
    final requestId = ++_toolsRequestId;
    if (serverName == null || serverName.isEmpty) {
      if (!mounted) return;
      setState(() {
        _toolsLoading = false;
        _toolsError = null;
        _tools = [];
        _toolName = null;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _toolsLoading = true;
      _toolsError = null;
    });
    final data = await ExtensionConfigApi.mcpToolsResult(serverName);
    if (!mounted || requestId != _toolsRequestId || _serverName != serverName) {
      return;
    }
    setState(() {
      _toolsLoading = false;
      if (data == null) {
        _toolsError = '拉取工具列表失败：网络不可达或 8816 连不上';
        _tools = [];
        _toolName = null;
      } else if (data['status'] == 404) {
        _toolsError = 'Server 不存在：${_diagnosticMessage(data, '拉取工具列表失败')}';
        _tools = [];
        _toolName = null;
      } else if (data['ok'] != true) {
        _toolsError = _diagnosticMessage(data, '拉取工具列表失败');
        _tools = [];
        _toolName = null;
      } else {
        final tools =
            (data['tools'] as List<dynamic>?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            [];
        _tools = tools;
        _toolName = tools.isNotEmpty ? tools.first['name']?.toString() : null;
      }
    });
  }

  Future<void> _test() async {
    final serverName = _serverName;
    final toolName = _toolName;
    if (serverName == null || serverName.isEmpty) {
      _showResultError('先选一个 MCP server');
      return;
    }
    if (toolName == null || toolName.isEmpty) {
      _showResultError('先选工具名（server 没拉到工具列表就选不了）');
      return;
    }
    final arguments = _parseArgs(_argsCtrl);
    if (arguments == null) return;
    setState(() {
      _testing = true;
      _result = null;
      _resultError = null;
    });
    final data = await ExtensionConfigApi.testMcp(
      serverName: serverName,
      toolName: toolName,
      arguments: arguments,
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (data == null) {
        _resultError = '测试请求失败：网络不可达或 8816 连不上';
      } else if (data['ok'] == true) {
        _result = data;
      } else if (data['status'] == 404) {
        _resultError = 'Server 或工具不存在：${_diagnosticMessage(data, '调用失败')}';
      } else {
        _resultError = '工具调用失败：${_diagnosticMessage(data, '调用失败')}';
      }
    });
  }

  Map<String, dynamic>? _parseArgs(TextEditingController ctrl) {
    try {
      final parsed = jsonDecode(
        ctrl.text.trim().isEmpty ? '{}' : ctrl.text.trim(),
      );
      if (parsed is! Map) {
        _showResultError('参数要是 JSON 对象，例如 {"key": "value"}');
        return null;
      }
      return parsed.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      _showResultError('参数 JSON 解析失败，检查格式');
      return null;
    }
  }

  Future<void> _loadSkillDetail() async {
    final name = _skillName;
    if (name == null || name.isEmpty) return;
    setState(() {
      _skillLoading = true;
      _skillContent = '';
    });
    final data = await ExtensionConfigApi.skillDetail(name);
    if (!mounted || _skillName != name) return;
    setState(() {
      _skillLoading = false;
      _skillContent = data?['content']?.toString() ?? '';
    });
  }

  Future<void> _testCommand() async {
    final name = _commandName;
    if (name == null || name.isEmpty) {
      setState(() => _commandError = '先选一个命令工具');
      return;
    }
    final arguments = _parseCommandArgs();
    if (arguments == null) return;
    setState(() {
      _commandTesting = true;
      _commandResult = null;
      _commandError = null;
    });
    final data = await ExtensionConfigApi.testCommand(
      name: name,
      arguments: arguments,
    );
    if (!mounted) return;
    setState(() {
      _commandTesting = false;
      if (data == null) {
        _commandError = '测试请求失败：网络不可达或 8816 连不上';
      } else if (data['ok'] == true) {
        _commandResult = data;
      } else {
        _commandError = '命令调用失败：${_diagnosticMessage(data, '调用失败')}';
      }
    });
  }

  Map<String, dynamic>? _parseCommandArgs() {
    try {
      final parsed = jsonDecode(
        _commandArgsCtrl.text.trim().isEmpty
            ? '{}'
            : _commandArgsCtrl.text.trim(),
      );
      if (parsed is! Map) {
        setState(() => _commandError = '参数要是 JSON 对象，例如 {"key": "value"}');
        return null;
      }
      return parsed.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      setState(() => _commandError = '参数 JSON 解析失败，检查格式');
      return null;
    }
  }

  void _showResultError(String msg) {
    if (!mounted) return;
    setState(() {
      _result = null;
      _resultError = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('工具测试')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                SettingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MCP server',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        // 换 server 时强制重建（initialValue 只在首次生效）
                        key: ValueKey(_serverName),
                        initialValue: _serverName,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final s in _servers)
                            DropdownMenuItem(
                              value: s['name']?.toString(),
                              child: Text(s['name']?.toString() ?? ''),
                            ),
                        ],
                        onChanged: _onServerChanged,
                      ),
                    ],
                  ),
                ),
                // v0.2.153 修复批次：工具名下拉（选 server 后自动拉 tools/list）
                SettingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '工具名',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_toolsLoading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text('拉取工具列表…', style: TextStyle(fontSize: 13)),
                            ],
                          ),
                        )
                      else if (_toolsError != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _toolsError!,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: _loadTools,
                              icon: const Icon(
                                LucideIcons.refresh_ccw,
                                size: 16,
                              ),
                              label: const Text('重试'),
                            ),
                          ],
                        )
                      else if (_tools.isEmpty)
                        Text(
                          '这个 server 当前没有可测试工具',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        )
                      else ...[
                        DropdownButtonFormField<String>(
                          key: ValueKey(_toolName),
                          initialValue: _toolName,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final t in _tools)
                              DropdownMenuItem(
                                value: t['name']?.toString(),
                                child: Text(t['name']?.toString() ?? ''),
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            _toolName = v;
                            _result = null;
                            _resultError = null;
                          }),
                        ),
                        // 选中工具的描述提示（可选，有就给一行）
                        if (_toolDescription(_toolName) case final String desc
                            when desc.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            desc,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                SettingCard(
                  child: TextField(
                    controller: _argsCtrl,
                    minLines: 3,
                    maxLines: 8,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    decoration: const InputDecoration(
                      labelText: '参数 JSON',
                      hintText: '{"key": "value"}',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: FilledButton.icon(
                    onPressed: _testing ? null : _test,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: const StadiumBorder(),
                    ),
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.flask_conical, size: 18),
                    label: Text(_testing ? '测试中…' : '发送测试调用'),
                  ),
                ),
                if (_resultError != null)
                  SettingCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.circle_alert,
                              size: 18,
                              color: theme.colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '调用失败',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SelectableText(
                          _resultError!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_result != null)
                  SettingCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.circle_check,
                              size: 18,
                              color: context.accentColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '返回结果',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SelectableText(
                          _result!['result']?.toString() ?? '（空结果）',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                SettingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            LucideIcons.book_open,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Skill 内容',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        key: ValueKey(_skillName),
                        initialValue: _skillName,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final s in _skills)
                            DropdownMenuItem(
                              value: s['id']?.toString(),
                              child: Text(
                                s['name']?.toString() ??
                                    s['id']?.toString() ??
                                    '',
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          setState(() => _skillName = v);
                          _loadSkillDetail();
                        },
                      ),
                      const SizedBox(height: 10),
                      if (_skillLoading)
                        const LinearProgressIndicator(minHeight: 2)
                      else if (_skillContent.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 260),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.fieldColor,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              _skillContent,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          _skills.isEmpty ? '还没有 Skill' : '这个 Skill 没有内容',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                SettingCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            LucideIcons.terminal,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '命令工具',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        key: ValueKey(_commandName),
                        initialValue: _commandName,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final p in _commands)
                            DropdownMenuItem(
                              value: p['name']?.toString(),
                              child: Text(p['name']?.toString() ?? ''),
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _commandName = v;
                          _commandResult = null;
                          _commandError = null;
                        }),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _commandArgsCtrl,
                        minLines: 2,
                        maxLines: 6,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                        decoration: const InputDecoration(
                          labelText: '参数 JSON',
                          hintText: '{"input": "hello"}',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _commandTesting || _commands.isEmpty
                            ? null
                            : _testCommand,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: const StadiumBorder(),
                        ),
                        icon: _commandTesting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.flask_conical, size: 18),
                        label: Text(_commandTesting ? '调用中…' : '真调用一次'),
                      ),
                      if (_commandError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _commandError!,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                      if (_commandResult != null) ...[
                        const SizedBox(height: 10),
                        SelectableText(
                          _commandResult!['result']?.toString() ?? '（空结果）',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
    );
  }

  String _toolDescription(String? name) {
    if (name == null) return '';
    for (final t in _tools) {
      if (t['name'] == name) {
        return t['description']?.toString() ?? '';
      }
    }
    return '';
  }

  String _diagnosticMessage(Map<String, dynamic> data, String fallback) {
    final status = data['status'];
    final raw =
        data['error'] ?? data['message'] ?? data['detail'] ?? data['result'];
    final text = raw?.toString().trim();
    final statusText = status == null ? '' : 'HTTP $status';
    if (text != null && text.isNotEmpty) {
      return statusText.isEmpty ? text : '$statusText：$text';
    }
    return statusText.isEmpty ? fallback : '$statusText：$fallback';
  }
}
