import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';
import 'extensions_pages.dart';
import 'plugin_market_page.dart';

/// 已安装插件的统一管理页。
/// MCP / Skill / 命令工具共用一条列表，点击条目直达编辑或详情。
/// 基准简洁卡片风：圆角 20 + 柔和阴影 + cardColor 底。
class MyPluginsPage extends StatefulWidget {
  const MyPluginsPage({super.key});

  @override
  State<MyPluginsPage> createState() => _MyPluginsPageState();
}

class _MyPluginsPageState extends State<MyPluginsPage> {
  /// 内置 MCP 服务的中文显示名（v0.2.181 汉化：配置里保持英文 id/name，
  /// 界面展示用中文，避免"内置还全是英文"）。
  static String _displayName(String raw) {
    return switch (raw.trim()) {
      'nowhere' => '旅行记录',
      'lutopia' => '路托邦论坛',
      'Termux' => 'Termux（手机终端）',
      _ => raw,
    };
  }

  List<Map<String, dynamic>> _mcp = [];
  List<Map<String, dynamic>> _commands = [];
  List<Map<String, dynamic>> _skills = [];
  final Set<String> _pendingItems = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final results = await Future.wait([
      ExtensionConfigApi.mcp(),
      ExtensionConfigApi.plugins(),
      ExtensionConfigApi.skills(),
    ]);
    if (!mounted) return;
    setState(() {
      _mcp =
          (results[0]?['servers'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _commands =
          (results[1]?['plugins'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _skills =
          (results[2]?['skills'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          [];
      _loading = false;
    });
  }

  Future<void> _toggleMcp(Map<String, dynamic> s, bool v) async {
    final key = _pendingKey('mcp', s);
    if (_pendingItems.contains(key)) return;
    final oldValue = s['enabled'] == true;
    setState(() {
      _pendingItems.add(key);
      s['enabled'] = v;
    });
    try {
      final data = await ExtensionConfigApi.saveMcp(List.of(_mcp));
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'saveMcp returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => s['enabled'] = oldValue);
        _showSnack('MCP 启停保存失败，已恢复原状态');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<void> _toggleCommand(Map<String, dynamic> p, bool v) async {
    final key = _pendingKey('command', p);
    if (_pendingItems.contains(key)) return;
    final oldValue = p['enabled'] == true;
    setState(() {
      _pendingItems.add(key);
      p['enabled'] = v;
    });
    try {
      final data = await ExtensionConfigApi.savePlugins(List.of(_commands));
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'savePlugins returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => p['enabled'] = oldValue);
        _showSnack('命令工具启停保存失败，已恢复原状态');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<void> _toggleSkill(Map<String, dynamic> s, bool v) async {
    final key = _pendingKey('skill', s);
    if (_pendingItems.contains(key)) return;
    final oldValue = s['enabled'] == true;
    setState(() {
      _pendingItems.add(key);
      s['enabled'] = v;
    });
    try {
      final data = await ExtensionConfigApi.setSkillEnabled(
        s['id']?.toString() ?? '',
        v,
      );
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'setSkillEnabled returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => s['enabled'] = oldValue);
        _showSnack('Skill 启停保存失败，已恢复原状态');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<bool> _confirmDelete(String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除插件'),
            content: Text('确定删除「$name」？'),
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
        ) ??
        false;
  }

  Future<void> _deleteMcp(Map<String, dynamic> s) async {
    final key = _pendingKey('mcp', s);
    if (_pendingItems.contains(key)) return;
    final name = _displayName(
      s['name']?.toString() ?? s['id']?.toString() ?? '',
    );
    if (!await _confirmDelete(name)) return;
    final index = _mcp.indexOf(s);
    if (index < 0) return;
    setState(() {
      _pendingItems.add(key);
      _mcp.removeAt(index);
    });
    try {
      final data = await ExtensionConfigApi.saveMcp(List.of(_mcp));
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'saveMcp returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _mcp.insert(_restoreIndex(index, _mcp.length), s));
        _showSnack('MCP 删除保存失败，已恢复条目');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<void> _deleteCommand(Map<String, dynamic> p) async {
    final key = _pendingKey('command', p);
    if (_pendingItems.contains(key)) return;
    final name = p['name']?.toString() ?? p['id']?.toString() ?? '';
    if (!await _confirmDelete(name)) return;
    final index = _commands.indexOf(p);
    if (index < 0) return;
    setState(() {
      _pendingItems.add(key);
      _commands.removeAt(index);
    });
    try {
      final data = await ExtensionConfigApi.savePlugins(List.of(_commands));
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'savePlugins returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _commands.insert(_restoreIndex(index, _commands.length), p),
        );
        _showSnack('命令工具删除保存失败，已恢复条目');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<void> _deleteSkill(Map<String, dynamic> s) async {
    final key = _pendingKey('skill', s);
    if (_pendingItems.contains(key)) return;
    final name = _displayName(
      s['name']?.toString() ?? s['id']?.toString() ?? '',
    );
    if (!await _confirmDelete(name)) return;
    final index = _skills.indexOf(s);
    if (index < 0) return;
    setState(() {
      _pendingItems.add(key);
      _skills.removeAt(index);
    });
    try {
      final data = await ExtensionConfigApi.deleteSkill(
        s['id']?.toString() ?? '',
      );
      if (!_isSuccessfulSave(data)) {
        throw Exception(
          'deleteSkill returned ${data == null ? 'null' : 'ok=false'}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _skills.insert(_restoreIndex(index, _skills.length), s));
        _showSnack('Skill 删除失败，已恢复条目');
      }
    } finally {
      if (mounted) setState(() => _pendingItems.remove(key));
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(SwipeBackRoute(builder: (_) => page));
    if (mounted) await _load();
  }

  Future<void> _openMarket() async {
    final result = await Navigator.of(
      context,
    ).push<Object?>(SwipeBackRoute(builder: (_) => const PluginMarketPage()));
    if (!mounted) return;
    await _load();
    if (!mounted || result is! Map) return;
    final message = result['message']?.toString().trim() ?? '';
    if (message.isNotEmpty) _showSnack(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        actions: [
          IconButton(
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refresh_ccw),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: '添加插件',
            onPressed: _loading ? null : _openMarket,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                for (final s in _mcp) _mcpRow(s),
                for (final s in _skills) _skillRow(s),
                for (final p in _commands) _commandRow(p),
                if (_mcp.isEmpty && _skills.isEmpty && _commands.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 32,
                      horizontal: 20,
                    ),
                    child: Column(
                      children: [
                        Text(
                          '还没有安装插件',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _openMarket,
                          icon: const Icon(LucideIcons.plus, size: 18),
                          label: const Text('添加插件'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
              ],
            ),
    );
  }

  Widget _mcpRow(Map<String, dynamic> s) {
    final name = _displayName(
      s['name']?.toString() ?? s['id']?.toString() ?? '',
    );
    final busy = _isPending('mcp', s);
    void edit() => _push(McpConfigPage(initialPlugin: s));
    return _pluginRow(
      onTap: edit,
      icon: LucideIcons.cable,
      title: name,
      typeLabel: 'MCP',
      enabled: s['enabled'] == true,
      onChanged: busy ? null : (v) => _toggleMcp(s, v),
      busy: busy,
      onEdit: edit,
      onDelete: () => _deleteMcp(s),
    );
  }

  Widget _skillRow(Map<String, dynamic> s) {
    final name = _displayName(
      s['name']?.toString() ?? s['id']?.toString() ?? '',
    );
    final busy = _isPending('skill', s);
    void edit() => _push(SkillDetailPage(skill: s));
    return _pluginRow(
      onTap: edit,
      icon: LucideIcons.book_open,
      title: name,
      typeLabel: 'Skill',
      enabled: s['enabled'] == true,
      onChanged: busy ? null : (v) => _toggleSkill(s, v),
      busy: busy,
      onEdit: edit,
      onDelete: () => _deleteSkill(s),
    );
  }

  Widget _commandRow(Map<String, dynamic> p) {
    final name = p['name']?.toString() ?? p['id']?.toString() ?? '';
    final busy = _isPending('command', p);
    void edit() => _push(PluginConfigPage(initialPlugin: p));
    return _pluginRow(
      onTap: edit,
      icon: LucideIcons.terminal,
      title: name,
      typeLabel: '命令',
      enabled: p['enabled'] == true,
      onChanged: busy ? null : (v) => _toggleCommand(p, v),
      busy: busy,
      onEdit: edit,
      onDelete: () => _deleteCommand(p),
    );
  }

  Widget _pluginRow({
    required IconData icon,
    required String title,
    required String typeLabel,
    required bool enabled,
    required ValueChanged<bool>? onChanged,
    required bool busy,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return SettingCard(
      onTap: onTap,
      child: Row(
        children: [
          _typeIcon(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: context.fieldColor,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      child: Text(
                        typeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
          PopupMenuButton<_PluginAction>(
            tooltip: '更多操作',
            enabled: !busy,
            onSelected: (action) {
              switch (action) {
                case _PluginAction.edit:
                  onEdit();
                case _PluginAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: _PluginAction.edit, child: Text('编辑')),
              PopupMenuItem(value: _PluginAction.delete, child: Text('删除')),
            ],
            icon: Icon(
              LucideIcons.ellipsis_vertical,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeIcon(IconData icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  bool _isPending(String type, Map<String, dynamic> item) =>
      _pendingItems.contains(_pendingKey(type, item));

  String _pendingKey(String type, Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final name = item['name']?.toString() ?? '';
    final raw = id.isNotEmpty ? id : name;
    return '$type:${raw.isEmpty ? identityHashCode(item) : raw}';
  }

  bool _isSuccessfulSave(Map<String, dynamic>? data) =>
      data != null && data['ok'] != false;

  int _restoreIndex(int index, int length) {
    if (index < 0) return 0;
    if (index > length) return length;
    return index;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _PluginAction { edit, delete }
