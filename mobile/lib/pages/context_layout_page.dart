import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/context_layout_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';

const Set<String> _mergedDynamicSources = {
  'time',
  'memory',
  'contemplation',
  'activities',
  'whispers',
};

String _stringValue(Object? value) => value == null ? '' : value.toString();

String _blockSource(Map<String, dynamic> block) {
  final source = _stringValue(block['source']).trim();
  return source.isNotEmpty ? source : _stringValue(block['id']).trim();
}

bool _isMergedDynamicBlock(Map<String, dynamic> block) =>
    _mergedDynamicSources.contains(_blockSource(block));

bool _isDisabledTimeBlock(Map<String, dynamic> block) =>
    _blockSource(block) == 'time' && block['enabled'] != true;

String _blockDisplayText(Map<String, dynamic> block) {
  final rendered = _stringValue(block['rendered_text']);
  if (_isDisabledTimeBlock(block)) {
    return '已禁用（时间感知已挂 get_time 工具）';
  }
  if (_isMergedDynamicBlock(block) && rendered.trim().isEmpty) {
    return '对话时实时生成；最近一轮是否实际注入，请以上方“最近一次实际拼接”为准';
  }
  if (rendered.trim().isEmpty) {
    return '当前无注入内容';
  }
  return rendered;
}

String _editableInitialText(Map<String, dynamic> block, String override) {
  if (override.isNotEmpty) return override;
  if (_isDisabledTimeBlock(block)) return '';
  return _stringValue(block['rendered_text']);
}

/// 上下文拼接可视化（v0.2.158）：
/// - 每块一张卡片：名称 + 位置标签（system/用户前/用户后）+ 开关 + 上移/下移；
/// - 卡片可展开/折叠看该块实际注入的 rendered_text；
/// - 点卡片进详情页：完整 prompt 文本 + 可编辑（保存后生效）+ 开关。
/// 数据源 8816 GET/POST /context-layout，rendered_text 由服务端渲染逻辑生成。
///
/// v0.2.159 交互修复：
/// - 整卡可点进详情（原来只有卡片上半部分能点）；
/// - 排序恢复拖动（ReorderableListView + 右侧拖动手柄），上移/下移按钮保留。
class ContextLayoutPage extends StatefulWidget {
  const ContextLayoutPage({super.key});

  @override
  State<ContextLayoutPage> createState() => _ContextLayoutPageState();
}

