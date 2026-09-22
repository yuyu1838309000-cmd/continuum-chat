import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

/// Continuum Chat 记忆日期列表页：完整时间线（全部记录日，可滚动）。
/// 主页「全部日期」入口进入。每行一天：日期（像素 24）+ 条数 + 摘要，
/// 整行可点（单卡直开详情，多卡先列当天再开单卡）。

class MemoryDaysPage extends StatefulWidget {
  const MemoryDaysPage({super.key});

  @override
  State<MemoryDaysPage> createState() => _MemoryDaysPageState();
}

class _MemoryDaysPageState extends State<MemoryDaysPage> {
  Map<String, List<MemoryCard>> _days = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显，过期/无缓存才静默拉新；
  /// 详情操作后 [force] 直接拉网。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8820, '/days');
    if (!force && _days.isEmpty) {
      final cached = await ApiCache.read(url);
      final cachedDays = _parseDays(cached);
      if (!mounted) return;
      if (cachedDays != null) {
        setState(() {
          _days = cachedDays;
          _loading = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    final raw = await ApiCache.fetchJson(
      url,
      timeout: const Duration(seconds: 8),
    );
    final days = _parseDays(raw);
    if (!mounted) return;
    setState(() {
      if (days != null) _days = days;
      _loading = false;
    });
  }

  static Map<String, List<MemoryCard>>? _parseDays(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    return {
      for (final e in raw.entries)
        e.key: [
          for (final c in (e.value as List<dynamic>? ?? const []))
            if (c is Map<String, dynamic>) MemoryCard.fromJson(c),
        ],
    };
  }

  List<MapEntry<String, List<MemoryCard>>> get _entries {
    final entries = _days.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    _backButton(context),
                    const SizedBox(width: 12),
                    Text(
                      '全部日期',
                      style: memPx(24, memTextOf(context), height: 1.2),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _loading
                    ? Center(
                        child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            color: memAccentOf(context),
                            strokeWidth: 2,
                          ),
                        ),
                      )
                    : _entries.isEmpty
                    ? _empty()
                    : _list(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 返回小圆钮（与主页一致，无文字）。
  Widget _backButton(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.all(10),
        child: Icon(
          LucideIcons.arrow_left,
          size: 20,
          color: memTextOf(context),
        ),
      ),
    );
  }

  /// 完整时间线：日期卡列表，整行可点。
  Widget _list() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 36),
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final entry = _entries[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _dayCard(entry),
        );
      },
    );
  }

  Widget _dayCard(MapEntry<String, List<MemoryCard>> entry) {
    final memT = memTextOf(context);
    final first = entry.value.first;
    final multi = entry.value.length > 1;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDay(entry),
      child: memCard(
        context: context,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(entry.key, style: memPx(24, memT, height: 1.2)),
                const Spacer(),
                if (multi)
                  Text(
                    '${entry.value.length} 条',
                    style: memBody(12, memT.withValues(alpha: 0.45)),
                  ),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevron_right,
                  size: 20,
                  color: memT.withValues(alpha: 0.3),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              first.content.isEmpty ? '（空）' : first.content,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: memBody(13, memT.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }

  /// 空态。
  Widget _empty() {
    final memT = memTextOf(context);
    return Center(
      child: Text('还没有记录的日子', style: memPx(24, memT.withValues(alpha: 0.35))),
    );
  }

  /// 单卡直开详情；多卡先弹当天列表再开单卡。
  Future<void> _openDay(MapEntry<String, List<MemoryCard>> entry) async {
    if (entry.value.length == 1) {
      _openDetail(entry.value.first);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryDaySheet(
        day: entry.key,
        cards: entry.value,
        onOpenCard: _openDetail,
      ),
    );
  }

  /// 卡片详情弹层（主页同款）。
  Future<void> _openDetail(MemoryCard card) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryDetailSheet(card: card),
    );
    if (!mounted) return;
    _load(force: true);
  }
}
