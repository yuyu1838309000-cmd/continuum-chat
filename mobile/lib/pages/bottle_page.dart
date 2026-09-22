import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/bottle.dart';
import '../services/api_cache.dart';
import '../services/bottle_api.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

typedef BottleDataLoader = Future<BottleData?> Function({bool force});

/// 提问瓶（v0.2.151，抽屉入口）：AI 助手往瓶里放问题，用户回答。
/// 结构（自上而下整页可滚）：8 维度统计卡（名称 + 已问问题数）→
/// 当前未回答的问题卡（罐子 + 问题 + 回答输入框 + 不回答）。
/// 回答动画：小纸条塞进上方罐子 + 罐子轻弹 + 「已收到」。
/// 风格照基准简洁卡片风：圆角 20 + cardShadow + cardColor，点缀色只走主题主色。
class BottlePage extends StatefulWidget {
  const BottlePage({super.key, @visibleForTesting this.dataLoader});

  @visibleForTesting
  final BottleDataLoader? dataLoader;

  @override
  State<BottlePage> createState() => _BottlePageState();
}

class _BottlePageState extends State<BottlePage> {
  BottleData? _data;
  bool _loading = true;
  bool _error = false;
  int _flipTick = 0; // 翻页后重建问题卡（重置动画/输入框状态）

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 下拉刷新/回答或跳过之后 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    if (widget.dataLoader case final loader?) {
      setState(() {
        _loading = _data == null;
        _error = false;
      });
      final data = await loader(force: force);
      if (!mounted) return;
      setState(() {
        if (data != null) _data = data;
        _loading = false;
        _error = _data == null;
      });
      return;
    }
    final url = ServerConfig.url(8820, '/bottle/questions');
    if (!force && _data == null) {
      final cached = await ApiCache.read(url);
      final cachedData = _parseData(cached);
      if (!mounted) return;
      if (cachedData != null) {
        setState(() {
          _data = cachedData;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _data == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      utf8Body: true,
      timeout: const Duration(seconds: 8),
    );
    final data = _parseData(raw);
    if (!mounted) return;
    setState(() {
      if (data != null) _data = data;
      _loading = false;
      _error = _data == null;
    });
  }

  static BottleData? _parseData(dynamic raw) =>
      raw is Map<String, dynamic> ? BottleData.fromJson(raw) : null;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('提问瓶'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final data = _data;
    if (_error || data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('提问瓶连不上', style: TextStyle(fontSize: 14)),
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _sectionHeading(
            theme,
            '今天想问你',
            data.latestUnanswered == null ? '这一轮暂时没有新问题' : 'AI 助手留了一张小纸条',
            primary: true,
          ),
          _QuestionCard(
            key: ValueKey('bottle-q-$_flipTick'),
            question: data.latestUnanswered,
            onDone: () {
              setState(() => _flipTick++);
              _load(force: true);
            },
          ),
          if (data.answeredRecent.isNotEmpty) ...[
            _sectionHeading(theme, '最近聊过', '已经回答过的小纸条'),
            for (final q in data.answeredRecent.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AnsweredBottleCard(question: q),
              ),
          ],
          if (data.dimensions.isNotEmpty) ...[
            _sectionHeading(theme, '按话题翻翻', '以前的提问都收在这里'),
            _dimensionGrid(theme, data.dimensions),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeading(
    ThemeData theme,
    String title,
    String subtitle, {
    bool primary = false,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, primary ? 4 : 26, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: primary ? 22 : 16,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 8 维度统计区：两列卡片，每张 = 图标 + 维度名 + 已问问题数。
  Widget _dimensionGrid(ThemeData theme, List<BottleDimension> dims) {
    if (dims.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final itemW = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: 12,
          children: [
            for (final d in dims)
              SizedBox(
                width: itemW,
                child: _DimensionCard(
                  dimension: d,
                  onTap: () => _openDimension(d.name),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _openDimension(String dimension) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _BottleDimensionPage(dimension: dimension),
      ),
    );
    if (mounted) _load(force: true);
  }
}

/// 单张维度统计卡：图标 + 维度名 + 已问数。
class _DimensionCard extends StatelessWidget {
  final BottleDimension dimension;
  final VoidCallback onTap;

  const _DimensionCard({required this.dimension, required this.onTap});

  static const Map<String, IconData> _icons = {
    '喜好': LucideIcons.heart,
    '经历': LucideIcons.map,
    '梦想': LucideIcons.sparkles,
    '关系': LucideIcons.heart_handshake,
    '三观': LucideIcons.compass,
    '日常': LucideIcons.coffee,
    '心情': LucideIcons.smile,
    '小秘密': LucideIcons.lock,
  };

  @override
  Widget build(BuildContext context) {
    final memT = memTextOf(context);
    final icon = _icons[dimension.name] ?? LucideIcons.circle_question_mark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: memCard(
        context: context,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: memT.withValues(alpha: 0.55)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                dimension.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${dimension.total}',
              style: memBody(13, memT.withValues(alpha: 0.5)),
            ),
            const SizedBox(width: 6),
            Icon(
              LucideIcons.chevron_right,
              size: 16,
              color: memT.withValues(alpha: 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottleDimensionPage extends StatefulWidget {
  final String dimension;

  const _BottleDimensionPage({required this.dimension});

  @override
  State<_BottleDimensionPage> createState() => _BottleDimensionPageState();
}

class _BottleDimensionPageState extends State<_BottleDimensionPage> {
  BottleData? _data;
  bool _loading = true;
  bool _error = false;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _data == null;
      _error = false;
    });
    final data = await BottleApi.fetch(dimension: widget.dimension);
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
      _error = data == null;
    });
  }

  List<BottleQuestion> _questions(BottleData data) {
    if (data.questions.isNotEmpty) return data.questions;
    final byId = <int, BottleQuestion>{};
    for (final q in [...data.unansweredList, ...data.answeredList]) {
      byId[q.id] = q;
    }
    return byId.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.dimension),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : _error || data == null
          ? Center(
              child: FilledButton.tonal(
                onPressed: _load,
                child: const Text('重试'),
              ),
            )
          : RefreshIndicator(onRefresh: _load, child: _buildList(data)),
    );
  }

  Widget _buildList(BottleData data) {
    final questions = _questions(data);
    if (questions.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          memCard(
            context: context,
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
            child: Center(
              child: Text(
                '这一类还没有问题',
                style: memBody(14, memTextOf(context).withValues(alpha: 0.65)),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: questions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final q = questions[index];
        final pending = q.status == '未答' || q.status.isEmpty;
        if (pending) {
          return _QuestionCard(
            key: ValueKey('bottle-dim-${q.id}-$_tick'),
            question: q,
            onDone: () {
              setState(() => _tick++);
              _load();
            },
          );
        }
        return _AnsweredBottleCard(question: q);
      },
    );
  }
}

class _AnsweredBottleCard extends StatelessWidget {
  final BottleQuestion question;

  const _AnsweredBottleCard({required this.question});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final memT = memTextOf(context);
    final answered = question.status == '已回答';
    return memCard(
      context: context,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                answered ? LucideIcons.check : LucideIcons.minus,
                size: 16,
                color: answered
                    ? theme.colorScheme.primary
                    : memT.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                question.status.isEmpty ? '已处理' : question.status,
                style: memBody(12, memT.withValues(alpha: 0.55)),
              ),
              const Spacer(),
              if (question.answeredAt.isNotEmpty)
                Text(
                  question.answeredAt.length >= 16
                      ? question.answeredAt.substring(0, 16)
                      : question.answeredAt,
                  style: memBody(11, memT.withValues(alpha: 0.42)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            question.question,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          if (question.answer.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              question.answer,
              style: memBody(13, memT.withValues(alpha: 0.72)),
            ),
          ],
        ],
      ),
    );
  }
}

enum _Phase { idle, flying, done }

/// 当前问题卡：罐子 + 问题 + 回答输入 + 不回答。
/// 回答成功 → 纸条从输入框飞进罐子（罐子轻弹）→ 「已收到」→ 翻页。
class _QuestionCard extends StatefulWidget {
  final BottleQuestion? question;
  final VoidCallback onDone;

  const _QuestionCard({
    super.key,
    required this.question,
    required this.onDone,
  });

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final TextEditingController _answerCtrl = TextEditingController();
  _Phase _phase = _Phase.idle;
  bool _busy = false;
  bool _lastSkipped = false;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1150),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            Future<void>.delayed(const Duration(milliseconds: 500), () {
              if (mounted) widget.onDone();
            });
          }
        });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final q = widget.question;
    if (q == null || _busy) return;
    final answer = _answerCtrl.text.trim();
    if (answer.isEmpty) return;
    setState(() => _busy = true);
    FocusManager.instance.primaryFocus?.unfocus();
    final r = await BottleApi.answer(id: q.id, answer: answer);
    if (!mounted) return;
    if (r == null || r['ok'] != true) {
      setState(() => _busy = false);
      _toast('没送进瓶子，再试一次');
      return;
    }
    setState(() {
      _phase = _Phase.flying;
      _lastSkipped = false;
    });
    _ctrl.forward(from: 0);
  }

