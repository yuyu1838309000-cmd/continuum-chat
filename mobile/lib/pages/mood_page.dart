import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/mood.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';
import '../widgets/mood_ring.dart';

/// Continuum Chat 情绪仪表盘（v0.2.85 重做，v0.2.123 加 11 维度 + 同快照）。
/// 聊天页顶部心情入口 → 全屏页。卡片：
/// 1. 主卡：完整 360° 中空玻璃管圆环（HSL 色相连续整圈无接缝，
///    绿→蓝→红→绕回绿，小球按 valence 在管上滑动 250ms easeOut，环中 emoji），
///    环下分值（+3），分值下直接是情绪标签（开心），再下才是内心活动 note；
///    底部低权重展示时间 + 来源；
/// 2. 维度卡：心情整行，其余 10 个维度响应式两列，同一条快照的 dims；
/// 3. 历史卡：当前之外最近 2 条，点开还原同快照（圆环/维度/来源一起切），
///    没有就显示空状态（卡片不消失）。
/// 风格：干净高智感，禁磨砂玻璃——卡片浅色底 + 极淡描边 + 柔阴影
/// （memCleanCard），管子的玻璃质感和卡片本身分开。
class MoodPage extends StatefulWidget {
  const MoodPage({super.key});

  @override
  State<MoodPage> createState() => _MoodPageState();
}

class _MoodPageState extends State<MoodPage> {
  MoodEntry? _current;
  List<MoodEntry> _history = const [];
  List<MoodEntry> _snapshots = const [];
  MoodEntry? _selected; // 历史点开的快照（null = 最新）
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 下拉刷新走 [force] 直接拉网。
  Future<void> _load({bool force = false}) async {
    final urls = [
      ServerConfig.url(8820, '/mood/current'),
      ServerConfig.url(8820, '/mood/history?limit=64'),
    ];
    if (!force && _current == null) {
      final cached = await Future.wait(urls.map(ApiCache.read));
      final cur = _parseCurrent(cached[0]);
      final hist = _parseHistory(cached[1]);
      if (!mounted) return;
      if (cur != null) {
        setState(() {
          _current = cur;
          final all = hist ?? const <MoodEntry>[];
          _snapshots = _mergeSnapshots(cur, all);
          _history = all.where((m) => m.id != cur.id).take(2).toList();
          _loading = false;
          _error = false;
          _selected = null;
        });
        final expired = await Future.wait(urls.map(ApiCache.isExpired));
        if (expired.every((e) => !e)) return;
      }
    }
    setState(() {
      _loading = _current == null;
      _error = false;
      _selected = null;
    });
    final raws = await Future.wait(
      urls.map(
        (u) => ApiCache.fetchJson(u, timeout: const Duration(seconds: 8)),
      ),
    );
    if (!mounted) return;
    final cur = _parseCurrent(raws[0]);
    final hist = _parseHistory(raws[1]) ?? const <MoodEntry>[];
    setState(() {
      if (cur != null) _current = cur;
      if (_current != null) {
        _snapshots = _mergeSnapshots(_current!, hist);
      }
      // 历史不含 current（按 id 过滤），最多取 2 条；为空也有卡（空状态）
      _history = _current == null
          ? const []
          : hist.where((m) => m.id != _current!.id).take(2).toList();
      _loading = false;
      _error = _current == null;
    });
  }

  static MoodEntry? _parseCurrent(dynamic raw) =>
      raw is Map<String, dynamic> && raw['id'] != null
      ? MoodEntry.fromJson(raw)
      : null;

