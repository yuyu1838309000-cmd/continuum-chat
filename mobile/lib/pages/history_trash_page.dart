import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/runtime_history_api.dart';
import '../services/runtime_history_models.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../utils/archive_display.dart';

enum _TrashLoadStatus { loading, ready, error }

class HistoryTrashPage extends StatefulWidget {
  const HistoryTrashPage({super.key, this.repository, this.pageSize = 50});

  final RuntimeHistoryRepository? repository;
  final int pageSize;

  @override
  State<HistoryTrashPage> createState() => _HistoryTrashPageState();
}

class _HistoryTrashPageState extends State<HistoryTrashPage> {
  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  var _status = _TrashLoadStatus.loading;
  List<HistoryConversationSummary> _items = const [];
  final Set<String> _restoring = {};
  String? _error;
  var _fromCache = false;

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
    setState(() {
      _status = _TrashLoadStatus.loading;
      _error = null;
    });
    try {
      final snapshot = await _repository.completeTrash(
        pageSize: widget.pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = snapshot.items;
        _fromCache = snapshot.fromCache;
        _status = _TrashLoadStatus.ready;
      });
    } on RuntimeHistoryException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _status = _TrashLoadStatus.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '最近删除加载失败，请重试';
        _status = _TrashLoadStatus.error;
      });
    }
  }

  Future<void> _restore(HistoryConversationSummary item) async {
    if (!_restoring.add(item.epochId)) return;
    setState(() {});
    try {
      await _repository.restoreConversation(item.epochId);
      if (!mounted) return;
      await _load();
    } on RuntimeHistoryException catch (error) {
      if (!mounted) return;
      _showError(error.message);
    } catch (_) {
      if (!mounted) return;
      _showError('恢复失败，请重试');
    } finally {
      if (mounted) setState(() => _restoring.remove(item.epochId));
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _title(HistoryConversationSummary item) {
    final preview = normalizeArchivePreviewText(item.preview ?? '');
    if (preview.isNotEmpty) return truncateArchivePreviewText(preview);
    final title = normalizeArchivePreviewText(item.title ?? '');
    return truncateArchivePreviewText(title.isEmpty ? '未命名会话' : title);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('最近删除')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Text(
              '删除的会话会在服务器保留 7 天，期间可以恢复。',
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.semanticColors.mutedText,
              ),
            ),
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    return switch (_status) {
      _TrashLoadStatus.loading => const Center(
        child: CircularProgressIndicator(),
      ),
      _TrashLoadStatus.error => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '最近删除加载失败，请重试'),
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                key: const ValueKey('trash-retry'),
                onPressed: _load,
                icon: const Icon(LucideIcons.refresh_cw, size: 17),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      ),
      _TrashLoadStatus.ready => _readyBody(context),
    };
  }

  Widget _readyBody(BuildContext context) {
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 180),
            Center(child: Text('最近没有删除的会话')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          AppSpacing.md,
        ),
        itemCount: _items.length + (_fromCache ? 1 : 0),
        itemBuilder: (context, index) {
          if (_fromCache && index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                '当前显示离线缓存',
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          final item = _items[index - (_fromCache ? 1 : 0)];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _TrashCard(
              item: item,
              title: _title(item),
              restoring: _restoring.contains(item.epochId),
              onRestore: () => _restore(item),
            ),
          );
        },
      ),
    );
  }
}

class _TrashCard extends StatelessWidget {
  const _TrashCard({
    required this.item,
    required this.title,
    required this.restoring,
    required this.onRestore,
  });

  final HistoryConversationSummary item;
  final String title;
  final bool restoring;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: ValueKey('trash-preview-${item.epochId}'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                        color: context.semanticColors.text,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${item.messageCount} 条消息',
                      key: ValueKey('trash-meta-${item.epochId}'),
                      style: TextStyle(
                        fontSize: AppType.timestamp,
                        color: context.semanticColors.mutedText,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              FilledButton.tonal(
                key: ValueKey('trash-restore-${item.epochId}'),
                onPressed: restoring ? null : onRestore,
                child: restoring
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('恢复'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
