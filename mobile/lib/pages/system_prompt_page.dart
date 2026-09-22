import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/swipe_back.dart';
import '../models/prompt_entry.dart';
import '../services/prompt_api.dart';
import '../utils/app_theme.dart';
import 'section_items_page.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 相处偏好：分区整理希望AI 助手了解和遵循的交互偏好。
/// 保留原有分区改名、排序、条目管理与保存能力。
class SystemPromptPage extends StatefulWidget {
  const SystemPromptPage({super.key});

  @override
  State<SystemPromptPage> createState() => _SystemPromptPageState();
}

class _SystemPromptPageState extends State<SystemPromptPage> {
  bool _loading = true;
  bool _loadFailed = false;
  String? _name;
  List<PromptSection> _sections = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _loadFailed = false;
      });
    }
    final data = await PromptApi.fetchActive();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (data == null) {
        if (showLoading) _loadFailed = true;
      } else {
        _name = data.name;
        _sections = data.sections;
      }
    });
  }

  Future<void> _renameSection(int index) async {
    final controller = TextEditingController(text: _sections[index].title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('改分区名'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.pop(ctx, controller.text.trim()),
            decoration: InputDecoration(
              hintText: '分区名称',
              filled: true,
              fillColor: context.fieldColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        controller.dispose,
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => _sections[index].title = result);
    }
  }

  Future<void> _save() async {
    if (_saving || _name == null) return;
    setState(() => _saving = true);
    final ok = await PromptApi.save(_name!, _sections);
    if (!mounted) return;
    if (ok) {
      // 保存成功后静默同步一次服务器数据，避免本地和服务器不一致
      await _load(showLoading: false);
      if (!mounted) return;
    }
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已保存' : '保存失败，本地修改还在，可重试'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openSection(int index) async {
    await Navigator.of(context).push(
      SwipeBackRoute(
        builder: (_) => SectionItemsPage(section: _sections[index]),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('相处偏好'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _saving ? null : _load,
            icon: const Icon(LucideIcons.refresh_cw),
          ),
          IconButton(
            tooltip: '保存',
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.save),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载失败'),
            const SizedBox(height: 8),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_sections.isEmpty) {
      return const Center(child: Text('还没有分区'));
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      header: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text(
          '长按卡片可以调整顺序',
          style: TextStyle(
            fontSize: AppType.caption,
            color: context.subTextColor,
          ),
        ),
      ),
      itemCount: _sections.length,
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          final sec = _sections.removeAt(oldIndex);
          _sections.insert(newIndex, sec);
        });
      },
      itemBuilder: (context, index) {
        final sec = _sections[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('sec_${sec.title}_$index'),
          index: index,
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: [context.cardShadow],
            ),
            child: Material(
              color: context.cardColor,
              borderRadius: BorderRadius.circular(AppRadius.md),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _openSection(index),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: AppSpacing.md,
                    top: AppSpacing.xs,
                    bottom: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.folder_open,
                        size: 24,
                        color: context.subTextColor,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          sec.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: AppType.body,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        '${sec.items.length} 条',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.subTextColor,
                        ),
                      ),
                      IconButton(
                        tooltip: '改名',
                        icon: const Icon(LucideIcons.pencil),
                        onPressed: () => _renameSection(index),
                      ),
                      Icon(
                        LucideIcons.chevron_right,
                        size: 20,
                        color: context.semanticColors.outline,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
