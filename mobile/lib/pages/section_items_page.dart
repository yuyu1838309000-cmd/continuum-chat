import 'dart:async';

import 'package:flutter/material.dart';
import '../models/prompt_entry.dart';
import '../utils/app_theme.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

/// 二级页：分区内的条目列表，可排序、编辑、新增、删除
/// 直接操作传入的 [section] 引用，返回时由一级页刷新
class SectionItemsPage extends StatefulWidget {
  final PromptSection section;

  const SectionItemsPage({super.key, required this.section});

  @override
  State<SectionItemsPage> createState() => _SectionItemsPageState();
}

class _SectionItemsPageState extends State<SectionItemsPage> {
  // 全屏编辑：showModalBottomSheet 高度 85% 屏，圆角 20。
  // 标题一行 + 内容 expands 占满剩余，底部取消/确定两个胶囊按钮。
  Future<({String title, String content})?> _editDialog({
    String? title,
    String? content,
  }) async {
    final t = TextEditingController(text: title ?? '');
    final c = TextEditingController(text: content ?? '');
    try {
      return await showModalBottomSheet<({String title, String content})>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          final mq = MediaQuery.of(ctx);
          final maxHeight = mq.size.height * 0.85;
          final insetHeight =
              maxHeight - mq.viewInsets.bottom - mq.padding.bottom;
          final sheetHeight = insetHeight < 220 ? 220.0 : insetHeight;
          return SafeArea(
            top: false,
            child: Padding(
              // 键盘弹起时整体上移；高度减去键盘高度避免溢出
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 12,
                bottom: mq.viewInsets.bottom + 16,
              ),
              child: SizedBox(
                height: sheetHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 顶部细把手
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title == null ? '新增条目' : '编辑条目',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 标题：一行输入
                    TextField(
                      controller: t,
                      autofocus: true,
                      decoration: _sheetInputDecoration(ctx, labelText: '标题'),
                    ),
                    const SizedBox(height: 12),
                    // 内容：占满剩余高度
                    Expanded(
                      child: TextField(
                        controller: c,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: _sheetInputDecoration(
                          ctx,
                          labelText: '内容',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 底部两个胶囊按钮
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: const StadiumBorder(),
                            ),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () {
                              final tt = t.text.trim();
                              if (tt.isEmpty) return;
                              Navigator.pop(ctx, (
                                title: tt,
                                content: c.text.trim(),
                              ));
                            },
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: const StadiumBorder(),
                            ),
                            child: const Text('确定'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } finally {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          t.dispose();
          c.dispose();
        }),
      );
    }
  }

  Future<void> _addItem() async {
    final result = await _editDialog();
    if (result == null || !mounted) return;
    setState(() {
      widget.section.items.add(
        PromptItem(title: result.title, content: result.content),
      );
    });
  }

  Future<void> _editItem(int index) async {
    final item = widget.section.items[index];
    final result = await _editDialog(title: item.title, content: item.content);
    if (result == null || !mounted) return;
    setState(() {
      item.title = result.title;
      item.content = result.content;
    });
  }

  Future<void> _deleteItem(int index) async {
    final item = widget.section.items[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${item.title}」？'),
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
    if (ok == true && mounted) {
      setState(() => widget.section.items.removeAt(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.section.title),
        actions: [
          IconButton(
            tooltip: '新增条目',
            onPressed: _addItem,
            icon: const Icon(LucideIcons.plus),
          ),
        ],
      ),
      body: widget.section.items.isEmpty
          ? const Center(child: Text('这个分区还没有条目'))
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: widget.section.items.length,
              onReorderItem: (oldIndex, newIndex) {
                setState(() {
                  final item = widget.section.items.removeAt(oldIndex);
                  widget.section.items.insert(newIndex, item);
                });
              },
              itemBuilder: (context, index) {
                final item = widget.section.items[index];
                final theme = Theme.of(context);
                return ReorderableDelayedDragStartListener(
                  key: ValueKey('item_${item.title}_$index'),
                  index: index,
                  // 基准简洁卡片：圆角 20 + cardShadow + cardColor，左图标 +
                  // 标题 15 w600 + 编辑/删除，正文最多一行（数据，非解释小字），间距 16
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [context.cardShadow],
                    ),
                    child: Material(
                      color: context.cardColor,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              LucideIcons.file_text,
                              size: 24,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                  if (item.content.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      item.content,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color:
                                            theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(LucideIcons.pencil),
                              onPressed: () => _editItem(index),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(LucideIcons.trash_2),
                              onPressed: () => _deleteItem(index),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addItem,
        tooltip: '新增条目',
        child: const Icon(LucideIcons.plus),
      ),
    );
  }

  InputDecoration _sheetInputDecoration(
    BuildContext context, {
    required String labelText,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      labelText: labelText,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: context.fieldColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide.none,
      ),
    );
  }
}
