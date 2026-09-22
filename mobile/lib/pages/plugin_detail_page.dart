import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/plugin_display.dart';
import '../widgets/setting_card.dart';

/// 插件详情页：完整描述 / 作者 / 版本 / 配置项 / 依赖 / 安装状态。
class PluginDetailPage extends StatefulWidget {
  final String id;
  final String source;
  final Map<String, dynamic>? initial;

  const PluginDetailPage({
    super.key,
    required this.id,
    required this.source,
    this.initial,
  });

  @override
  State<PluginDetailPage> createState() => _PluginDetailPageState();
}

class _PluginDetailPageState extends State<PluginDetailPage> {
  Map<String, dynamic>? _plugin;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _plugin = widget.initial == null ? null : Map.of(widget.initial!);
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final data = await ExtensionConfigApi.marketDetail(
      source: widget.source,
      id: widget.id,
    );
    if (!mounted) return;
    setState(() {
      final plugin = data?['plugin'];
      if (data != null &&
          data['ok'] == true &&
          plugin is Map<String, dynamic>) {
        _plugin = plugin;
        _error = null;
      } else {
        _error = data?['error']?.toString() ?? '插件详情加载失败';
      }
      _loading = false;
    });
  }

  Future<void> _install() async {
    if (_busy) return;
    setState(() => _busy = true);
    final data = await ExtensionConfigApi.installMarketPlugin(
      widget.id,
      source: widget.source,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (data == null) {
      _snack('安装失败，服务器没回应');
      return;
    }
    if (data['ok'] == true) {
      _snack(data['already_installed'] == true ? '已经装过了' : '已安装');
      Navigator.of(context).pop(true);
      return;
    }
    _snack(data['error']?.toString() ?? '安装失败');
  }

  Future<void> _uninstall() async {
    if (_busy) return;
    final name = _displayName();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('确定卸载「$name」？装好的配置会一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    final data = await ExtensionConfigApi.uninstallMarketPlugin(
      widget.id,
      source: widget.source,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (data == null || data['ok'] != true) {
      _snack(data?['error']?.toString() ?? '卸载失败，服务器没回应');
      return;
    }
    _snack('已卸载');
    Navigator.of(context).pop(true);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _text(String key) => _plugin?[key]?.toString().trim() ?? '';

  String _source() {
    final source = _text('source').toLowerCase();
    return source.isEmpty ? widget.source.toLowerCase() : source;
  }

  String _sourceLabel() => pluginSourceLabel(_source());

  String _displayName() => pluginDisplayName(
    _plugin ?? const <String, dynamic>{},
    fallback: widget.id,
  );

  String _displayDescription() {
    final plugin = _plugin;
    if (plugin == null) return '';
    return pluginDisplayDescription(plugin);
  }

  IconData _sourceIcon() => switch (_source()) {
    'manual' => LucideIcons.hand,
    'internal' || 'local' => LucideIcons.shield_check,
    _ => LucideIcons.puzzle,
  };

  String _trustLevel() {
    final source = _source();
    if (source == 'internal' || source == 'local') return 'trusted';
    final level = _text('trust_level').toLowerCase();
    if (level == 'trusted' || level == 'partial' || level == 'manual') {
      return level;
    }
    return source == 'manual' ? 'manual' : 'partial';
  }

  String _trustLabel() {
    final source = _source();
    if (source == 'internal' || source == 'local') return '内部维护';
    return switch (_trustLevel()) {
      'trusted' => '平台来源',
      'manual' => '手动添加',
      _ => '社区来源',
    };
  }

  IconData _trustIcon() => switch (_trustLevel()) {
    'trusted' => LucideIcons.shield_check,
    'manual' => LucideIcons.hand,
    _ => LucideIcons.shield_alert,
  };

  String _trustDescription() {
    final reason = _text('trust_reason');
    if (reason.isNotEmpty) return reason;
    final source = _source();
    if (source == 'internal' || source == 'local') {
      return '内部维护条目；来源标签不影响工具执行。';
    }
    return switch (_trustLevel()) {
      'trusted' => '平台或高信誉来源；来源标签不影响工具执行。',
      'manual' => '手动添加来源；来源标签不影响工具执行。',
      _ => '社区来源条目；来源标签不影响工具执行。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = _plugin;
    final description = _displayDescription();

    return Scaffold(
      appBar: AppBar(
        title: const Text('插件详情'),
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
        ],
      ),
      bottomNavigationBar: plugin == null
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: _actionButton(theme),
            ),
      body: _loading && plugin == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && plugin == null
          ? _errorBody(theme)
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                _headerCard(theme),
                if (description.isNotEmpty)
                  _textCard(
                    theme,
                    title: '完整描述',
                    icon: LucideIcons.file_text,
                    text: description,
                  ),
                _textCard(
                  theme,
                  title: '信任级别',
                  icon: _trustIcon(),
                  text: '${_trustLabel()}\n${_trustDescription()}',
                ),
                _textCard(
                  theme,
                  title: '配置项',
                  icon: LucideIcons.sliders_horizontal,
                  text: _text('config').isEmpty ? '未提供配置项。' : _text('config'),
                ),
                _textCard(
                  theme,
                  title: '依赖',
                  icon: LucideIcons.package_check,
                  text: _text('dependencies').isEmpty
                      ? '未提供依赖说明。'
                      : _text('dependencies'),
                ),
                _toolsCard(theme),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  Widget _errorBody(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(LucideIcons.refresh_ccw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerCard(ThemeData theme) {
    final name = _displayName();
    final author = _text('author');
    final version = _text('version');
    final installed = _plugin?['installed'] == true;

    return SettingCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.62,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              _sourceIcon(),
              size: 22,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
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
                    const SizedBox(width: 8),
                    _tag(_sourceLabel()),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    if (author.isNotEmpty) _metaChip(LucideIcons.user, author),
                    if (version.isNotEmpty)
                      _metaChip(LucideIcons.git_branch, version),
                    _metaChip(_trustIcon(), _trustLabel()),
                    _metaChip(
                      installed
                          ? LucideIcons.circle_check
                          : LucideIcons.download,
                      installed ? '已安装' : '未安装',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _textCard(
    ThemeData theme, {
    required String title,
    required IconData icon,
    required String text,
  }) {
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              height: 1.55,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolsCard(ThemeData theme) {
    final tools = _plugin?['tools'];
    if (tools is! List || tools.isEmpty) return const SizedBox.shrink();
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.wrench,
                size: 17,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              const Text(
                '工具',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final item in tools.whereType<Map>())
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['name']?.toString() ?? '',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((item['description']?.toString() ?? '').isNotEmpty)
                    Text(
                      item['description'].toString(),
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionButton(ThemeData theme) {
    final installed = _plugin?['installed'] == true;
    final installable = _plugin?['installable'] != false;
    if (installed) {
      return OutlinedButton.icon(
        onPressed: _busy ? null : _uninstall,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(LucideIcons.trash_2, size: 18),
        label: const Text('卸载'),
      );
    }
    return FilledButton.icon(
      onPressed: (!_busy && installable) ? _install : null,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              installable ? LucideIcons.download : LucideIcons.circle_slash_2,
              size: 18,
            ),
      label: Text(installable ? '安装' : '暂不能直装'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }

  Widget _tag(String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.outline),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }
}
