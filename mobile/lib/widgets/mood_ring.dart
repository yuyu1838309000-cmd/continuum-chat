import 'dart:math';

import 'package:flutter/material.dart';

/// Continuum Chat 情绪圆环（v0.2.86）：完整 360° 中空玻璃管，色相连续无接缝。
/// - 整圈圆环、管子有粗细（中空管状，像呼啦圈）；
/// - 玻璃质感：半透明管体 + 极淡描边 + 内侧高光（alpha ≤0.2）；
/// - 渐变不再用固定 stops：逐角度按 HSL 色相连续映射，
///   hue = 120° + 角度（整圈 120°→480°，归一化后首尾同为绿自然闭合），
///   角度 0=绿（-10）、120=蓝（0）、240=红（+10），超过 +10 继续绕回绿；
///   浅色调（sat 适中、light 偏亮，不是深色、不是蓝紫绿）；
/// - 小球按 valence 在管上滑动，小球角度 hue = 240° + 12°×valence
///   （-10→绿、0→蓝、+10→红），250ms easeOut，入场从蓝端滑到分值。
class MoodRing extends StatefulWidget {
  final int valence;
  final String emoji;

  const MoodRing({super.key, required this.valence, required this.emoji});

  @override
  State<MoodRing> createState() => _MoodRingState();
}

class _MoodRingState extends State<MoodRing> {
  double _from = 0;
  double _target = 0;

  @override
  void initState() {
    super.initState();
    // 首帧小球停在中间（蓝），下一帧滑到真实分值（入场动画）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _target = widget.valence.toDouble());
    });
  }

  @override
  void didUpdateWidget(covariant MoodRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valence != widget.valence) {
      setState(() => _target = widget.valence.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 管壁蓝灰色调走主题语义（浅色下用 surfaceContainerHighest/outline，
    // 深色下用白 alpha 高光，玻璃质感保持）。
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 232,
      height: 232,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: _from, end: _target),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            onEnd: () => _from = _target,
            builder: (context, v, _) => CustomPaint(
              size: const Size.square(232),
              painter: _MoodRingPainter(
                v,
                dark: dark,
                tubeBottom: cs.surfaceContainerHighest,
                edge: cs.outline,
              ),
            ),
          ),
          Text(
            widget.emoji.isEmpty ? '😶' : widget.emoji,
            style: const TextStyle(fontSize: 48, height: 1),
          ),
        ],
      ),
    );
  }
}

class _MoodRingPainter extends CustomPainter {
  final double valence;
  final bool dark;
  final Color tubeBottom;
  final Color edge;

  const _MoodRingPainter(
    this.valence, {
    required this.dark,
    required this.tubeBottom,
    required this.edge,
  });

  static const double _tubeW = 26;
  static const double _bandAlpha = 0.9;
  static const double _bandSat = 0.72;
  static const double _bandLight = 0.68;

  /// 色相连续渐变（v0.2.86）：每度一个颜色，hue = 120° + 角度，
  /// 整圈 120°→480°（%360 归一化），首尾同为绿自然闭合无接缝；
  /// 角度 0=绿（-10）、120=蓝（0）、240=红（+10），再往后绕回绿。
  /// 带一点透明度（像管中流动的色液），玻璃管壁的浅蓝灰能透出来。
  static final SweepGradient _bandGradient = SweepGradient(
    startAngle: 0,
    endAngle: 2 * pi,
    colors: [
      for (var i = 0; i < 360; i++)
        HSLColor.fromAHSL(
          _bandAlpha,
          (120 + i) % 360,
          _bandSat,
          _bandLight,
        ).toColor(),
    ],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2 - _tubeW / 2 - 2;
    // 小球角度与色相一致：-10→0°（绿）、0→120°（蓝）、+10→240°（红）、
    // +20→360°（绿，与起点重合）。超过 +10 继续绕回绿。
    final v = valence.clamp(-10.0, 20.0);
    final angle = (v + 10) / 30 * 2 * pi;
    final rect = Rect.fromCircle(center: center, radius: r);

    // 1) 玻璃管体：半透明白 → 浅蓝灰（上亮下暗），管壁带一点色相，
    //    和纯白卡片分开，能看出「玻璃管」而不是细色条
    final body = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _tubeW
      ..strokeCap = StrokeCap.butt
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: dark
            ? [
                Colors.white.withValues(alpha: 0.4),
                Colors.white.withValues(alpha: 0.22),
              ]
            : [
                Colors.white.withValues(alpha: 0.62),
                tubeBottom.withValues(alpha: 0.5),
              ],
      ).createShader(rect.inflate(_tubeW + 4));
    canvas.drawArc(rect, 0, 2 * pi, false, body);

    // 2) 管内渐变：HSL 色相连续完整一圈（浅色调，像管中流动的色液）
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _tubeW - 8
      ..strokeCap = StrokeCap.butt
      ..shader = _bandGradient.createShader(rect.inflate(_tubeW + 4));
    canvas.drawArc(rect, 0, 2 * pi, false, band);

    // 3) 极淡描边（管外缘 / 管内缘）：浅色用蓝灰（白线在浅底上看不见）
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = dark
          ? Colors.white.withValues(alpha: 0.3)
          : edge.withValues(alpha: 0.4);
    canvas.drawCircle(center, r + _tubeW / 2, edgePaint);
    canvas.drawCircle(center, r - _tubeW / 2, edgePaint);

    // 4) 内侧高光：玻璃光泽，若有若无（alpha ≤0.2）
    final shine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt
      ..color = Colors.white.withValues(alpha: 0.18);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r - _tubeW / 2 + 2.5),
      0,
      2 * pi,
      false,
      shine,
    );

    // 5) 顶部外侧微光：更淡，只露一点玻璃反光
    final outerShine = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.12);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r + _tubeW / 2 - 2),
      200 * pi / 180,
      120 * pi / 180,
      false,
      outerShine,
    );

    // 6) 情绪小球：白球 + 柔影 + 极淡描边，浮在管上
    final pos = center + Offset(r * cos(angle), r * sin(angle));
    canvas.drawCircle(
      pos,
      12.5,
      Paint()
        ..color = Colors.black.withValues(alpha: dark ? 0.25 : 0.1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(pos, 11.5, Paint()..color = Colors.white);
    canvas.drawCircle(
      pos,
      11.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.08),
    );
  }

  @override
  bool shouldRepaint(_MoodRingPainter oldDelegate) =>
      oldDelegate.valence != valence || oldDelegate.dark != dark;
}
