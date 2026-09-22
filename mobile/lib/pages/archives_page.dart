import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/message.dart';
import '../services/history_cutover_reconciler.dart';
import '../services/history_index_item.dart';
import '../services/runtime_history_api.dart';
import '../services/runtime_history_models.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../utils/archive_display.dart';
import 'read_only_chat_view_page.dart';
import '../widgets/folder_picker.dart';
import '../widgets/swipe_back.dart';

String _summaryDisplayTitle(HistoryIndexItem item) {
  final preview = normalizeArchivePreviewText(item.preview ?? '');
  if (preview.isNotEmpty) return truncateArchivePreviewText(preview);
  final title = normalizeArchivePreviewText(item.title ?? '');
  return truncateArchivePreviewText(title.isEmpty ? '历史片段' : title);
}

class ArchivesPage extends StatefulWidget {
  const ArchivesPage({super.key, this.repository, this.prepareHistory});

  final RuntimeHistoryRepository? repository;
  final Future<void> Function()? prepareHistory;

  @override
  State<ArchivesPage> createState() => _ArchivesPageState();
}

class _ArchivesPageState extends State<ArchivesPage> {
  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  List<HistoryIndexItem>? _archives;
  List<HistoryFolder> _folders = const [];
  String? _loadError;

  /// 筛选值：全部 / 未分类 / 文件夹 id，只影响展示层。
  String _filter = archiveFilterAll;