class _ContextLayoutPageState extends State<ContextLayoutPage> {
  List<Map<String, dynamic>>? _blocks;
  List<Map<String, dynamic>>? _lastAssembly;
  bool _loading = true;
  bool _error = false;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final cfg = await ContextLayoutApi.fetch();
    if (!mounted) return;
    final blocks = (cfg?['blocks'] as List<dynamic>?)
        ?.whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final lastAssembly = (cfg?['last_assembly'] as List<dynamic>?)
        ?.whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    setState(() {
      _blocks = blocks;
      _lastAssembly = lastAssembly;
      _loading = false;
      _error = blocks == null;
    });
  }

  Future<bool> _persist() async {
    final blocks = _blocks;
    if (blocks == null) return false;
    final ok = await ContextLayoutApi.save({'blocks': blocks});
    if (!ok && mounted) _toast('保存失败，配置没写进去');
    return ok;
  }

  Future<void> _reset() async {
    final ok = await ContextLayoutApi.reset();
    if (ok) {
      await _load();
    } else if (mounted) {
      _toast('恢复默认失败');
    }
  }

  String _positionLabel(String p) => switch (p) {
    'system' => 'system',
    'user_before' => 'user 前缀',
    'user_after' => 'user 后缀',
    _ => p,
  };

  void _toggle(Map<String, dynamic> block, bool v) {
    setState(() => block['enabled'] = v);
    _persist();
  }

  void _move(int index, int delta) {
    final blocks = _blocks;
    if (blocks == null) return;
    final target = index + delta;
    if (target < 0 || target >= blocks.length) return;
    setState(() {
      final item = blocks.removeAt(index);
      blocks.insert(target, item);
    });
    _persist();
  }

  void _reorder(int oldIndex, int newIndex) {
    final blocks = _blocks;
    if (blocks == null) return;
    setState(() {
      final item = blocks.removeAt(oldIndex);
      blocks.insert(newIndex, item);
    });
    _persist();
  }

  Future<void> _openDetail(Map<String, dynamic> block) async {
    final updated = await Navigator.of(context).push<Map<String, dynamic>>(
      SwipeBackRoute(
        builder: (_) => _BlockDetailPage(block: block, onSave: _saveBlock),
      ),
    );
    if (updated != null) {
      final blocks = _blocks;
      if (blocks == null) return;
      setState(() {
        final idx = blocks.indexWhere((b) => b['id'] == updated['id']);
        if (idx >= 0) blocks[idx] = updated;
      });
      await _load();
    }
  }

  Future<bool> _saveBlock(Map<String, dynamic> updated) async {
    final blocks = _blocks;
    if (blocks == null) return false;
    final next = [
      for (final b in blocks)
        b['id'] == updated['id'] ? updated : Map<String, dynamic>.from(b),
    ];
    final ok = await ContextLayoutApi.save({'blocks': next});
    if (ok) {
      setState(() => _blocks = next);
    } else if (mounted) {
      _toast('保存失败，配置没写进去');
    }
    return ok;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('上下文拼接'),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        actions: [
          TextButton.icon(
            onPressed: _blocks == null ? null : _reset,
            icon: const Icon(LucideIcons.rotate_ccw, size: 18),
            label: const Text('恢复默认'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final blocks = _blocks;
    if (_error || blocks == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('上下文配置连不上', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12),
      header: _assemblyPreviewCard(),
      buildDefaultDragHandles: false,
      onReorderItem: _reorder,
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final block = blocks[index];
        final id = block['id'] as String? ?? 'block-$index';
        return _blockCard(block, index, blocks.length, key: ValueKey(id));
      },
    );
  }

  Widget _blockCard(
    Map<String, dynamic> block,
    int index,
    int total, {
    Key? key,
  }) {
    final id = block['id'] as String? ?? '$index';
    final enabled = block['enabled'] == true;
    final position = block['position'] as String? ?? 'system';
    final label = block['label'] as String? ?? id;
    final hasOverride = block['has_override'] == true;
    final previewText = _blockDisplayText(block);
    final expanded = _expanded.contains(id);

    return SettingCard(
      key: key,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: () => _openDetail(block),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _positionTag(position),
                        if (_isMergedDynamicBlock(block))
                          _flowTag('合并进最新 user'),
                        if (_isDisabledTimeBlock(block))
                          _flowTag('get_time 工具'),
                        if (hasOverride) ...[_overrideTag()],
                      ],
                    ),
                  ],
                ),
              ),
              Switch(value: enabled, onChanged: (v) => _toggle(block, v)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                tooltip: '上移',
                visualDensity: VisualDensity.compact,
                onPressed: index > 0 ? () => _move(index, -1) : null,
                icon: const Icon(LucideIcons.arrow_up, size: 20),
              ),
              IconButton(
                tooltip: '下移',
                visualDensity: VisualDensity.compact,
                onPressed: index < total - 1 ? () => _move(index, 1) : null,
                icon: const Icon(LucideIcons.arrow_down, size: 20),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.full),
                onTap: () => setState(() {
                  expanded ? _expanded.remove(id) : _expanded.add(id);
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        expanded ? '收起' : '配置预览',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.subTextColor,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        expanded
                            ? LucideIcons.chevron_up
                            : LucideIcons.chevron_down,
                        size: 16,
                        color: context.subTextColor,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Icon(
                    LucideIcons.grip_vertical,
                    size: 18,
                    color: context.subTextColor,
                  ),
                ),
              ),
            ],
          ),
          if (expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: context.fieldColor,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: SingleChildScrollView(
                child: Text(
                  previewText,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _assemblyPreviewCard() {
    final assembly = _lastAssembly;
    return SettingCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.git_merge,
                size: 22,
                color: context.subTextColor,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '最近一次实际拼接',
                  style: TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (assembly != null && assembly.isNotEmpty)
                _flowTag('${assembly.length} 条'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '这里记录最近一轮真正送给模型的拼接；下面各卡只是当前配置预览，动态内容会随每轮对话变化。',
            style: TextStyle(
              fontSize: 11,
              color: context.subTextColor,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          if (assembly == null || assembly.isEmpty)
            Text(
              '还没有对话触发过拼接',
              style: TextStyle(fontSize: 12, color: context.subTextColor),
            )
          else
            for (var i = 0; i < assembly.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              _assemblyRow(assembly[i]),
            ],
        ],
      ),
    );
  }

  Widget _assemblyRow(Map<String, dynamic> item) {
    final role = _stringValue(item['role']).trim();
    final source = _assemblySourceLabel(_stringValue(item['source']).trim());
    final preview = _stringValue(
      item['content_preview'] ?? item['preview'] ?? item['content_head'],
    ).trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _assemblyTag(role.isEmpty ? 'unknown' : role),
            _assemblyTag(source.isEmpty ? 'history' : source),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          preview.isEmpty ? '（空）' : preview,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, height: 1.45),
        ),
      ],
    );
  }

  String _assemblySourceLabel(String source) {
    if (source.startsWith('stable_system:')) {
      return 'stable_system · ${source.substring('stable_system:'.length)}';
    }
    if (source.startsWith('merged_into_user:')) {
      return 'merged_into_user · ${source.substring('merged_into_user:'.length)}';
    }
    return source;
  }

  Widget _positionTag(String position) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        _positionLabel(position),
        style: TextStyle(fontSize: 11, color: context.subTextColor),
      ),
    );
  }

  Widget _flowTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: context.subTextColor),
      ),
    );
  }

  Widget _assemblyTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: context.subTextColor),
      ),
    );
  }

  Widget _overrideTag() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '已编辑',
        style: TextStyle(fontSize: 11, color: context.accentColor),
      ),
    );
  }
}

