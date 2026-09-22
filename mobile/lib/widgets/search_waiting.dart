import 'package:flutter/material.dart';
import 'thinking_dots.dart';

/// "努力搜索中"等待动画（网页搜索时，AI 消息气泡内显示）。
/// 入场 200ms 淡入（动效短、不拖沓），文字旁三点跳动复用 ThinkingDots
/// （跟停顿/思考三点同一体系，不另起炉灶）；文案简短冷幽默，不整花哨。
class SearchWaiting extends StatefulWidget {
  final Color color;

  const SearchWaiting({super.key, required this.color});

  @override
  State<SearchWaiting> createState() => _SearchWaitingState();
}

class _SearchWaitingState extends State<SearchWaiting>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;

  @override
  void initState() {
    super.initState();
    // 入场淡入 200ms，easeOut，不炫技
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '努力搜索中',
            style: TextStyle(fontSize: 13, color: widget.color, height: 1.2),
          ),
          const SizedBox(width: 2),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ThinkingDots(color: widget.color, size: 14, dotSize: 3),
          ),
        ],
      ),
    );
  }
}
