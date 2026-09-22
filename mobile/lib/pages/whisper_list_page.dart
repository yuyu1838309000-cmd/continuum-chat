import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/personal_space.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart' show memTimeFull;

typedef WhisperListLoader = Future<List<Whisper>?> Function({bool force});

/// 个人内容 · 想说的话。保留“最新 + 月历 + 按日查看”的只读结构。
class WhisperListPage extends StatefulWidget {
  const WhisperListPage({super.key, this.loader});

  /// 测试和宿主可注入数据；生产默认继续走原有缓存与 /whisper 路径。
  final WhisperListLoader? loader;

  @override
  State<WhisperListPage> createState() => _WhisperListPageState();
}

class _WhisperListPageState extends State<WhisperListPage> {
  List<Whisper>? _whispers;
  bool _loading = true;
  bool _error = false;
  static const String _unknownDateKey = 'unknown';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），过期/无缓存才静默拉新；
  /// 下拉刷新/重试走 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    if (widget.loader case final loader?) {
      setState(() {
        _loading = _whispers == null;
        _error = false;
      });
      final whispers = await loader(force: force);
      if (!mounted) return;
      setState(() {
        if (whispers != null) _whispers = whispers;
        _loading = false;
        _error = _whispers == null;
      });
      return;
    }

    final url = ServerConfig.url(8820, '/whisper');
    if (!force && _whispers == null) {
      final cached = await ApiCache.read(url);
      final cachedWhispers = _parseWhispers(cached);
      if (!mounted) return;
      if (cachedWhispers != null) {
        setState(() {
          _whispers = cachedWhispers;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _whispers == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      timeout: const Duration(seconds: 8),
    );
    final whispers = _parseWhispers(raw);
    if (!mounted) return;
    setState(() {
      if (whispers != null) _whispers = whispers;
      _loading = false;
      _error = _whispers == null;
    });
  }

  static List<Whisper>? _parseWhispers(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) Whisper.fromJson(e),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('想说的话'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error) {
      return _errorState(context);
    }
    final whispers = _whispers ?? const <Whisper>[];
    final sorted = _sortWhispers(whispers);
    final latest = sorted.isEmpty ? null : sorted.first;
    final groups = _groupByDate(sorted);
    final latestDate = latest == null ? null : _dateKey(latest.createdAt);
    final unknownWhispers = groups[_unknownDateKey] ?? const <Whisper>[];
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.xl,
        ),
        children: [
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 120),
              child: Center(
                child: Text(
                  '还没有想说的话',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else ...[
            _latestCard(
              context,
              latest!,
              dateKey: latestDate!,
              dayWhispers: groups[latestDate] ?? <Whisper>[latest],
            ),
            for (final month in _months(groups.keys))
              _monthCalendarCard(context, month, groups),
            if (unknownWhispers.isNotEmpty)
              _unknownDateCard(context, unknownWhispers),
          ],
        ],
      ),
    );
  }

  static List<Whisper> _sortWhispers(List<Whisper> whispers) {
    final sorted = [...whispers];
    sorted.sort((a, b) {
      final at = _parseCreatedAt(a.createdAt)?.millisecondsSinceEpoch ?? 0;
      final bt = _parseCreatedAt(b.createdAt)?.millisecondsSinceEpoch ?? 0;
      final byTime = bt.compareTo(at);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return sorted;
  }

  static Map<String, List<Whisper>> _groupByDate(Iterable<Whisper> whispers) {
    final groups = <String, List<Whisper>>{};
    for (final whisper in whispers) {
      final key = _dateKey(whisper.createdAt);
      groups.putIfAbsent(key, () => <Whisper>[]).add(whisper);
    }
    return groups;
  }

  static String _dateKey(String createdAt) {
    final dt = _parseCreatedAt(createdAt);
    if (dt == null) return _unknownDateKey;
    final year = dt.year.toString().padLeft(4, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  static DateTime? _parseCreatedAt(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value.replaceFirst(' ', 'T'))?.toLocal();
  }

  static String _dateTitleFromKey(String key) {
    if (key == _unknownDateKey) return '未知日期';
    final dt = DateTime.tryParse(key);
    if (dt == null) return '未知日期';
    final now = DateTime.now();
    final date = '${dt.month}月${dt.day}日';
    return dt.year == now.year ? date : '${dt.year}年$date';
  }

  static List<String> _months(Iterable<String> dateKeys) {
    final months = <String>{};
    for (final key in dateKeys) {
      if (key.length < 7 || key == _unknownDateKey) continue;
      months.add(key.substring(0, 7));
    }
    return months.toList()..sort((a, b) => b.compareTo(a));
  }

  static String _formatDate(int year, int month, int day) =>
      '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  Widget _latestCard(
    BuildContext context,
    Whisper whisper, {
    required String dateKey,
    required List<Whisper> dayWhispers,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      child: Material(
        key: const ValueKey('latest_whisper'),
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openDay(dateKey, dayWhispers),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '最新',
                  style: TextStyle(
                    fontSize: AppType.timestamp,
                    fontWeight: FontWeight.w700,
                    color: context.accentColor,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _WhisperPassage(whisper: whisper, featured: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _monthCalendarCard(
    BuildContext context,
    String month,
    Map<String, List<Whisper>> groups,
  ) {
    final theme = Theme.of(context);
    final parts = month.split('-');
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final mon = int.tryParse(parts[1]) ?? DateTime.now().month;
    final first = DateTime(year, mon, 1);
    final days = DateTime(year, mon + 1, 0).day;
    final leading = first.weekday - 1; // 周一作为第一列
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: AppSpacing.sm),
            child: Text(
              '$year年$mon月',
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _weekdayHeader(context),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1,
            children: [
              for (var i = 0; i < leading; i++) const SizedBox.shrink(),
              for (var d = 1; d <= days; d++)
                _dayCell(context, year, mon, d, groups),
            ],
          ),
        ],
      ),
    );
  }

  Widget _weekdayHeader(BuildContext context) {
    final labels = const ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      children: [
        for (final label in labels)
          Expanded(
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppType.timestamp,
                  color: context.subTextColor.withValues(alpha: 0.72),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _dayCell(
    BuildContext context,
    int year,
    int month,
    int day,
    Map<String, List<Whisper>> groups,
  ) {
    final theme = Theme.of(context);
    final date = _formatDate(year, month, day);
    final whispers = groups[date] ?? const <Whisper>[];
    if (whispers.isEmpty) {
      return Center(
        child: Text(
          '$day',
          style: TextStyle(
            fontSize: AppType.caption,
            color: context.subTextColor.withValues(alpha: 0.42),
          ),
        ),
      );
    }
    final allConsumed = whispers.every((w) => w.consumed);
    final fill = allConsumed ? context.fieldColor : context.accentColor;
    final textColor = allConsumed
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onPrimary;
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDay(date, whispers),
        child: Stack(
          children: [
            Center(
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ),
            if (whispers.length > 1)
              Positioned(
                right: 4,
                bottom: 3,
                child: Text(
                  '${whispers.length}',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: textColor.withValues(alpha: 0.82),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _unknownDateCard(BuildContext context, List<Whisper> whispers) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => _openDay(_unknownDateKey, whispers),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '未知日期',
                    style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                Text(
                  '${whispers.length}',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevron_right,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.wifi_off, size: 24, color: grey),
          const SizedBox(height: 12),
          Text('想说的话连不上', style: TextStyle(fontSize: 14, color: grey)),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => _load(force: true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  void _openDay(String dateKey, List<Whisper> whispers) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _WhisperDayPage(
          title: _dateTitleFromKey(dateKey),
          whispers: _sortWhispers(whispers),
        ),
      ),
    );
  }
}

class _WhisperDayPage extends StatelessWidget {
  const _WhisperDayPage({required this.title, required this.whispers});

  final String title;
  final List<Whisper> whispers;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          itemCount: whispers.length,
          separatorBuilder: (_, _) => Divider(
            height: AppSpacing.xl,
            color: context.cardStrokeColor.withValues(alpha: 0.5),
          ),
          itemBuilder: (context, index) =>
              _WhisperPassage(whisper: whispers[index]),
        ),
      ),
    );
  }
}

class _WhisperPassage extends StatelessWidget {
  const _WhisperPassage({required this.whisper, this.featured = false});

  final Whisper whisper;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final dim = whisper.consumed;
    final textColor = dim ? context.subTextColor : context.textColor;
    return Opacity(
      opacity: dim ? 0.72 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (whisper.isPinned) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.pin, size: 13, color: context.subTextColor),
                const SizedBox(width: 6),
                Text(
                  '置顶',
                  style: TextStyle(
                    fontSize: AppType.timestamp,
                    color: context.subTextColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
          ],
          SelectionArea(
            child: Text(
              whisper.content,
              style: TextStyle(
                fontSize: featured ? 20 : 17,
                height: featured ? 1.65 : 1.75,
                fontWeight: featured ? FontWeight.w500 : FontWeight.w400,
                color: textColor,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            memTimeFull(whisper.createdAt),
            style: TextStyle(
              fontSize: AppType.timestamp,
              color: context.subTextColor,
            ),
          ),
        ],
      ),
    );
  }
}
