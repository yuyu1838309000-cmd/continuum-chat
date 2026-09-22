import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/reading_book.dart';
import '../services/api_cache.dart';
import '../services/reading_api.dart';
import '../services/reading_data_parser.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';

/// 书详情（一起读）：进度时间线 + 感想列表 + 评分（分人显示）+ 情绪 emoji。
/// 用户只能操作自己的评分/短评/情绪（上报 8816，AI 助手能感知并自然回应）；
/// AI 助手的评分来自 read-mcp 工具记录，这里只读。
class ReadingDetailPage extends StatefulWidget {
  final String title;

  const ReadingDetailPage({super.key, required this.title});

  @override
  State<ReadingDetailPage> createState() => _ReadingDetailPageState();
}

class _ReadingDetailPageState extends State<ReadingDetailPage> {
  ReadingBook? _book;
  bool _loading = true;
  bool _error = false;

  // 用户评分编辑态（从书数据初始化）
  int _score = 0;
  String _mood = '';
  final TextEditingController _commentCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 下拉刷新/保存后 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8070, '/read_data.json');
    if (!force && _book == null) {
      final cached = await ApiCache.read(url);
      final cachedBook = _findBook(parseReadingBooks(cached), widget.title);
      if (!mounted) return;
      if (cachedBook != null) {
        setState(() {
          _book = cachedBook;
          _loading = false;
          _error = false;
          _score = cachedBook.participantRating?.score ?? 0;
          _mood = cachedBook.participantRating?.mood ?? '';
          _commentCtrl.text = cachedBook.participantRating?.comment ?? '';
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _book == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      utf8Body: true,
      timeout: const Duration(seconds: 10),
    );
    if (!mounted) return;
    final found = _findBook(parseReadingBooks(raw), widget.title);
    setState(() {
      if (found != null) _book = found;
      _loading = false;
      _error = _book == null;
      if (found != null) {
        _score = found.participantRating?.score ?? 0;
        _mood = found.participantRating?.mood ?? '';
        _commentCtrl.text = found.participantRating?.comment ?? '';
      }
    });
  }

  static ReadingBook? _findBook(List<ReadingBook>? books, String title) {
    if (books == null) return null;
    for (final b in books) {
      if (b.title == title) return b;
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final res = await ReadingApi.reportActivity(
      title: widget.title,
      score: _score,
      mood: _mood,
      comment: _commentCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res == null || res['ok'] != true) {
      _toast('保存失败，再试一次');
      return;
    }
    _toast('已记下，AI 助手会看到的');
    await _load(force: true);
  }

  void _toast(String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
          duration: const Duration(milliseconds: 1600),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书详情'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: _buildBody(theme),
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
    final book = _book;
    if (_error || book == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('书详情连不上', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _headerCard(theme, book),
          _sectionTitle(theme, '评分'),
          _participantRatingCard(theme, book),
          _assistantRatingCard(theme, book),
          if (book.progress.isNotEmpty) ...[
            _sectionTitle(theme, '进度时间线'),
            _timelineCard(theme, book),
          ],
          if (book.notes.isNotEmpty) ...[
            _sectionTitle(theme, '感想'),
            _notesCard(theme, book),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  Widget _headerCard(ThemeData theme, ReadingBook book) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  book.title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _statusChip(theme, book.status),
            ],
          ),
          if (book.author.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              book.author,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (book.participantLastChapter.isNotEmpty ||
              book.assistantLastChapter.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (book.participantLastChapter.isNotEmpty)
                    _chapterLine(theme, '用户读到', book.participantLastChapter),
                  if (book.assistantLastChapter.isNotEmpty)
                    _chapterLine(theme, 'AI 助手读到', book.assistantLastChapter),
                ],
              ),
            ),
          if (book.summary.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              book.summary,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
          if (book.updated.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '更新于 ${book.updated}',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chapterLine(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            fontSize: 13,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: value,
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  /// 用户评分卡（可编辑）：星 + 情绪 emoji + 短评 + 保存。
  Widget _participantRatingCard(ThemeData theme, ReadingBook book) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '用户',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _starRow(theme, _score, (v) => setState(() => _score = v)),
          const SizedBox(height: 12),
          _moodRow(theme, _mood, (v) => setState(() => _mood = v)),
          const SizedBox(height: 12),
          TextField(
            controller: _commentCtrl,
            maxLength: 80,
            maxLines: 2,
            minLines: 1,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '当时看完想说的一句…',
              hintStyle: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.outline,
              ),
              counterText: '',
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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('记下来', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  /// AI 助手评分卡（只读）：星 + 情绪 + 短评 + 时间。
  Widget _assistantRatingCard(ThemeData theme, ReadingBook book) {
    final r = book.assistantRating;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI 助手',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          if (r == null)
            Text(
              'AI 助手还没评',
              style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _readonlyStars(theme, r.score),
                if (r.mood.isNotEmpty || r.comment.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: theme.colorScheme.onSurface,
                      ),
                      children: [
                        if (r.mood.isNotEmpty) TextSpan(text: '${r.mood} '),
                        if (r.comment.isNotEmpty) TextSpan(text: r.comment),
                      ],
                    ),
                  ),
                ],
                if (r.time.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      r.time,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _starRow(ThemeData theme, int value, ValueChanged<int> onChanged) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(i == value ? 0 : i),
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                LucideIcons.star,
                size: 26,
                color: i <= value
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
            ),
          ),
        if (value > 0)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Text(
              '$value 星',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
      ],
    );
  }

  Widget _readonlyStars(ThemeData theme, int score) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Icon(
              LucideIcons.star,
              size: 16,
              color: i <= score
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
            ),
          ),
      ],
    );
  }

  Widget _moodRow(
    ThemeData theme,
    String selected,
    ValueChanged<String> onChanged,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in readingMoodEmojis)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(selected == e ? '' : e),
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected == e
                    ? theme.colorScheme.primary.withValues(alpha: 0.14)
                    : context.fieldColor,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: selected == e
                    ? Border.all(color: theme.colorScheme.primary, width: 1)
                    : null,
              ),
              child: Text(e, style: const TextStyle(fontSize: 18)),
            ),
          ),
      ],
    );
  }

  Widget _timelineCard(ThemeData theme, ReadingBook book) {
    final sorted = [...book.progress]..sort((a, b) => b.time.compareTo(a.time));
    return _card(
      child: Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            _timelineRow(theme, sorted[i]),
          ],
        ],
      ),
    );
  }

  Widget _timelineRow(ThemeData theme, ReadingProgress p) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 7,
          height: 7,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: p.who == '用户'
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    p.who,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (p.time.isNotEmpty)
                    Text(
                      p.time,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
              if (p.chapter.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  p.chapter,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (p.text.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  p.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _notesCard(ThemeData theme, ReadingBook book) {
    final sorted = [...book.notes]..sort((a, b) => b.time.compareTo(a.time));
    return _card(
      child: Column(
        children: [
          for (var i = 0; i < sorted.length; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: sorted[i].who == '用户'
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            sorted[i].who,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            sorted[i].time,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        sorted[i].text,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
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

  Widget _card({required Widget child}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(18), child: child),
      ),
    );
  }
}
