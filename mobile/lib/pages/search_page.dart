import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/message.dart';
import '../services/runtime_history_api.dart';
import '../services/runtime_history_models.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../utils/time_format.dart';
import '../widgets/swipe_back.dart';
import 'read_only_chat_view_page.dart';

/// 搜索页只读取 Runtime canonical history 与只读 legacy archive。
/// 当前窗口仅用于把 Runtime event 精确定位回聊天页，不参与搜索结果拼接。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.currentMessages,
    this.repository,
    this.debounceDuration = const Duration(milliseconds: 400),
    this.pageSize = 30,
  });

  final List<ChatMessage> currentMessages;
  final RuntimeHistoryRepository? repository;
  final Duration debounceDuration;
  final int pageSize;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _focus = FocusNode();

  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  Timer? _debounce;
  int _querySequence = 0;
  List<HistorySearchHit> _results = const [];
  bool _searching = false;
  bool _loadingMore = false;
  bool _searched = false;
  bool _fromCache = false;
  bool _hasMore = false;
  String _phase = 'runtime';
  String? _cursor;
  int? _revision;
  String? _searchError;
  String? _paginationError;
  HistorySearchHit? _openingHit;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RuntimeHistoryRepository();
    _ownsRepository = widget.repository == null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_ownsRepository) _repository.close();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _queryText => _query.text.trim();
  String get _normalizedQuery => _queryText.toLowerCase();

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    final sequence = ++_querySequence;
    setState(() {
      _results = const [];
      _searching = false;
      _loadingMore = false;
      _searched = false;
      _fromCache = false;
      _hasMore = false;
      _phase = 'runtime';
      _cursor = null;
      _revision = null;
      _searchError = null;
      _paginationError = null;
    });
    final query = _queryText;
    if (query.isEmpty) return;
    _debounce = Timer(widget.debounceDuration, () {
      _search(query: query, sequence: sequence, append: false);
    });
  }

  Future<void> _search({
    required String query,
    required int sequence,
    required bool append,
  }) async {
    if (!mounted || query.isEmpty || sequence != _querySequence) return;
    setState(() {
      if (append) {
        _loadingMore = true;
        _paginationError = null;
      } else {
        _searching = true;
        _searchError = null;
      }
    });
    try {
      final page = await _repository.search(
        query,
        phase: append ? _phase : 'runtime',
        cursor: append ? _cursor : null,
        limit: widget.pageSize,
        expectedRevision: append ? _revision : null,
      );
      if (!mounted || sequence != _querySequence || query != _queryText) {
        return;
      }
      setState(() {
        _results = append ? [..._results, ...page.results] : page.results;
        _searching = false;
        _loadingMore = false;
        _searched = true;
        _fromCache = _fromCache || page.fromCache;
        _hasMore = page.hasMore;
        _phase = page.phase;
        _cursor = page.nextCursor;
        _revision = page.revision ?? _revision;
        _searchError = null;
        _paginationError = null;
      });
    } on RuntimeHistoryException catch (error) {
      if (!mounted || sequence != _querySequence || query != _queryText) {
        return;
      }
      setState(() {
        _searching = false;
        _loadingMore = false;
        _searched = true;
        if (append) {
          _paginationError = error.message;
        } else {
          _searchError = error.message;
        }
      });
    } catch (_) {
      if (!mounted || sequence != _querySequence || query != _queryText) {
        return;
      }
      setState(() {
        _searching = false;
        _loadingMore = false;
        _searched = true;
        if (append) {
          _paginationError = '更多搜索结果加载失败';
        } else {
          _searchError = '历史搜索失败，请重试';
        }
      });
    }
  }

  void _retryInitial() {
    final query = _queryText;
    if (query.isEmpty) return;
    _search(query: query, sequence: _querySequence, append: false);
  }

  void _loadMore() {
    final query = _queryText;
    if (query.isEmpty || _loadingMore || !_hasMore) return;
    _search(query: query, sequence: _querySequence, append: true);
  }

  int _currentIndexOf(HistorySearchHit hit) {
    if (hit.legacyArchive) return -1;
    final eventId = hit.message.eventId;
    if (eventId == null || eventId.isEmpty) return -1;
    return widget.currentMessages.indexWhere(
      (message) => message.eventId == eventId,
    );
  }

  Future<void> _onTapResult(HistorySearchHit hit) async {
    final currentIndex = _currentIndexOf(hit);
    if (currentIndex >= 0) {
      Navigator.pop(context, currentIndex);
      return;
    }
    if (_openingHit != null) return;

    if (hit.legacyArchive && hit.groupBucket != 'windowed') {
      _openReadOnly(hit, [hit.message], title: '旧历史补充记录');
      return;
    }

    setState(() => _openingHit = hit);
    try {
      final messages = await _repository.completeSearchHitMessages(hit);
      if (!mounted) return;
      _openReadOnly(hit, messages, title: hit.legacyArchive ? '旧历史对话' : '历史对话');
    } on RuntimeHistoryException catch (error) {
      if (!mounted) return;
      _showOpenError(error.message);
    } catch (_) {
      if (!mounted) return;
      _showOpenError('对话详情加载失败，请重试');
    } finally {
      if (mounted) setState(() => _openingHit = null);
    }
  }

  void _showOpenError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openReadOnly(
    HistorySearchHit hit,
    List<ChatMessage> messages, {
    required String title,
  }) {
    Navigator.push(
      context,
      SwipeBackRoute(
        builder: (_) => ReadOnlyChatViewPage(
          title: title,
          messages: messages,
          focusEventId: hit.message.eventId,
          focusRawEventId: hit.message.rawEventId,
        ),
      ),
    );
  }

  Widget _preview(HistorySearchHit hit, TextStyle style) {
    final text = _visiblePreview(hit.message);
    if (hit.attachmentContentMatch) {
      return Text(
        text,
        style: style,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }
    return _highlightText(text, style);
  }

  String _visiblePreview(ChatMessage message) {
    final parts = <String>[
      if (message.content.trim().isNotEmpty) message.content.trim(),
      if ((message.fileName ?? '').trim().isNotEmpty)
        '附件：${message.fileName!.trim()}',
      if ((message.imageUrl ?? '').isNotEmpty || message.imageUrls.isNotEmpty)
        '图片附件',
    ];
    return parts.isEmpty ? '附件消息' : parts.join('\n');
  }

  Widget _highlightText(String text, TextStyle base) {
    final keyword = _normalizedQuery;
    if (keyword.isEmpty) {
      return Text(
        text,
        style: base,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      );
    }
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(keyword, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + keyword.length),
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onTertiaryContainer,
          ),
        ),
      );
      start = index + keyword.length;
    }
    return Text.rich(
      TextSpan(children: spans, style: base),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _sourceLabel(HistorySearchHit hit) {
    if (_currentIndexOf(hit) >= 0) return '当前对话';
    if (!hit.legacyArchive) return '历史对话';
    return hit.groupBucket == 'windowed' ? '旧历史' : '旧历史补充';
  }

  Widget _resultCard(HistorySearchHit hit) {
    final theme = Theme.of(context);
    final message = hit.message;
    final isMe = message.role == 'user';
    final opening = identical(_openingHit, hit);
    final identity = message.eventId ?? hit.legacyGroupId ?? 'unknown';
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('search-hit-${message.eventId ?? hit.legacyGroupId}'),
          onTap: opening ? null : () => _onTapResult(hit),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KeyedSubtree(
                  key: ValueKey('search-hit-content-$identity'),
                  child: _preview(
                    hit,
                    theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                          height: 1.45,
                        ) ??
                        const TextStyle(),
                  ),
                ),
                if (hit.attachmentContentMatch) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '附件内容命中',
                    key: ValueKey('search-hit-attachment-$identity'),
                    style: TextStyle(
                      fontSize: AppType.timestamp,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(
                      isMe ? '我' : 'AI 助手',
                      style: TextStyle(
                        fontSize: AppType.timestamp,
                        color: context.semanticColors.mutedText,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                      ),
                      child: Text(
                        '·',
                        style: TextStyle(
                          fontSize: AppType.timestamp,
                          color: context.semanticColors.mutedText,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _sourceLabel(hit),
                        key: ValueKey('search-hit-meta-$identity'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.timestamp,
                          color: context.semanticColors.mutedText,
                        ),
                      ),
                    ),
                    if (opening)
                      const Padding(
                        padding: EdgeInsets.only(right: AppSpacing.xs),
                        child: SizedBox.square(
                          dimension: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Text(
                      formatMessageTime(message.time, null),
                      style: TextStyle(
                        fontSize: AppType.timestamp,
                        color: context.semanticColors.mutedText,
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

  Widget _statusLabel(String text, {bool loading = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      child: Row(
        children: [
          if (loading) ...[
            const SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queryEmpty = _queryText.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: TextField(
            controller: _query,
            focusNode: _focus,
            onChanged: _onQueryChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜历史消息…',
              prefixIcon: const Icon(LucideIcons.search, size: 20),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      icon: const Icon(LucideIcons.x, size: 18),
                      onPressed: () {
                        _query.clear();
                        _onQueryChanged('');
                      },
                    ),
              filled: true,
              fillColor: context.fieldColor,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: queryEmpty
          ? const _EmptyHint(text: '输入关键词，搜咱们聊过的内容')
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              children: [
                if (_searching)
                  _statusLabel('正在搜索全部历史…', loading: true)
                else if (_searchError != null) ...[
                  _statusLabel(_searchError!),
                  _retryButton(onPressed: _retryInitial),
                ] else ...[
                  if (_fromCache) _statusLabel('当前显示离线缓存结果'),
                  for (final hit in _results) ...[
                    _resultCard(hit),
                    const SizedBox(height: 8),
                  ],
                  if (_searched && _results.isEmpty)
                    _EmptyHint(text: _fromCache ? '离线缓存里没有匹配结果' : '没有找到相关内容'),
                  if (_paginationError != null) ...[
                    _statusLabel('更多结果加载失败：$_paginationError'),
                    _retryButton(onPressed: _loadMore),
                  ] else if (_loadingMore)
                    _statusLabel('正在加载更多…', loading: true)
                  else if (_hasMore)
                    Center(
                      child: TextButton(
                        key: const ValueKey('search-load-more'),
                        onPressed: _loadMore,
                        child: const Text('加载更多'),
                      ),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _retryButton({required VoidCallback onPressed}) {
    return Center(
      child: TextButton.icon(
        key: const ValueKey('search-retry'),
        onPressed: onPressed,
        icon: const Icon(LucideIcons.rotate_cw, size: 16),
        label: const Text('重试'),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Text(
          text,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}