  static List<MoodEntry>? _parseHistory(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic> && e['id'] != null) MoodEntry.fromJson(e),
    ];
  }

  static List<MoodEntry> _mergeSnapshots(
    MoodEntry current,
    Iterable<MoodEntry> history,
  ) {
    final byId = <int, MoodEntry>{current.id: current};
    for (final mood in history) {
      byId[mood.id] = mood;
    }
    final items = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));
    return items;
  }

  /// 当前展示的快照：最新，或历史点开的同快照。
  MoodEntry? get _displayed => _selected ?? _current;

  static const _tabularNumbers = [FontFeature.tabularFigures()];

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
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
    if (_error || _current == null) {
      return _errorState(context);
    }
    final m = _displayed!;
    final width = MediaQuery.sizeOf(context).width;
    final pageX = width < 360 ? 16.0 : (width < 400 ? 20.0 : 24.0);
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      color: memAccentOf(context),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(pageX, 12, pageX, 40),
        children: [
          _topBar(context),
          const SizedBox(height: 24),
          _mainCard(context, m),
          const SizedBox(height: 20),
          _dimsCard(context, m),
          const SizedBox(height: 16),
          _historyCard(context),
        ],
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Row(
      children: [
        _backButton(context),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '心情',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _px(24, memTextOf(context), height: 1),
          ),
        ),
        if (_selected != null) ...[
          const SizedBox(width: 12),
          _backToLatest(context),
        ],
      ],
    );
  }

  /// 返回小圆钮（无文字，干净白卡，非磨砂）。
  Widget _backButton(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: memCleanCard(
        context: context,
        circle: true,
        fullWidth: false,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(
              LucideIcons.arrow_left,
              size: 20,
              color: memTextOf(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 历史快照时的小胶囊：回到最新。
  Widget _backToLatest(BuildContext context) {
    final grey = memTextOf(context).withValues(alpha: 0.5);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selected = null),
      child: memCleanCard(
        context: context,
        radius: 999,
        fullWidth: false,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.rotate_ccw, size: 14, color: grey),
              const SizedBox(width: 6),
              Text('最新', maxLines: 1, style: memBody(12, grey, height: 1)),
            ],
          ),
        ),
      ),
    );
  }

  // ── 第一卡：情绪主卡 ──────────────────────────────────────────
  Widget _mainCard(BuildContext context, MoodEntry m) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.5);
    return memCleanCard(
      context: context,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          _responsiveMoodRing(m),
          const SizedBox(height: 22),
          // 分值：正整数带 +（-10~10 区间），无刻度行
          Text(
            m.valence > 0 ? '+${m.valence}' : '${m.valence}',
            style: _px(36, textColor, height: 1),
          ),
          if (m.label.isNotEmpty) ...[
            const SizedBox(height: 10),
            // 情绪标签：直接在分值下方，整页唯一点缀粉
            Text(
              m.label,
              style: TextStyle(
                color: memAccentOf(context),
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ],
          if (m.note.isNotEmpty) ...[
            const SizedBox(height: 14),
            // 标签下方才是内心活动一句
            Text(
              m.note,
              textAlign: TextAlign.center,
              style: memBody(14, grey, height: 1.7),
            ),
          ],
          if (m.createdAt.isNotEmpty || m.source.isNotEmpty) ...[
            const SizedBox(height: 28),
            _moodMetadata(context, m),
          ],
        ],
      ),
    );
  }

  Widget _responsiveMoodRing(MoodEntry m) {
    return LayoutBuilder(
      builder: (context, c) {
        final ringSize = c.hasBoundedWidth && c.maxWidth < 232
            ? c.maxWidth
            : 232.0;
        return SizedBox(
          width: ringSize,
          height: ringSize,
          child: FittedBox(
            fit: BoxFit.contain,
            child: MoodRing(valence: m.valence, emoji: m.emoji),
          ),
        );
      },
    );
  }

  Widget _moodMetadata(BuildContext context, MoodEntry m) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.46);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.clock, size: 14, color: grey),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.createdAt.isNotEmpty)
                Text(memTimeFull(m.createdAt), style: _px(12, grey, height: 1)),
              if (m.source.isNotEmpty) ...[
                if (m.createdAt.isNotEmpty) const SizedBox(height: 6),
                Text(m.source, style: memBody(12, grey, height: 1.5)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── 第二卡：11 维度条（v0.2.123）──────────────────────────────
  Widget _dimsCard(BuildContext context, MoodEntry m) {
    final grey = memTextOf(context).withValues(alpha: 0.5);
    final dims = resolveMoodDimensions(m, _snapshots);
    return memCleanCard(
      context: context,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('维度', style: _px(12, grey, height: 1)),
          const SizedBox(height: 18),
          if (dims.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('暂无维度数据', style: memBody(13, grey, height: 1)),
            )
          else ...[
            _dimRow(
              context,
              'valence',
              dims['valence'] ?? m.valence.toDouble(),
            ),
            const SizedBox(height: 20),
            _dimGrid(context, dims),
          ],
        ],
      ),
    );
  }

  Widget _dimGrid(BuildContext context, Map<String, double> values) {
    final dims = moodDimOrder
        .where((key) => key != 'valence' && values.containsKey(key))
        .toList();
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 240) {
          return Column(
            children: [
              for (var i = 0; i < dims.length; i++) ...[
                if (i > 0) const SizedBox(height: 16),
                _dimRow(context, dims[i], values[dims[i]]!, compact: true),
              ],
            ],
          );
        }
        final gap = c.maxWidth < 280 ? 12.0 : 16.0;
        final itemWidth = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: 16,
          children: [
            for (final key in dims)
              SizedBox(
                width: itemWidth,
                child: _dimRow(context, key, values[key]!, compact: true),
              ),
          ],
        );
      },
    );
  }

  /// 一根维度：中文名 + 数值（像素点缀）+ 低调数值条。
  Widget _dimRow(
    BuildContext context,
    String key,
    double value, {
    bool compact = false,
  }) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.45);
    final label = moodDimLabels[key] ?? key;
    final isValence = key == 'valence';
    final vText = isValence
        ? (value > 0 ? '+${value.round()}' : '${value.round()}')
        : '${value.round()}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: memBody(compact ? 12 : 13, textColor, height: 1),
              ),
            ),
            const SizedBox(width: 8),
            Text(vText, style: _px(12, grey, height: 1)),
          ],
        ),
        SizedBox(height: compact ? 6 : 8),
        _dimBar(
          context,
          min: isValence ? -10 : 0,
          max: 10,
          value: value,
          height: compact ? 5 : 6,
        ),
      ],
    );
  }

  /// 低调数值条：心情 -10~+10 从中心向两侧，其余 0-10 从左往右。
  Widget _dimBar(
    BuildContext context, {
    required double min,
    required double max,
    required double value,
    double height = 6,
  }) {
    final textColor = memTextOf(context);
    final track = textColor.withValues(alpha: 0.08);
    final fill = textColor.withValues(alpha: 0.52);
    final v = value.clamp(min, max).toDouble();
    final span = max - min;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            final f = ((v - min) / span).clamp(0.0, 1.0).toDouble();
            if (min < 0 && v != 0) {
              final half = w / 2;
              final fillW = (v > 0 ? f - 0.5 : 0.5 - f) * w;
              return Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: track)),
                  if (fillW > 0)
                    Positioned(
                      left: v > 0 ? half : half - fillW,
                      width: fillW,
                      top: 0,
                      bottom: 0,
                      child: ColoredBox(color: fill),
                    ),
                ],
              );
            }
            return Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: track)),
                Positioned(
                  left: 0,
                  width: f * w,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: fill),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 第三卡：历史情绪（当前之外最近 2 条；点开还原同快照） ────
  Widget _historyCard(BuildContext context) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.5);
    return memCleanCard(
      context: context,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('最近', style: _px(12, grey, height: 1)),
          const SizedBox(height: 16),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('还没有更多情绪记录', style: memBody(13, grey, height: 1)),
            )
          else
            for (var i = 0; i < _history.length; i++) ...[
              if (i > 0) const SizedBox(height: 18),
              _historyItem(context, _history[i]),
            ],
        ],
      ),
    );
  }

  Widget _historyItem(BuildContext context, MoodEntry mood) {
    final selected = _selected?.id == mood.id;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selected = mood),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        opacity: _selected == null || selected ? 1 : 0.66,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(
            alignment: Alignment.center,
            child: MoodRow(mood: mood),
          ),
        ),
      ),
    );
  }

  TextStyle _px(double size, Color color, {double? height}) => memPx(
    size,
    color,
    height: height,
  ).copyWith(fontFeatures: _tabularNumbers);

  // ── 错误 / 空状态 ────────────────────────────────────────────
  Widget _errorState(BuildContext context) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.5);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.wifi_off, size: 24, color: grey),
          const SizedBox(height: 12),
          Text('心情连不上', style: memBody(14, grey)),
          const SizedBox(height: 16),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _load(force: true),
            child: memCleanCard(
              context: context,
              radius: 999,
              fullWidth: false,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: Text('重试', style: memBody(13, textColor)),
            ),
          ),
        ],
      ),
    );
  }
}
