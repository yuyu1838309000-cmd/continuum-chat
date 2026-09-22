import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';
import '../utils/plugin_display.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';
import 'plugin_detail_page.dart';
import 'plugin_manual_add_page.dart';

/// 单一添加插件流程：首屏完成搜索、浏览和安装，手动 MCP 与 Skill 导入
/// 是同页次级动作；详情只用于按需查看更多。
class PluginMarketPage extends StatefulWidget {
  const PluginMarketPage({super.key});

  @override
  State<PluginMarketPage> createState() => _PluginMarketPageState();
}

class _PluginMarketPageState extends State<PluginMarketPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final List<Map<String, dynamic>> _plugins = [];
  final Set<String> _installing = {};
  Timer? _debounce;
  String? _error;
  String? _softError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  int _requestSeq = 0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loading || _loadingMore) return;
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 280) {
      _load(reset: false);
    }
  }

  void _onSearchChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 420), () {
      if (mounted) _load(reset: true);
    });
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      _requestSeq++;
      setState(() {
        _loading = true;
        _loadingMore = false;
        _hasMore = true;
        _page = 0;
        _plugins.clear();
        _error = null;
        _softError = null;
      });
    } else {
      if (!_hasMore || _loadingMore) return;
      setState(() => _loadingMore = true);
    }

    final seq = _requestSeq;
    final nextPage = reset ? 1 : _page + 1;
    final data = await ExtensionConfigApi.market(
      query: _searchCtrl.text.trim(),
      source: 'all',
      page: nextPage,
    );
    if (!mounted || seq != _requestSeq) return;

    final fetched =
        (data?['plugins'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        [];
    final errors = data?['errors'];

    setState(() {
      if (data == null) {
        if (reset) _error = '拉取插件市场失败，检查服务器连接';
        _hasMore = false;
      } else {
        _appendPlugins(fetched, reset: reset);
        _page = nextPage;
        _hasMore = data['has_more'] == true;
        _softError = _formatErrors(errors);
        _error = null;
      }
      _loading = false;
      _loadingMore = false;
    });
  }

  void _appendPlugins(
    List<Map<String, dynamic>> fetched, {
    required bool reset,
  }) {
    if (reset) _plugins.clear();
    final seen = {for (final p in _plugins) '${_sourceOf(p)}:${_idOf(p)}'};
    for (final p in fetched) {
      final key = '${_sourceOf(p)}:${_idOf(p)}';
      if (key == ':' || seen.contains(key)) continue;
      _plugins.add(p);
      seen.add(key);
    }
  }

  String? _formatErrors(Object? errors) {
    if (errors is! Map || errors.isEmpty) return null;
    final names = [
      for (final e in errors.entries)
        if (e.value != null && e.value.toString().isNotEmpty) e.key.toString(),
    ];
    if (names.isEmpty) return null;
    return '部分平台暂时没拉到：${names.join('、')}';
  }

  String _idOf(Map<String, dynamic> p) => p['id']?.toString() ?? '';

  String _sourceOf(Map<String, dynamic> p) =>
      p['source']?.toString().toLowerCase() ?? 'local';

  String _sourceLabel(String source) => pluginSourceLabel(source);

  String _typeLabel(Map<String, dynamic> plugin) {
    return switch (plugin['type']?.toString().trim().toLowerCase()) {
      'mcp' => 'MCP',
      'skill' => 'Skill',
      'command' => '命令',
      _ => '插件',
    };
  }

  IconData _iconOf(Map<String, dynamic> p) {
    final source = _sourceOf(p);
    if (source == 'internal' || source == 'local') {
      return LucideIcons.shield_check;
    }
    if (source == 'manual') return LucideIcons.hand;
    return LucideIcons.puzzle;
  }

  Future<void> _openManualAdd(String type) async {
    final result = await Navigator.of(context).push<Object?>(
      SwipeBackRoute(builder: (_) => PluginManualAddPage(initialType: type)),
    );
    if (!mounted || result is! Map) return;
    Navigator.of(context).pop(result);
  }

  Future<void> _openDetail(Map<String, dynamic> plugin) async {
    final changed = await Navigator.of(context).push<bool>(
      SwipeBackRoute(
        builder: (_) => PluginDetailPage(
          id: _idOf(plugin),
          source: _sourceOf(plugin),
          initial: plugin,
        ),
      ),
    );
    if (mounted && changed == true) {
      Navigator.of(context).pop({'message': '插件列表已更新'});
    }
  }

  Future<void> _install(Map<String, dynamic> plugin) async {
    final key = '${_sourceOf(plugin)}:${_idOf(plugin)}';
    if (plugin['installed'] == true || _installing.contains(key)) return;
    setState(() => _installing.add(key));
    final data = await ExtensionConfigApi.installMarketPlugin(
      _idOf(plugin),
      source: _sourceOf(plugin),
    );
    if (!mounted) return;
    if (data?['ok'] == true) {
      Navigator.of(context).pop({
        'message': data?['already_installed'] == true ? '已经安装过了' : '插件已安装',
      });
      return;
    }
    setState(() => _installing.remove(key));
    final message = data?['error']?.toString().trim();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message == null || message.isEmpty ? '安装失败，服务器没回应' : message,
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('添加插件'),
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
            onPressed: _loading ? null : () => _load(reset: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: ListView(
          controller: _scrollCtrl,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            _searchBox(),
            _secondaryActions(),
            if (_softError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  _softError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (_loading && _plugins.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _errorState(theme)
            else if (_plugins.isEmpty)
              _emptyState(theme)
            else
              for (final p in _plugins) _pluginCard(context, p),
            if (_loadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _searchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: _searchCtrl,
        onChanged: _onSearchChanged,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _load(reset: true),
        decoration: InputDecoration(
          hintText: '搜索插件',
          prefixIcon: const Icon(LucideIcons.search, size: 20),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(LucideIcons.x, size: 18),
                  tooltip: '清空',
                  onPressed: () {
                    _searchCtrl.clear();
                    _load(reset: true);
                  },
                ),
          filled: true,
          fillColor: context.fieldColor,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _secondaryActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: () => _openManualAdd('mcp'),
            icon: const Icon(LucideIcons.cable, size: 16),
            label: const Text('手动添加 MCP'),
          ),
          OutlinedButton.icon(
            onPressed: () => _openManualAdd('skill'),
            icon: const Icon(LucideIcons.file_up, size: 16),
            label: const Text('导入 Skill'),
          ),
        ],
      ),
    );
  }

  Widget _errorState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
      child: Center(
        child: Column(
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
              onPressed: () => _load(reset: true),
              icon: const Icon(LucideIcons.refresh_ccw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Center(
        child: Text(
          '没搜到匹配的插件',
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

  Widget _pluginCard(BuildContext context, Map<String, dynamic> p) {
    final theme = Theme.of(context);
    final installed = p['installed'] == true;
    final installable = p['installable'] != false;
    final name = pluginDisplayName(p, fallback: _idOf(p));
    final desc = pluginDisplayDescription(p);
    final source = _sourceOf(p);
    final installing = _installing.contains('$source:${_idOf(p)}');

    return SettingCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.fieldColor,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              _iconOf(p),
              size: 20,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _tag(_typeLabel(p)),
                    _tag(_sourceLabel(source)),
                    TextButton(
                      onPressed: () => _openDetail(p),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(44, 36),
                      ),
                      child: const Text('更多'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed)
            _installedStatus(theme)
          else if (!installable)
            OutlinedButton(
              onPressed: () => _openDetail(p),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('查看'),
            )
          else
            FilledButton(
              onPressed: installing ? null : () => _install(p),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: installing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('安装'),
            ),
        ],
      ),
    );
  }

  Widget _installedStatus(ThemeData theme) {
    return Semantics(
      label: '已安装',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.circle_check,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            '已安装',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