  /// 多选只允许现役 Runtime 会话；旧 RikkaHub 档案始终只读。
  final Set<String> _selected = {};
  bool get _inSelection => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RuntimeHistoryRepository();
    _ownsRepository = widget.repository == null;
    _load();
  }

  @override
  void dispose() {
    if (_ownsRepository) _repository.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      await (widget.prepareHistory ??
          HistoryCutoverCoordinator.instance.ensure)();
      final archivesFuture = _repository.historyIndex();
      final foldersFuture = _repository.folders();
      final archives = await archivesFuture;
      final folders = await foldersFuture;
      if (!mounted) return;
      setState(() {
        _archives = archives;
        _folders = folders.items;
        _loadError = null;
        if (_filter != archiveFilterAll &&
            _filter != archiveFilterUncategorized &&
            !folders.items.any((f) => f.folderId == _filter)) {
          _filter = archiveFilterAll;
        }
      });
    } on RuntimeHistoryException catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = '历史加载失败，请重试');
    }
  }

  List<HistoryIndexItem> _visible(List<HistoryIndexItem> all) =>
      switch (_filter) {
        archiveFilterUncategorized =>
          all.where((archive) => (archive.folderId ?? '').isEmpty).toList(),
        archiveFilterAll => all,
        final folderId =>
          all.where((archive) => archive.folderId == folderId).toList(),
      };

  String? _folderNameOf(HistoryIndexItem item) {
    final id = item.folderId;
    if (id == null || id.isEmpty) return null;
    for (final folder in _folders) {
      if (folder.folderId == id) return folder.name;
    }
    return null;
  }

  Future<void> _confirmDelete(HistoryIndexItem item) async {
    final epochId = item.epochId;
    if (!item.mutable || epochId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除历史'),
        content: Text(
          '将「${_summaryDisplayTitle(item)}」移到最近删除。\n\n'
          '其中 ${item.messageCount} 条消息会在服务器保留 7 天，期间可以恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.deleteConversation(epochId);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      _toast('已移到最近删除，7 天内可恢复');
    } on RuntimeHistoryException catch (error) {
      if (mounted) _toast('删除失败：${error.message}');
    }
  }

  Future<void> _createFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '文件夹名字'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await _repository.createFolder(name);
      if (mounted) await _load();
    } on RuntimeHistoryException catch (error) {
      if (mounted) _toast('创建失败：${error.message}');
    }
  }

  Future<void> _renameFolder(HistoryFolder folder) async {
    final ctrl = TextEditingController(text: folder.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '文件夹名字'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await _repository.renameFolder(folder.folderId, name);
      if (mounted) await _load();
    } on RuntimeHistoryException catch (error) {
      if (mounted) _toast('重命名失败：${error.message}');
    }
  }

  Future<void> _confirmDeleteFolder(HistoryFolder folder) async {
    final count = (_archives ?? const <HistoryIndexItem>[])
        .where((a) => a.folderId == folder.folderId)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text(
          '删除文件夹「${folder.name}」？\n\n'
          '里面的 $count 个会话会移回未分类，不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _repository.deleteFolder(folder.folderId);
      if (_filter == folder.folderId) _filter = archiveFilterAll;
      if (mounted) await _load();
    } on RuntimeHistoryException catch (error) {
      if (mounted) _toast('删除失败：${error.message}');
    }
  }

  void _showFolderMenu(HistoryFolder folder) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _folderMenuRow(
              sheetContext: ctx,
              icon: LucideIcons.pencil,
              title: '重命名',
              onTap: () {
                Navigator.pop(ctx);
                _renameFolder(folder);
              },
            ),
            _folderMenuRow(
              sheetContext: ctx,
              icon: LucideIcons.trash_2,
              title: '删除',
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteFolder(folder);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _folderMenuRow({
    required BuildContext sheetContext,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(sheetContext);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Material(
        color: sheetContext.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 21, color: theme.colorScheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevron_right,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 长按会话进入多选（该条自动勾上）。
  void _enterSelection(String id) {
    setState(() => _selected.add(id));
  }

  /// 多选模式点卡片：只允许现役 Runtime 会话进入选择。
  void _toggleSelect(HistoryIndexItem item) {
    if (!item.mutable) return;
    setState(() {
      if (!_selected.remove(item.id)) _selected.add(item.id);
    });
  }

  /// 退出多选（不移动任何会话）。
  void _exitSelection() {
    setState(() => _selected.clear());
  }

  Future<void> _moveSelected() async {
    final choice = await showFolderPicker(
      context,
      title: '移动到',
      allowCreate: true,
    );
    if (!mounted || choice == null) return;
    final selected = (_archives ?? const <HistoryIndexItem>[])
        .where((item) => _selected.contains(item.id) && item.mutable)
        .toList();
    final epochIds = selected
        .map((item) => item.epochId)
        .whereType<String>()
        .toList();
    if (epochIds.isEmpty) return;
    try {
      await _repository.assignFolder(epochIds, choice.id);
      if (!mounted) return;
      final target = choice.id == null ? '未分类' : '「${choice.name}」';
      setState(() => _selected.clear());
      await _load();
      if (mounted) _toast('已移到$target');
    } on RuntimeHistoryException catch (error) {
      if (mounted) _toast('移动失败：${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final archives = _archives;
    final loadError = _loadError;
    return PopScope(
      // 多选模式：返回键/边缘右滑先退出多选，不离开页面
      canPop: !_inSelection,
      onPopInvokedWithResult: (didPop, _) {
        if (shouldExitArchiveSelectionOnBlockedPop(
          didPop: didPop,
          inSelection: _inSelection,
        )) {
          _exitSelection();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('会话'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: _inSelection
              ? IconButton(
                  tooltip: '取消多选',
                  icon: const Icon(LucideIcons.x),
                  onPressed: _exitSelection,
                )
              : null,
        ),
        body: loadError != null
            ? _HistoryLoadError(message: loadError, onRetry: _load)
            : archives == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 多选模式：筛选区置灰不可点，防误触
                  IgnorePointer(
                    ignoring: _inSelection,
                    child: Opacity(
                      opacity: _inSelection ? 0.45 : 1,
                      child: _folderBar(theme),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _inSelection
                        ? ArchiveSelectionActionBar(
                            key: const ValueKey('archive-selection-actions'),
                            count: _selected.length,
                            onCancel: _exitSelection,
                            onMove: _moveSelected,
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(child: _buildList(archives, theme)),
                ],
              ),
      ),
    );
  }

  /// 顶部文件夹筛选区：全部 / 未分类 / 各文件夹 / 新建"+"。
  Widget _folderBar(ThemeData theme) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          _chip(theme, archiveFilterAll, '全部', onLongPress: null),
          const SizedBox(width: 8),
          _chip(theme, archiveFilterUncategorized, '未分类', onLongPress: null),
          for (final f in _folders) ...[
            const SizedBox(width: 8),
            _chip(
              theme,
              f.folderId,
              f.name,
              onLongPress: () => _showFolderMenu(f),
            ),
          ],
          const SizedBox(width: 8),
          _addChip(theme),
        ],
      ),
    );
  }

  Widget _chip(
    ThemeData theme,
    String id,
    String label, {
    required VoidCallback? onLongPress,
  }) {
    final selected = _filter == id;
    final scheme = theme.colorScheme;
    final fill = selected
        ? Color.alphaBlend(
            scheme.primary.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.18 : 0.1,
            ),
            context.fieldColor,
          )
        : context.fieldColor;
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(AppRadius.full),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: () => setState(() => _filter = id),
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _addChip(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Material(
      color: context.fieldColor,
      borderRadius: BorderRadius.circular(AppRadius.full),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: _createFolder,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(
              LucideIcons.plus,
              size: 17,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(List<HistoryIndexItem> archives, ThemeData theme) {
    if (archives.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '还没有历史',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final visible = _visible(archives);
    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '这个文件夹还没有会话',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final entries = _archiveListEntries(visible);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        final group = entry.group;
        if (group != null) {
          return _dateHeader(group, theme);
        }
        final a = entry.chat!;
        final folderName = _folderNameOf(a);
        final checked = _selected.contains(a.id);
        return ArchiveListCard(
          chat: a,
          title: _summaryDisplayTitle(a),
          meta: archiveMetaLine(
            archivedAt: a.archivedAt,
            messageCount: a.messageCount,
            folderName: folderName,
          ),
          inSelection: _inSelection,
          selected: checked,
          onLongPress: a.mutable ? () => _enterSelection(a.id) : () {},
          onTap: _inSelection
              ? () => _toggleSelect(a)
              : () {
                  Navigator.push(
                    context,
                    SwipeBackRoute(
                      builder: (_) => HistoryChatLoaderPage(
                        item: a,
                        repository: _repository,
                      ),
                    ),
                  );
                },
          onDelete: a.mutable ? () => _confirmDelete(a) : null,
        );
      },
    );
  }

  List<_ArchiveListEntry> _archiveListEntries(List<HistoryIndexItem> archives) {
    final entries = <_ArchiveListEntry>[];
    var lastDateKey = '';
    for (final archive in archives) {
      final date = archive.archivedAt;
      final dateKey = '${date.year}-${date.month}-${date.day}';
      if (dateKey != lastDateKey) {
        entries.add(_ArchiveListEntry.group(date));
        lastDateKey = dateKey;
      }
      entries.add(_ArchiveListEntry.chat(archive));
    }
    return entries;
  }

  Widget _dateHeader(DateTime date, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Text(
        archiveDateHeaderLabel(date),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.outline,
          height: 1.2,
        ),
      ),
    );
  }
}

class HistoryChatLoaderPage extends StatefulWidget {
  const HistoryChatLoaderPage({
    super.key,
    required this.item,
    required this.repository,
  });

  final HistoryIndexItem item;
  final RuntimeHistoryRepository repository;

  @override
  State<HistoryChatLoaderPage> createState() => _HistoryChatLoaderPageState();
}

class _HistoryChatLoaderPageState extends State<HistoryChatLoaderPage> {
  late Future<List<ChatMessage>> _messagesFuture;

  @override
  void initState() {
    super.initState();
    _messagesFuture = widget.repository.completeConversationMessages(
      widget.item,
    );
  }

  void _retry() {
    setState(() {
      _messagesFuture = widget.repository.completeConversationMessages(
        widget.item,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = _summaryDisplayTitle(widget.item);
    return FutureBuilder<List<ChatMessage>>(
      future: _messagesFuture,
      builder: (context, snapshot) {
        final messages = snapshot.data;
        if (messages != null) {
          return ReadOnlyChatViewPage(title: title, messages: messages);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            appBar: AppBar(title: Text(title)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Center(
            child: TextButton.icon(
              onPressed: _retry,
              icon: const Icon(LucideIcons.refresh_cw, size: 18),
              label: const Text('重新加载'),
            ),
          ),
        );
      },
    );
  }
}

class ArchiveListCard extends StatelessWidget {
  final HistoryIndexItem chat;
  final String title;
  final String meta;
  final bool inSelection;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDelete;

  const ArchiveListCard({
    super.key,
    required this.chat,
    required this.title,
    required this.meta,
    required this.inSelection,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: ValueKey('archive-card-${chat.id}'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 10, 15),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (inSelection) ...[
                  Icon(
                    selected ? LucideIcons.circle_check : LucideIcons.circle,
                    size: 23,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: ValueKey('archive-preview-${chat.id}'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w500,
                          color: context.semanticColors.text,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        meta,
                        key: ValueKey('archive-meta-${chat.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.timestamp,
                          color: context.semanticColors.mutedText,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!inSelection && onDelete != null)
                  PopupMenuButton<ArchiveCardAction>(
                    tooltip: '更多',
                    icon: Icon(
                      LucideIcons.ellipsis,
                      size: 20,
                      color: scheme.outline,
                    ),
                    onSelected: (action) {
                      if (action == ArchiveCardAction.delete) onDelete!();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: ArchiveCardAction.delete,
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.trash_2,
                              size: 18,
                              color: scheme.error,
                            ),
                            const SizedBox(width: 10),
                            Text('删除', style: TextStyle(color: scheme.error)),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ArchiveSelectionActionBar extends StatelessWidget {
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onMove;

  const ArchiveSelectionActionBar({
    super.key,
    required this.count,
    required this.onCancel,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: '取消多选',
                onPressed: onCancel,
                icon: const Icon(LucideIcons.x, size: 18),
              ),
              Expanded(
                child: Text(
                  '已选 $count 项',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: onMove,
                icon: const Icon(LucideIcons.folder_input, size: 17),
                label: const Text('移动到'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum ArchiveCardAction { delete }

class _ArchiveListEntry {
  const _ArchiveListEntry._({this.group, this.chat});

  final DateTime? group;
  final HistoryIndexItem? chat;

  const _ArchiveListEntry.group(DateTime group) : this._(group: group);

  const _ArchiveListEntry.chat(HistoryIndexItem chat) : this._(chat: chat);
}

class _HistoryLoadError extends StatelessWidget {
  const _HistoryLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refresh_cw, size: 18),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}
