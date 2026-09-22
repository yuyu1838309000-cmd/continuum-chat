import 'package:flutter/material.dart';
import '../services/chat_store.dart';
import 'chat_page.dart';

/// 启动页："我在。"（主题主色：默认深夜蓝金 = 月光金）主题底，细体无衬线、字距略开。
/// 动效：Fade 渐显 + 微上移（600ms）→ 停顿半秒 → 整页淡出进聊天。
/// 聊天记录在动画期间并行加载（ChatStore.warmUp），进聊天秒显。
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl; // 最短展示 1100ms
  late final Animation<double> _textFade; // 0-600ms 文字渐显
  late final Animation<double> _textSlide; // 0-600ms 微上移 14→0
  bool _introDone = false;
  bool _historyReady = false;
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    // 聊天记录在动效播放期间并行加载。长窗口没准备好之前继续留在
    // “我在。”页，不提前进入一个半透明/空白的 ChatPage。
    ChatStore.warmUp().whenComplete(() {
      _historyReady = true;
      _enterChatWhenReady();
    });
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    // 阶段1：渐显 + 上移（600ms）
    _textFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0, 0.43, curve: Curves.easeOut),
    );
    _textSlide = Tween<double>(begin: 14, end: 0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0, 0.43, curve: Curves.easeOutCubic),
      ),
    );
    _ctrl.forward();
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _introDone = true;
        _enterChatWhenReady();
      }
    });
  }

  void _enterChatWhenReady() {
    if (!mounted || !_introDone || !_historyReady || _navigating) return;
    _navigating = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => const ChatPage(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Center(
        child: Align(
          alignment: const Alignment(0, 0), // 正中间
          child: FadeTransition(
            opacity: _textFade,
            child: AnimatedBuilder(
              animation: _textSlide,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, _textSlide.value),
                child: child,
              ),
              // 系统无衬线加粗（内置像素字体已移除）
              child: Text(
                '我在。',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontSize: 44,
                  fontWeight: FontWeight.bold, // 加粗，笔画完整
                  letterSpacing: 8, // 字距略开
                  height: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