  Future<void> _skip() async {
    final q = widget.question;
    if (q == null || _busy) return;
    setState(() => _busy = true);
    final ok = await BottleApi.skip(id: q.id);
    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      _toast('没跳过，再试一次');
      return;
    }
    setState(() => _lastSkipped = true);
    widget.onDone();
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
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    if (q == null) {
      // 空瓶状态：罐子 + 一句话
      return memCard(
        context: context,
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
        child: Column(
          children: [
            const _JarVisual(hasNote: false),
            const SizedBox(height: 20),
            Text(
              '瓶子空了',
              style: memBody(15, memTextOf(context).withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }
    final memT = memTextOf(context);
    return AnimatedOpacity(
      opacity: _lastSkipped ? 0 : 1,
      duration: const Duration(milliseconds: 180),
      child: memCard(
        context: context,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              children: [
                _JarVisual(
                  hasNote: _phase == _Phase.done,
                  pulse: _jarPulse,
                  wobble: _jarWobble,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        q.dimension,
                        style: memBody(12, memT.withValues(alpha: 0.6)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  q.question,
                  textAlign: TextAlign.center,
                  style: memPx(24, memT, height: 1.3),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _answerCtrl,
                  enabled: !_busy,
                  minLines: 2,
                  maxLines: 3,
                  maxLength: 120,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '写下你的回答…',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    filled: true,
                    fillColor: context.fieldColor,
                    counterText: '',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _skip,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                        ),
                        child: const Text(
                          '不回答',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                        ),
                        child: const Text('回答', style: TextStyle(fontSize: 14)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // 飞行的小纸条（输入框位置 → 罐子口，用 Align 比例定位）
            if (_phase != _Phase.idle)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment(0, _noteY),
                    child: Opacity(
                      opacity: _noteOpacity,
                      child: Transform.rotate(
                        angle: _noteRotation,
                        child: Transform.scale(
                          scale: _noteScale,
                          child: _PaperNote(text: _answerCtrl.text.trim()),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 「已收到」
            if (_phase != _Phase.idle)
              Positioned(
                left: 0,
                right: 0,
                top: 14,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: _doneOpacity,
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.check,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '已收到',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  double get _t => _ctrl.value;

  /// 纸条纵向位置：输入框区（+0.78）→ 罐子口（-0.72）。
  double get _noteY => lerpDouble(0.78, -0.72, _smooth(_t, 0.0, 0.52)) ?? 0;

  double get _noteScale =>
      0.72 + 0.18 * _smooth(_t, 0.0, 0.35) - 0.22 * _smooth(_t, 0.35, 0.62);

  double get _noteOpacity => 1.0 - 0.55 * _smooth(_t, 0.5, 0.75);

  double get _noteRotation => 0.06 * math.sin(_smooth(_t, 0.0, 0.55) * math.pi);

  /// 罐子轻弹（落地脉冲）。
  double get _jarPulse => _smooth(_t, 0.42, 0.7) < 1
      ? 1.0 + 0.12 * math.sin(_smooth(_t, 0.42, 0.7) * math.pi)
      : 1.0;

  /// 罐子微晃（落地小晃）。
  double get _jarWobble =>
      0.045 * math.sin(_smooth(_t, 0.45, 0.75) * math.pi * 2);

  double get _doneOpacity => _smooth(_t, 0.78, 0.96);

  double _smooth(double t, double a, double b) {
    if (t <= a) return 0;
    if (t >= b) return 1;
    return (t - a) / (b - a);
  }
}

/// 罐子：盖子 + 瓶身 + 瓶里的纸条。pulse/wobble 用于回答动画。
class _JarVisual extends StatelessWidget {
  final bool hasNote;
  final double pulse;
  final double wobble;

  const _JarVisual({this.hasNote = false, this.pulse = 1.0, this.wobble = 0.0});

  @override
  Widget build(BuildContext context) {
    final stroke = context.cardStrokeColor.withValues(alpha: 0.5);
    final accent = Theme.of(context).colorScheme.primary;
    return Transform.rotate(
      angle: wobble,
      child: Transform.scale(
        scale: pulse,
        child: SizedBox(
          width: 68,
          height: 78,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              // 盖子
              Positioned(
                top: 0,
                child: Container(
                  width: 30,
                  height: 12,
                  decoration: BoxDecoration(
                    color: context.cardColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: stroke, width: 1),
                  ),
                ),
              ),
              // 瓶口
              Positioned(
                top: 10,
                child: Container(
                  width: 44,
                  height: 12,
                  decoration: BoxDecoration(
                    color: context.cardColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: stroke, width: 1),
                  ),
                ),
              ),
              // 瓶身
              Positioned(
                top: 20,
                child: Container(
                  width: 64,
                  height: 58,
                  decoration: BoxDecoration(
                    color: context.cardColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: stroke, width: 1),
                  ),
                ),
              ),
              // 瓶里的小纸条
              if (hasNote)
                Positioned(
                  top: 34,
                  child: Container(
                    width: 36,
                    height: 24,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(
                      LucideIcons.check,
                      size: 14,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 飞行的小纸条：回答摘要折成纸条。
class _PaperNote extends StatelessWidget {
  final String text;

  const _PaperNote({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 76,
      constraints: const BoxConstraints(minHeight: 34, maxHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [context.cardShadow],
      ),
      child: Text(
        text.length > 8 ? '${text.substring(0, 8)}…' : text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          height: 1.3,
          color: theme.colorScheme.onPrimary,
        ),
      ),
    );
  }
}
