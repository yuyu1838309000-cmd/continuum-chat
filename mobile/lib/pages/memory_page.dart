import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/memory_card.dart';
import '../models/mood.dart';
import '../services/api_cache.dart';
import '../services/memory_api.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';
import '../widgets/swipe_back.dart';
import 'memory_archive_page.dart';
import 'memory_category_page.dart';
import 'memory_days_page.dart';
import 'memory_trash_page.dart';
import 'mood_history_page.dart';
import 'server_config_page.dart';

/// Continuum Chat 记忆面板主页（简洁卡片风 v0.2.92）。
/// 结构（自上而下整页可滚）：返回钮 + 标题 + 新增记忆 → 最新记忆 → 统计
/// （浮卡/年轮/记录日）→ 日历热力 → 分类入口（我们/项目/规则 + 归档/回收站）→
/// 最近日期（含「全部日期」入口）→ 情绪区块。完整时间线收进日期页。
/// 风格：基准简洁卡片（圆角 20 + 柔和阴影 + cardColor 底 + 无解释小字 +
/// 留白多），背景跟主题（不再粉蓝渐变/磨砂玻璃），点缀色只走主题主色，
/// 标题/数字/日期与正文统一走系统无衬线。
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  Map<String, dynamic>? _stats;
  List<MemoryCard> _cards = const [];
  Map<String, List<MemoryCard>> _days = const {};
  int _archiveCount = 0;
  int _trashCount = 0;
  MemoryCard? _latest;
  List<MoodEntry>? _moods;
  bool _loading = true;
  String? _error;

  /// 分类体系：v0.2.74 我们/项目/规则 + v0.2.151 扩展 你/我/生活/心情/未分类
  /// （只加不删；「日子」tag 的日期卡保持独立，只进最近日期，不进分类栏）。
  static const _kCategories = ['我们', '项目', '规则', '你', '我', '生活', '心情', '未分类'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 七个接口的缓存键（与 MemoryApi/MoodApi 请求的 URL 完全一致）。
  List<String> _apiUrls() => [
    ServerConfig.url(8820, '/stats'),
    ServerConfig.url(8820, '/cards?ui=true'),
    ServerConfig.url(8820, '/days'),
    ServerConfig.url(8820, '/archive'),
    ServerConfig.url(8820, '/trash'),
    ServerConfig.url(8820, '/latest'),
    ServerConfig.url(8820, '/mood/history?limit=20'),
  ];

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 手动刷新 / 写操作后走 [force] 直接拉网。
  Future<void> _load({bool force = false}) async {
    if (!force && _stats == null) {
      final cached = await Future.wait(_apiUrls().map(ApiCache.read));
      final cachedStats = _parseStats(cached[0]);
      final cachedCards = _parseCards(cached[1]);
      final cachedDays = _parseDays(cached[2]);
      final cachedArchive = _parseArchive(cached[3]);
      final cachedTrash = _parseArchive(cached[4]);
      final cachedLatest = _parseLatest(cached[5]);
      final cachedMoods = _parseMoods(cached[6]);
      if (!mounted) return;
      // 至少一块有缓存才秒显，否则保持转圈直接走网络（首开无缓存不闪空页）。
      if (cachedStats != null || cachedCards != null || cachedDays != null) {
        setState(() {
          _stats = cachedStats;
          _cards = cachedCards ?? const [];
          _days = cachedDays ?? const {};
          _archiveCount = cachedArchive?.length ?? 0;
          _trashCount = cachedTrash?.length ?? 0;
          _latest = cachedLatest;
          _moods = cachedMoods;
          _loading = false;
          _error = null;
        });
      }
      // 六个缓存都齐且没过期：秒显的即是最新，不再重复拉网。
      final expired = await Future.wait(_apiUrls().map(ApiCache.isExpired));
      final allFresh =
          cachedStats != null &&
          cachedCards != null &&
          cachedDays != null &&
          expired.every((e) => !e);
      if (allFresh) return;
    }

    var results = await _fetchAll();
    // v0.2.81 容错：stats/cards/days 任一失败自动重试一次，仍失败才报错，
    // 不会出现分类全空只剩归档的假象。
    if (results[0] == null || results[1] == null || results[2] == null) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      results = await _fetchAll();
    }
    if (!mounted) return;
    setState(() {
      // 拉新失败保留已有缓存数据，不白屏不报错；拿到的字段才覆盖。
      if (results[0] != null) _stats = results[0] as Map<String, dynamic>;
      if (results[1] != null) _cards = results[1] as List<MemoryCard>;
      if (results[2] != null) {
        _days = results[2] as Map<String, List<MemoryCard>>;
      }
      if (results[3] != null) {
        _archiveCount = (results[3] as List<MemoryDetail>).length;
      }
      if (results[4] != null) {
        _trashCount = (results[4] as List<MemoryDetail>).length;
      }
      if (results[5] != null) _latest = results[5] as MemoryCard;
      if (results[6] != null) _moods = results[6] as List<MoodEntry>;
      _loading = false;
      if (_stats == null ||
          (results[1] == null && _cards.isEmpty) ||
          (results[2] == null && _days.isEmpty)) {
        _error = '服务未连接';
      } else {
        _error = null;
      }
    });
  }

  Future<List<Object?>> _fetchAll() async {
    final raws = await Future.wait(
      _apiUrls().map(
        (u) => ApiCache.fetchJson(u, timeout: const Duration(seconds: 8)),
      ),
    );
    return [
      _parseStats(raws[0]),
      _parseCards(raws[1]),
      _parseDays(raws[2]),
      _parseArchive(raws[3]),
      _parseArchive(raws[4]),
      _parseLatest(raws[5]),
      _parseMoods(raws[6]),
    ];
  }

  // ── 原始 JSON → 模型（与 API 服务解析逻辑一致）──────────────
  static Map<String, dynamic>? _parseStats(dynamic raw) =>
      raw is Map<String, dynamic> ? raw : null;

  static List<MemoryCard>? _parseCards(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) MemoryCard.fromJson(e),
    ];
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

  static List<MemoryDetail>? _parseArchive(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>)
          MemoryDetail(
            card: MemoryCard.fromJson(e),
            rings: [
              for (final r in (e['rings'] as List<dynamic>? ?? const []))
                if (r is Map<String, dynamic>) MemoryRing.fromJson(r),
            ],
            reproducible: e['reproducible'] == true,
          ),
    ];
  }

  static MemoryCard? _parseLatest(dynamic raw) =>
      raw is Map<String, dynamic> ? MemoryCard.fromJson(raw) : null;

  static List<MoodEntry>? _parseMoods(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic> && e['id'] != null) MoodEntry.fromJson(e),
    ];
  }

  /// 主题卡：title 非日期格式的浮卡。
  List<MemoryCard> get _themeCards =>
      _cards.where((c) => !c.isDateCard).toList();

  /// 该分类下的主题卡数量（分类入口卡用）。
  int _countOf(String category) {
    if (category == '未分类') {
      return _themeCards.where((c) {
        final first = c.tags.split(',').first.trim();
        return first.isEmpty || first == '未分类';
      }).length;
    }
    return _themeCards
        .where((c) => c.tags.split(',').first.trim() == category)
        .length;
  }

  /// 近两天日期条目（日期倒序取前 2）。
  List<MapEntry<String, List<MemoryCard>>> get _recentDays {
    final entries = _days.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return entries.take(2).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  Future<void> _openServerSettings() async {
    await Navigator.of(
      context,
    ).push(SwipeBackRoute(builder: (_) => const ServerConfigPage()));
    if (mounted) {
      await _load(force: true);
    }
  }

  Widget _buildBody() {
    final memT = memTextOf(context);
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            color: memAccentOf(context),
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.wifi_off,
              size: 24,
              color: memT.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text('服务未连接', style: memBody(14, memT.withValues(alpha: 0.7))),
            const SizedBox(height: 6),
            Text(
              '请检查服务器地址或本地调试连接',
              style: memBody(12, memT.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: _openServerSettings,
                  child: memCard(
                    context: context,
                    radius: 999,
                    fullWidth: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Text('服务器设置', style: memBody(13, memT)),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: () => _load(force: true),
                  child: memCard(
                    context: context,
                    radius: 999,
                    fullWidth: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 10,
                    ),
                    child: Text('重试', style: memBody(13, memT)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      color: memAccentOf(context),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Row(
            children: [
              _backButton(),
              const SizedBox(width: 12),
              Text('记忆', style: memPx(24, memT, height: 1.2)),
              const Spacer(),
              _addMemoryButton(),
            ],
          ),
          if (_latest != null) ...[const SizedBox(height: 24), _latestCard()],
          const SizedBox(height: 24),
          _statsRow(),
          const SizedBox(height: 24),
          _calendarCard(),
          const SizedBox(height: 24),
          _categorySection(),
          if (_recentDays.isNotEmpty) ...[
            const SizedBox(height: 24),
            _recentDaysCard(),
          ],
          if (_moods != null) ...[const SizedBox(height: 24), _moodSection()],
        ],
      ),
    );
  }

  /// 返回小圆钮（无文字，简洁卡片）。
  Widget _backButton() {
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

  /// 新增记忆胶囊按钮（顶部右侧）。
  Widget _addMemoryButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openNewMemory,
      child: memCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 15, color: memAccentOf(context)),
            const SizedBox(width: 6),
            Text('新增记忆', style: memBody(13, memAccentOf(context))),
          ],
        ),
      ),
    );
  }

  // ── 统计行：浮卡 / 年轮 / 记录日 ─────────────────────────────
  Widget _statsRow() {
    final fresh = (_stats?['fresh'] as num?)?.toInt() ?? 0;
    final rings = (_stats?['rings'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        Expanded(
          child: _statCapsule(number: '$fresh', label: '浮卡'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCapsule(number: '$rings', label: '年轮'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _statCapsule(number: '${_days.length}', label: '记录日'),
        ),
      ],
    );
  }

  Widget _statCapsule({required String number, required String label}) {
    final memT = memTextOf(context);
    return memCard(
      context: context,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        children: [
          Text(number, style: memPx(24, memT, height: 1.0)),
          const SizedBox(height: 6),
          Text(label, style: memBody(12, memT.withValues(alpha: 0.5))),
        ],
      ),
    );
  }

  // ── 日历热力：最近 35 天，7 列周历 ────────────────────────────
  Widget _calendarCard() {
    final memT = memTextOf(context);
    final today = DateTime.now();
    final start = today.subtract(const Duration(days: 34));
    final lead = start.weekday - 1; // 周一起
    final hasDays = _days.keys.toSet();
    return memCard(
      context: context,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(
        children: [
          Row(
            children: [
              for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(
                      w,
                      style: memBody(12, memT.withValues(alpha: 0.35)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.3,
            children: [
              for (var i = 0; i < lead; i++) const SizedBox.shrink(),
              for (var i = 0; i < 35; i++)
                _dayCell(start.add(Duration(days: i)), today, hasDays),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(DateTime d, DateTime today, Set<String> hasDays) {
    final dark = context.isDark;
    final memT = memTextOf(context);
    final key =
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final isToday =
        d.year == today.year && d.month == today.month && d.day == today.day;
    final has = hasDays.contains(key);
    final accent = memAccentOf(context);
    return Container(
      decoration: BoxDecoration(
        color: isToday
            ? accent
            : has
            ? accent.withValues(alpha: dark ? 0.28 : 0.16)
            : context.fieldColor,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        '${d.day}',
        style: memPx(
          12,
          isToday
              ? Theme.of(context).colorScheme.onPrimary
              : memT.withValues(alpha: has ? 0.8 : 0.45),
        ),
      ),
    );
  }

  // ── 分类入口：分类卡（只显示有卡的分类）+ 归档/回收站（常显）──
  Widget _categorySection() {
    final rows = <Widget>[];
    for (final c in _kCategories) {
      final count = _countOf(c);
      if (count > 0) {
        rows.add(
          _categoryRow(name: c, count: count, onTap: () => _openCategory(c)),
        );
        rows.add(const SizedBox(height: 12));
      }
    }
    rows.add(
      _categoryRow(name: '归档', count: _archiveCount, onTap: _openArchive),
    );
    rows.add(const SizedBox(height: 12));
    rows.add(_categoryRow(name: '回收站', count: _trashCount, onTap: _openTrash));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  /// 单张分类入口卡（基准卡片：图标 + 名称 + 数量 + chevron，无小字）。
  Widget _categoryRow({
    required String name,
    required int count,
    required VoidCallback onTap,
  }) {
    final memT = memTextOf(context);
    final icon = switch (name) {
      '我们' => LucideIcons.heart,
      '项目' => LucideIcons.folder,
      '规则' => LucideIcons.scroll_text,
      '你' => LucideIcons.user,
      '我' => LucideIcons.star,
      '生活' => LucideIcons.coffee,
      '心情' => LucideIcons.smile,
      '未分类' => LucideIcons.inbox,
      '回收站' => LucideIcons.trash_2,
      _ => LucideIcons.archive,
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: memCard(
        context: context,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24, color: memT.withValues(alpha: 0.55)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text('$count', style: memBody(13, memT.withValues(alpha: 0.5))),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.chevron_right,
              size: 22,
              color: memT.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }

  // ── 最新记忆卡：顶部展示最新一条（标题+内容+时间），点开进详情 ──
  Widget _latestCard() {
    final memT = memTextOf(context);
    final card = _latest!;
    final hasTitle = card.title.isNotEmpty;
    final activityPreview =
        card.latestActivityKind == 'ring' &&
            card.latestActivityContent.trim().isNotEmpty
        ? card.latestActivityContent.trim()
        : card.content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDetail(card),
      child: memCard(
        context: context,
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FreshnessDot(freshness: card.freshness),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _timeLabel(card),
                    style: memPx(12, memT.withValues(alpha: 0.35)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              hasTitle
                  ? card.title
                  : (card.content.isEmpty ? '（空）' : card.content),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: hasTitle
                  ? memPx(24, memT, height: 1.3)
                  : memBody(14, memT, height: 1.4),
            ),
            if (hasTitle) ...[
              const SizedBox(height: 10),
              Text(
                activityPreview.isEmpty ? '（空）' : activityPreview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: memBody(13, memT.withValues(alpha: 0.6)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 最近变化时间短格式：MM-DD HH:MM；旧服务端无该字段时回退创建时间。
  String _timeLabel(MemoryCard card) {
    final raw = card.latestActivityAt.trim().isNotEmpty
        ? card.latestActivityAt.trim()
        : card.createdAt.trim();
    return raw.length >= 16 ? raw.substring(5, 16) : raw;
  }

  // ── 最近日期：最近两天 + 全部日期入口 ─────────────────────────
  Widget _recentDaysCard() {
    final memT = memTextOf(context);
    final entries = _recentDays;
    return memCard(
      context: context,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最近日期', style: memPx(24, memT, height: 1.2)),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.push(
                    context,
                    SwipeBackRoute(builder: (_) => const MemoryDaysPage()),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 4,
                    horizontal: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.chevron_right,
                        size: 22,
                        color: memT.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (final entry in entries) ...[
            _recentDayTile(entry),
            if (entry != entries.last) const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }

  /// 单天条目：日期 + 条数 + 内容摘要（整条可点）。
  Widget _recentDayTile(MapEntry<String, List<MemoryCard>> entry) {
    final memT = memTextOf(context);
    final first = entry.value.first;
    final multi = entry.value.length > 1;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDay(entry),
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
    );
  }

  // ── 情绪区块：最近 3 条 mood_events，点卡看全部 ───────────────
  Widget _moodSection() {
    final memT = memTextOf(context);
    final moods = _moods ?? const <MoodEntry>[];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openMoodHistory,
      child: memCard(
        context: context,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('情绪', style: memPx(24, memT, height: 1.2)),
                const Spacer(),
                Icon(
                  LucideIcons.chevron_right,
                  size: 22,
                  color: memT.withValues(alpha: 0.35),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (moods.isEmpty)
              Text(
                '还没有情绪记录',
                style: memBody(13, memT.withValues(alpha: 0.5), height: 1),
              )
            else
              for (var i = 0; i < moods.length && i < 3; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                MoodRow(mood: moods[i]),
              ],
          ],
        ),
      ),
    );
  }

  /// 打开情绪记录列表页（GET /mood/history?limit=20 全部情绪事件）。
  void _openMoodHistory() {
    Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const MoodHistoryPage()),
    );
  }

  // ── 打开 ───────────────────────────────────────────────────
  void _openCategory(String category) {
    Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => MemoryCategoryPage(category: category)),
    );
  }

  void _openArchive() {
    Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const MemoryArchivePage()),
    );
  }

  Future<void> _openTrash() async {
    await Navigator.push(
      context,
      SwipeBackRoute(builder: (_) => const MemoryTrashPage()),
    );
    if (mounted) _load(force: true);
  }

  /// 新增记忆：弹编辑弹窗 → POST /write → 成功后刷新并提示结果。
  Future<void> _openNewMemory() async {
    final result = await showModalBottomSheet<MemoryEditResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryEditSheet(
        titleLabel: '新增记忆',
        confirmLabel: '保存',
        onSave: (title, content) async {
          final r = await MemoryApi.write(title: title, content: content);
          return MemoryEditResult(saved: r.saved, message: r.message);
        },
      ),
    );
    if (result?.saved == true && mounted) {
      _load(force: true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result!.message),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

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

  Future<void> _openDetail(MemoryCard card) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemoryDetailSheet(card: card),
    );
    _load(force: true); // 关闭后刷新：归档操作后卡片离开活跃区
  }
}
