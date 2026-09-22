import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 三点跳动动画（停顿指示 / 思考中）。
/// 三个点相位错开 120°，依次上下跳动，颜色/大小可配。
/// 自带动画循环，dispose 自动释放，可随处复用。
class ThinkingDots extends StatefulWidget {
  final Color color;
  final double size;
  final double dotSize;

  const ThinkingDots({
    super.key,
    required this.color,
    this.size = 12,
    this.dotSize = 3,
  });

  @override
  State<ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<ThinkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // 三个点相位错开，sin 驱动上下位移，柔和不弹跳
            final phase = (_anim.value - i / 3) % 1.0;
            final dy = math.sin(phase * 2 * math.pi) * (widget.size * 0.35);
            final opacity =
                0.3 + 0.7 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
            return Transform.translate(
              offset: Offset(0, dy),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: widget.dotSize,
                  height: widget.dotSize,
                  margin: EdgeInsets.symmetric(
                    horizontal: widget.dotSize * 0.4,
                  ),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
