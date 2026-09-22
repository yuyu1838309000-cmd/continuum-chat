import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/personal_space.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../utils/diary_mood.dart';
import '../widgets/swipe_back.dart';
import 'diary_detail_page.dart';
import 'diary_overview_page.dart';

typedef DiaryListLoader = Future<List<DiaryEntry>?> Function({bool force});

/// 个人内容 · 日记。保留接口返回顺序，第一篇作为主要阅读入口。
class DiaryListPage extends StatefulWidget {
  const DiaryListPage({super.key, this.loader});

  /// 测试和宿主可注入数据；生产默认继续走原有缓存与 /diary 路径。
  final DiaryListLoader? loader;

  @override
  State<DiaryListPage> createState() => _DiaryListPageState();
}

class _DiaryListPageState extends State<DiaryListPage> {
  List<DiaryEntry>? _entries;
  bool _loading = true;
  bool _error = false;

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
        _loading = _entries == null;
        _error = false;
      });
      final entries = await loader(force: force);
      if (!mounted) return;
      setState(() {
        if (entries != null) _entries = entries;
        _loading = false;
        _error = _entries == null;
      });
      return;
    }

    final url = ServerConfig.url(8820, '/diary');
    if (!force && _entries == null) {
      final cached = await ApiCache.read(url);
      final cachedEntries = _parseEntries(cached);
      if (!mounted) return;
      if (cachedEntries != null) {
        setState(() {
          _entries = cachedEntries;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _entries == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      timeout: const Duration(seconds: 8),
    );
    final entries = _parseEntries(raw);
    if (!mounted) return;
    setState(() {
      if (entries != null) _entries = entries;
      _loading = false;
      _error = _entries == null;
    });
  }

  static List<DiaryEntry>? _parseEntries(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) DiaryEntry.fromJson(e),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('日记'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          actions: [
            IconButton(
              onPressed: _entries == null ? null : _openOverview,
              tooltip: '日期总览',
              icon: const Icon(LucideIcons.calendar_days, size: 21),
            ),
            const SizedBox(width: 8),
          ],
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
    final entries = _entries ?? const <DiaryEntry>[];
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 120),
              child: Center(
                child: Text(
                  '还没有日记',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else ...[
            _featuredEntry(context, entries.first),
            if (entries.length > 1) ...[
              const SizedBox(height: AppSpacing.lg),
              for (var index = 1; index < entries.length; index++) ...[
                _diaryRow(context, entries[index]),
                if (index < entries.length - 1)
                  Divider(
                    height: 1,
                    indent: AppSpacing.xs,
                    endIndent: AppSpacing.xs,
                    color: context.cardStrokeColor.withValues(alpha: 0.55),
                  ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _featuredEntry(BuildContext context, DiaryEntry entry) {
    return Container(
      key: const ValueKey('featured_diary_entry'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openDetail(context, entry),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _entryMeta(context, entry),
                const SizedBox(height: AppSpacing.md),
                Text(
                  entry.title.isEmpty ? '无题' : entry.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                if (entry.content.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    entry.content,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.body,
                      height: 1.7,
                      color: context.subTextColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _diaryRow(BuildContext context, DiaryEntry entry) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: () => _openDetail(context, entry),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _entryMeta(context, entry),
              const SizedBox(height: AppSpacing.xs),
              Text(
                entry.title.isEmpty ? '无题' : entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (entry.content.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  entry.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.caption,
                    height: 1.55,
                    color: context.subTextColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _entryMeta(BuildContext context, DiaryEntry entry) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (entry.date.isNotEmpty)
          Text(
            entry.date,
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
        if (entry.weather.isNotEmpty)
          Text(
            entry.weather,
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
        if (entry.mood.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: diaryMoodColor(entry.moodScore),
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(width: 8, height: 8),
              ),
              const SizedBox(width: 6),
              Text(
                entry.mood,
                style: TextStyle(
                  fontSize: AppType.caption,
                  color: context.subTextColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
      ],
    );
  }

  void _openDetail(BuildContext context, DiaryEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => DiaryDetailPage(entry: entry)),
    );
  }

  void _openOverview() {
    final entries = [...?_entries]..sort((a, b) => a.date.compareTo(b.date));
    Navigator.of(
      context,
    ).push(SwipeBackRoute(builder: (_) => DiaryOverviewPage(entries: entries)));
  }

  Widget _errorState(BuildContext context) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.wifi_off, size: 24, color: grey),
          const SizedBox(height: 12),
          Text('日记连不上', style: TextStyle(fontSize: 14, color: grey)),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => _load(force: true),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
