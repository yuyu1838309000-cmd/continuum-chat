import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/reading_book.dart';
import '../services/api_cache.dart';
import '../services/reading_data_parser.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import 'reading_detail_page.dart';

typedef ReadingBooksLoader = Future<List<ReadingBook>?> Function({bool force});

/// 一起读（v0.2.148，抽屉入口）：共读小屋搬进Continuum Chat。
/// 三组（未读/正在看/已读）+ 搜索（书名/作者过滤）+ 书卡片（书名/作者/状态/进度数/
/// 感想数/双方评分），点书进详情（进度时间线 + 感想 + 评分 + 情绪 emoji）。
/// 数据源 read_data.json（8070 static，read-mcp 同源），BLOCKED 红线前端同样过滤。
/// 风格照基准简洁卡片风：圆角 20 + cardShadow + cardColor，全页点缀色只出现一处。
class ReadingPage extends StatefulWidget {
  const ReadingPage({super.key, @visibleForTesting this.booksLoader});

  @visibleForTesting
  final ReadingBooksLoader? booksLoader;

  @override
  State<ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<ReadingPage> {
  static const List<String> _groups = ['未读', '正在看', '已读'];

  List<ReadingBook>? _books;
  bool _loading = true;
  bool _error = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 下拉刷新/详情返回后 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    if (widget.booksLoader case final loader?) {
      setState(() {
        _loading = _books == null;
        _error = false;
      });
      final books = await loader(force: force);
      if (!mounted) return;
      setState(() {
        if (books != null) _books = books;
        _loading = false;
        _error = _books == null;
      });
      return;
    }
    final url = ServerConfig.url(8070, '/read_data.json');
    if (!force && _books == null) {
      final cached = await ApiCache.read(url);
      final cachedBooks = parseReadingBooks(cached);
      if (!mounted) return;
      if (cachedBooks != null) {
        setState(() {
          _books = cachedBooks;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _books == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      utf8Body: true,
      timeout: const Duration(seconds: 10),
    );
    final books = parseReadingBooks(raw);
    if (!mounted) return;
    setState(() {
      if (books != null) _books = books;
      _loading = false;
      _error = _books == null;
    });
  }

  List<ReadingBook> _grouped(String status) {
    final q = _query.trim().toLowerCase();
    final all = _books ?? const <ReadingBook>[];
    return all.where((b) {
      if (b.status != status) return false;
      if (q.isEmpty) return true;
      return b.title.toLowerCase().contains(q) ||
          b.author.toLowerCase().contains(q);
    }).toList();
  }

  int _groupCount(String status) => _grouped(status).length;

  void _openDetail(ReadingBook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReadingDetailPage(title: book.title)),
    );
    if (mounted) _load(force: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('一起读'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: Column(
          children: [
            _searchField(theme),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _searchField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: '搜书名或作者',
          hintStyle: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
          prefixIcon: Icon(
            LucideIcons.search,
            size: 18,
            color: theme.colorScheme.outline,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(LucideIcons.x, size: 16),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: context.fieldColor,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final books = _books;
    if (_error || books == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('共读小屋连不上', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (books.isEmpty) {
      return _emptyState(theme, '共读小屋还是空的');
    }
    final visible = _groups.any((g) => _groupCount(g) > 0);
    if (!visible) {
      return _emptyState(theme, '没找到这本书');
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (_groupCount('正在看') > 0) ...[
            _groupHeader(theme, '正在一起读', _groupCount('正在看'), primary: true),
            for (final book in _grouped('正在看'))
              _bookCard(theme, book, primary: true),
          ] else if (_query.trim().isEmpty) ...[
            _activeEmptyState(theme),
          ],
          for (final group in _groups.where((group) => group != '正在看'))
            if (_groupCount(group) > 0) ...[
              _groupHeader(theme, group, _groupCount(group)),
              for (final book in _grouped(group)) _bookCard(theme, book),
            ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _activeEmptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.fieldColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '现在没有正在一起读的书',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '从未读书架里选一本，再继续共享进度和感想。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.book_open,
            size: 34,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _groupHeader(
    ThemeData theme,
    String name,
    int count, {
    bool primary = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: Row(
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: primary ? 20 : 15,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _bookCard(ThemeData theme, ReadingBook book, {bool primary = false}) {
    final latestNote = primary ? _latestNote(book) : null;
    return Container(
      key: primary ? ValueKey('reading-active-${book.title}') : null,
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
          onTap: () => _openDetail(book),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        book.title,
                        style: TextStyle(
                          fontSize: primary ? 18 : 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (primary)
                      Text(
                        '继续读',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    else
                      _statusChip(theme, book.status),
                  ],
                ),
                if (book.author.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    book.author,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    _metaItem(
                      theme,
                      LucideIcons.clock,
                      '进度 ${book.progressCount}',
                    ),
                    const SizedBox(width: 16),
                    _metaItem(theme, LucideIcons.quote, '感想 ${book.noteCount}'),
                    const Spacer(),
                    Icon(
                      LucideIcons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
                if (primary &&
                    (book.participantLastChapter.isNotEmpty ||
                        book.assistantLastChapter.isNotEmpty)) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    children: [
                      if (book.participantLastChapter.isNotEmpty)
                        _readingProgress(
                          theme,
                          '用户读到',
                          book.participantLastChapter,
                        ),
                      if (book.assistantLastChapter.isNotEmpty)
                        _readingProgress(
                          theme,
                          'AI 助手读到',
                          book.assistantLastChapter,
                        ),
                    ],
                  ),
                ],
                if (latestNote != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    '最近感想 · ${latestNote.who}',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    latestNote.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (book.participantRating != null ||
                    book.assistantRating != null) ...[
                  const SizedBox(height: 12),
                  _ratingsPreview(theme, book),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  ReadingNote? _latestNote(ReadingBook book) {
    if (book.notes.isEmpty) return null;
    final notes = [...book.notes]..sort((a, b) => b.time.compareTo(a.time));
    return notes.first;
  }

  Widget _readingProgress(ThemeData theme, String label, String chapter) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        children: [
          TextSpan(text: '$label '),
          TextSpan(
            text: chapter,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(ThemeData theme, String status) {
    final color = switch (status) {
      '已读' => context.successColor,
      '正在看' => theme.colorScheme.primary,
      _ => theme.colorScheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(status, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _metaItem(ThemeData theme, IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.outline),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 双方评分预览：用户一条、AI 助手一条（只在评过的人出现）。
  Widget _ratingsPreview(ThemeData theme, ReadingBook book) {
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        if (book.participantRating != null)
          _personStars(theme, '用户', book.participantRating!),
        if (book.assistantRating != null)
          _personStars(theme, 'AI 助手', book.assistantRating!),
      ],
    );
  }

  Widget _personStars(ThemeData theme, String name, ReadingRating r) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 4),
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= r.score ? LucideIcons.star : LucideIcons.star,
            size: 13,
            color: i <= r.score
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
          ),
        if (r.mood.isNotEmpty) ...[
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 72),
            child: Text(
              r.mood,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}
