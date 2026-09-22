import 'package:flutter/material.dart';

/// 右滑返回路由：iOS 风格滑动转场 + 全屏右滑手势返回上一级。
/// Android 上 CupertinoPageRoute 默认禁用手势（popGestureEnabled=false，
/// Flutter 源码为避免和横向滚动冲突），所以自己实现手势。
/// 用法和 MaterialPageRoute 一样：Navigator.push(context, SwipeBackRoute(builder: ...))。
class SwipeBackRoute<T> extends PageRouteBuilder<T> {
  SwipeBackRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: const Duration(milliseconds: 160),
        reverseTransitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (context, animation, secondaryAnimation) =>
            SwipeBackWrap(child: builder(context)),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 重页面只做短淡入淡出，避免整页横移 + 淡入同时抢首帧。
          final opacity = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(opacity: opacity, child: child);
        },
      );
}

/// 右滑返回手势：全屏右滑（速度或距离超阈值）→ 返回上一级。
/// 横向控件（Slider 等）在手势竞技场里是内层 recognizer，优先于外层手势，
/// 所以拖动 Slider 不会误触返回；竖向滚动不受影响。
class SwipeBackWrap extends StatefulWidget {
  final Widget child;
  const SwipeBackWrap({super.key, required this.child});

  @override
  State<SwipeBackWrap> createState() => _SwipeBackWrapState();
}

class _SwipeBackWrapState extends State<SwipeBackWrap> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _dx = 0,
      onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
      onHorizontalDragEnd: (d) {
        final velocity = d.primaryVelocity ?? 0;
        // 快速右滑（速度 > 350）或明显右滑（距离 > 80）→ 返回上一级
        if ((velocity > 350) || (_dx > 80 && velocity > 0)) {
          Navigator.of(context).maybePop();
        }
        _dx = 0;
      },
      onHorizontalDragCancel: () => _dx = 0,
      child: widget.child,
    );
  }
}
