import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/extension_config_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 快捷消息管理页（v0.2.153，借鉴 RikkaHub QuickMessages）：
/// 每条一个短文本（"AI 助手在吗"/"晚安"），列表增删改，存 8816 ~/quick_messages.json；
/// 聊天页输入框上方的入口点开直接发送同款列表。
/// 基准简洁卡片：圆角 20 + 柔和阴影 + cardColor 底，左图标 + 文本 + 编辑/删除。
class QuickMessagesPage extends StatefulWidget {
  const QuickMessagesPage({super.key});

  @override
  State<QuickMessagesPage> createState() => _QuickMessagesPageState();
}

class _QuickMessagesPageState extends State<QuickMessagesPage> {
  List<String> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final msgs = await ExtensionConfigApi.quickMessages();
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final saved = await ExtensionConfigApi.saveQuickMessages(_messages);
    if (!mounted) return;
    if (saved != null) {
      setState(() => _messages = saved);
    }
  }

  Future<void> _add() async {
    final text = await _editDialog(null);
    if (text == null || text.isEmpty) return;
    setState(() => _messages = [..._messages, text]);
    await _save();
  }

  Future<void> _edit(int index) async {
    final text = await _editDialog(_messages[index]);
    if (text == null || text.isEmpty) return;
    setState(() {
      final next = List<String>.from(_messages);
      next[index] = text;
      _messages = next;
    });
    await _save();
  }

  Future<void> _delete(int index) async {
    setState(
      () => _messages = [
        for (var i = 0; i < _messages.length; i++)
          if (i != index) _messages[i],
      ],
    );
    await _save();
  }

  Future<String?> _editDialog(String? old) async {
    final ctrl = TextEditingController(text: old ?? '');
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.lg,
          ),
          title: Text(old == null ? '添加快捷消息' : '编辑快捷消息'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: SingleChildScrollView(
              child: TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 60,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
                decoration: const InputDecoration(hintText: '例如：AI 助手在吗'),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), ctrl.dispose),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('快捷消息'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            onPressed: _loading ? null : _add,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _messages.isEmpty
          ? _emptyState(theme)
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              children: [
                for (var i = 0; i < _messages.length; i++)
                  SettingCard(
                    child: Row(
                      children: [
                        Icon(
                          LucideIcons.zap,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _messages[i],
                            style: const TextStyle(
                              fontSize: AppType.body,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.pencil),
                          onPressed: () => _edit(i),
                          tooltip: '编辑',
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.trash_2),
                          onPressed: () => _delete(i),
                          tooltip: '删除',
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpacing.xs),
              ],
            ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.zap, size: 28, color: theme.colorScheme.outline),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '还没有快捷消息',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.icon(
              onPressed: _add,
              icon: const Icon(LucideIcons.plus, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}