/// 单块详情：实际注入文本（只读）+ 可编辑文本（保存后作为覆盖生效）+ 开关。
class _BlockDetailPage extends StatefulWidget {
  final Map<String, dynamic> block;
  final Future<bool> Function(Map<String, dynamic> updated) onSave;

  const _BlockDetailPage({required this.block, required this.onSave});

  @override
  State<_BlockDetailPage> createState() => _BlockDetailPageState();
}

class _BlockDetailPageState extends State<_BlockDetailPage> {
  late final TextEditingController _ctrl;
  late bool _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _enabled = widget.block['enabled'] == true;
    final override = widget.block['text_override'] as String? ?? '';
    _ctrl = TextEditingController(
      text: _editableInitialText(widget.block, override),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _updated() {
    final b = Map<String, dynamic>.from(widget.block);
    b['enabled'] = _enabled;
    b['text_override'] = _ctrl.text.trim();
    return b;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await widget.onSave(_updated());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(_updated());
    } else {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('保存失败，配置没写进去', style: TextStyle(fontSize: 13)),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _toggleSwitch(bool v) async {
    setState(() => _enabled = v);
    final ok = await widget.onSave(_updated());
    if (!ok && mounted) {
      setState(() => _enabled = !v);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('开关保存失败', style: TextStyle(fontSize: 13)),
            duration: Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  void _restoreAuto() {
    setState(() => _ctrl.text = '');
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.block['id'] as String? ?? '';
    final label = widget.block['label'] as String? ?? id;
    final rendered = _blockDisplayText(widget.block);
    return Scaffold(
      appBar: AppBar(
        title: Text(label),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        actions: [
          IconButton(
            tooltip: '保存',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.save, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
        children: [
          SettingCard(
            padding: EdgeInsets.zero,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              secondary: Icon(
                LucideIcons.power,
                size: 24,
                color: context.subTextColor,
              ),
              title: const Text(
                '启用该块',
                style: TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
              value: _enabled,
              onChanged: _toggleSwitch,
            ),
          ),
          _sectionLabel('实际注入的 prompt 文本'),
          SettingCard(
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SelectableText(
                  rendered.isEmpty ? '该块当前无注入内容（动态块会在对话时按需注入）' : rendered,
                  style: const TextStyle(fontSize: 13, height: 1.6),
                ),
              ),
            ),
          ),
          _sectionLabel('编辑文本（保存后生效）'),
          SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _ctrl,
                  minLines: 8,
                  maxLines: 18,
                  autocorrect: false,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                  decoration: InputDecoration(
                    hintText: '留空 = 恢复自动渲染',
                    filled: true,
                    fillColor: context.fieldColor,
                    contentPadding: const EdgeInsets.all(12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _restoreAuto,
                    icon: const Icon(LucideIcons.undo_2, size: 16),
                    label: const Text('恢复自动渲染', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: context.subTextColor),
      ),
    );
  }
}
