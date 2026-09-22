import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/message.dart';
import '../services/history_index_item.dart';
import '../services/runtime_history_models.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../utils/archive_display.dart';
import '../utils/export_chat.dart';
import '../widgets/setting_card.dart';
import '../widgets/swipe_back.dart';
import 'archives_page.dart';
import 'calendar_page.dart';
import 'history_trash_page.dart';
import 'read_only_chat_view_page.dart';
import 'search_page.dart';

typedef HistoryExportCallback =
    Future<void> Function(BuildContext context, List<ChatMessage> messages);

class HistoryHubPage extends StatefulWidget {
  const HistoryHubPage({
    super.key,
    required this.currentMessages,
    this.repository,
    this.exportConversation,
  });

  final List<ChatMessage> currentMessages;
  final RuntimeHistoryRepository? repository;
  final HistoryExportCallback? exportConversation;

  @override
  State<HistoryHubPage> createState() => _HistoryHubPageState();
}

class _HistoryHubPageState extends State<HistoryHubPage> {
  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  List<HistoryConversationSummary>? _recentConversations;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RuntimeHistoryRepository();
    _ownsRepository = widget.repository == null;
    _loadRecentConversations();
  }

  @override
  void dispose() {
    if (_ownsRepository) _repository.close();
    super.dispose();
  }

  Future<void> _loadRecentConversations() async {
    try {
      final page = await _repository.conversations(limit: 1);
      if (!mounted) return;
      setState(() => _recentConversations = page.items.take(1).toList());
    } catch (_) {
      // 最近内容是增强信息；读取失败时保留完整 Hub 导航并静默降级。
    }
  }

  Future<void> _openSearch() async {
    final index = await Navigator.push<int>(
      context,
      SwipeBackRoute(
        builder: (_) => SearchPage(
          currentMessages: widget.currentMessages,
          repository: _repository,
        ),
      ),
    );
    if (index != null && mounted) Navigator.pop(context, index);
  }

  void _openArchives() {
    Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => ArchivesPage(repository: _repository)),
    );
  }

  Future<void> _openRecentConversation(
    HistoryConversationSummary conversation,
  ) async {
    try {
      final messages = await _repository.completeConversationMessages(
        HistoryIndexItem.runtime(conversation),
      );
      if (!mounted) return;
      final preview = normalizeArchivePreviewText(
        conversation.preview ?? conversation.title ?? '',
      );
      Navigator.push(
        context,
        SwipeBackRoute(
          builder: (_) => ReadOnlyChatViewPage(
            title: preview.isEmpty
                ? '历史对话'
                : truncateArchivePreviewText(preview),
            messages: messages,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('对话详情加载失败，请重试')));
    }
  }

  Future<void> _export() async {
    if (widget.currentMessages.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('还没有可导出的对话')));
      return;
    }
    try {
      final callback = widget.exportConversation;
      if (callback != null) {
        await callback(context, widget.currentMessages);
      } else {
        await ChatExporter.exportAndShare(
          context,
          widget.currentMessages,
          title: 'Continuum Chat对话',
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('导出失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          _CurrentConversationCard(messages: widget.currentMessages),
          if (_recentConversations case final conversations?) ...[
            const AppSectionLabel('最近的会话', compact: true),
            if (conversations.isEmpty)
              const _RecentConversationEmpty()
            else
              _RecentConversationsCard(
                conversations: conversations,
                onTap: _openRecentConversation,
              ),
          ],
          const AppSectionLabel('打开历史', compact: true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: _PrimaryDestination(
                    key: const ValueKey('history-hub-conversations'),
                    icon: LucideIcons.messages_square,
                    label: '会话',
                    onTap: _openArchives,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: _PrimaryDestination(
                    key: const ValueKey('history-hub-search'),
                    icon: LucideIcons.search,
                    label: '搜索',
                    onTap: _openSearch,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: _PrimaryDestination(
                    key: const ValueKey('history-hub-calendar'),
                    icon: LucideIcons.calendar_days,
                    label: '日历',
                    onTap: () => Navigator.push(
                      context,
                      SwipeBackRoute(
                        builder: (_) => CalendarPage(repository: _repository),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const AppSectionLabel('其他', compact: true),
          _SecondaryAction(
            key: const ValueKey('history-hub-trash'),
            icon: LucideIcons.trash_2,
            label: '最近删除',
            onTap: () => Navigator.push(
              context,
              SwipeBackRoute(
                builder: (_) => HistoryTrashPage(repository: _repository),
              ),
            ),
          ),
          _SecondaryAction(
            key: const ValueKey('history-hub-export'),
            icon: LucideIcons.share,
            label: '导出当前对话',
            onTap: _export,
          ),
        ],
      ),
    );
  }
}

class _CurrentConversationCard extends StatelessWidget {
  const _CurrentConversationCard({required this.messages});

  final List<ChatMessage> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _latestMessagePreview(messages);
    return SettingCard(
      key: const ValueKey('history-hub-current-conversation'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '当前对话',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${messages.length} 条消息',
                key: const ValueKey('history-hub-current-count'),
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: context.semanticColors.mutedText,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            preview ?? '还没有内容',
            key: const ValueKey('history-hub-current-preview'),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              height: 1.45,
              fontSize: AppType.body,
              color: preview == null
                  ? context.semanticColors.mutedText
                  : context.semanticColors.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentConversationsCard extends StatelessWidget {
  const _RecentConversationsCard({
    required this.conversations,
    required this.onTap,
  });

  final List<HistoryConversationSummary> conversations;
  final ValueChanged<HistoryConversationSummary> onTap;

  @override
  Widget build(BuildContext context) {
    return SettingCard(
      key: const ValueKey('history-hub-recent-conversations'),
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final conversation in conversations)
            _RecentConversationRow(
              conversation: conversation,
              onTap: () => onTap(conversation),
            ),
        ],
      ),
    );
  }
}

class _RecentConversationRow extends StatelessWidget {
  const _RecentConversationRow({
    required this.conversation,
    required this.onTap,
  });

  final HistoryConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = normalizeArchivePreviewText(
      conversation.preview ?? conversation.title ?? '',
    );
    return InkWell(
      key: ValueKey('history-hub-recent-${conversation.epochId}'),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.isEmpty
                          ? '${conversation.messageCount} 条消息'
                          : preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${conversation.messageCount} 条消息',
                        style: TextStyle(
                          fontSize: AppType.timestamp,
                          color: context.semanticColors.mutedText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                LucideIcons.chevron_right,
                size: 18,
                color: context.semanticColors.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentConversationEmpty extends StatelessWidget {
  const _RecentConversationEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '还没有归档会话',
          style: TextStyle(
            fontSize: AppType.caption,
            color: context.semanticColors.mutedText,
          ),
        ),
      ),
    );
  }
}

class _PrimaryDestination extends StatelessWidget {
  const _PrimaryDestination({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: context.fieldColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 21, color: scheme.primary),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.caption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: context.semanticColors.mutedText),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.semanticColors.mutedText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _latestMessagePreview(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    final content = normalizeArchivePreviewText(message.content);
    if (content.isNotEmpty) return content;
    final fileName = message.fileName?.trim();
    if (fileName != null && fileName.isNotEmpty) return fileName;
    if ((message.imageUrl ?? '').isNotEmpty || message.imageUrls.isNotEmpty) {
      return '图片附件';
    }
  }
  return null;
}
