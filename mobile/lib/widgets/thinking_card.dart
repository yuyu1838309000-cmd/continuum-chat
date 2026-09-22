import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../utils/app_theme.dart';
import 'selection_toolbar.dart';

/// 思考链卡片（v0.2.95）：对话流里独立的气泡，无头像，与正文气泡交替排列：
/// 思考气泡 → 正文气泡 →（下次）思考气泡 → 正文气泡。
/// 展开内容（v0.2.98）：展开时显示全部思考内容，不做 180px 限高、不内部滚动，
/// 高度自适应跟随对话列表整体滚动。
/// 宽度（v0.2.97）：收起态为正文气泡 2/3（min(0.5 屏宽, 240)），
/// 展开态跟正文气泡同宽（0.75 屏宽）。几何切换直接落到真实尺寸，避免流式 rebuild 留下过期高度。
/// 收起/展开（v0.2.112，修正 v0.2.111 改过头）：
/// - 收起态：小气泡「脑图标 + 我在想 + 呼吸省略号」，思考中省略号呼吸动画，
///   不直接显示思考内容，点卡片才展开
/// - 展开态：思考中直接显示打字机已吐出部分（无「正在想……」占位，流式刚
///   开始还没吐出内容时内容区留空，随后直接跟随 Runtime 累积内容）；历史/非流式显示全文
/// 样式遵循 design-guide：圆角、留白、字少、图标只做点缀、正文用系统字体。
/// v0.2.117：思考内容支持选择/复制（复用普通气泡的 SelectionToolbar，体验一致），
/// 收起态头部左侧加"呼吸小绿灯"（思考中持续呼吸，结束变静态，低调不抢眼）。
class ThinkingCard extends StatefulWidget {
  /// 显示用思考内容（流式期间是 Runtime 已收到的累积内容）
  final String text;

  /// 思考进行中：省略号呼吸动画
  final bool active;

  /// 是否展开
  final bool expanded;

  /// 展开/收起切换（chat_page 维护展开集合）
  final VoidCallback? onToggle;

  /// 头部的稳定渲染锚点；聊天页用它在几何变化前后测量真实屏幕位置。
  final Key? headerAnchorKey;

  /// 复制整条思考内容（长按选择工具栏的"复制整条"）
  final VoidCallback? onCopyAll;

  const ThinkingCard({
    super.key,
    this.text = '',
    this.active = false,
    this.expanded = false,
    this.onToggle,
    this.headerAnchorKey,
    this.onCopyAll,
  });

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard>
    with SingleTickerProviderStateMixin {
  static const double _bodyHorizontalPadding = 12;
  static const double _bodyBottomPadding = 8;
  static const double _bottomBarHeight = 28;

  late final AnimationController _dotsAnim;

  TextStyle _bodyTextStyle(ThemeData theme) => TextStyle(
    fontSize: 12,
    height: 1.6,
    color: theme.colorScheme.onSurfaceVariant,
  );

  void _handleToggle() => widget.onToggle?.call();

  @override
  void initState() {
    super.initState();
    _dotsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.active) _dotsAnim.repeat();
  }

  @override
  void didUpdateWidget(covariant ThinkingCard old) {
    super.didUpdateWidget(old);
    if (widget.active && !_dotsAnim.isAnimating) {
      _dotsAnim.repeat();
    } else if (!widget.active && _dotsAnim.isAnimating) {
      _dotsAnim.stop();
      _dotsAnim.value = 1;
    }
  }

  @override
  void dispose() {
    _dotsAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 思考属于低权重状态，底色和描边都弱于正文气泡。
    final bg = context.processColor;
    final dotColor = theme.colorScheme.primary.withValues(alpha: 0.72);

    final header = Row(
      // 撑满整卡宽度：收起态整卡可点（v0.2.97 宽度固定为 2/3 后）
      mainAxisSize: MainAxisSize.max,
      children: [
        _ThinkingDot(anim: _dotsAnim, active: widget.active, color: dotColor),
        const SizedBox(width: 7),
        Icon(
          LucideIcons.brain,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(
          widget.active ? '在想' : '想过',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (widget.active) ...[
          const SizedBox(width: 4),
          _BreathingDots(
            anim: _dotsAnim,
            active: true,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
        const Spacer(),
        Icon(
          widget.expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
          size: 13,
          color: theme.colorScheme.outline,
        ),
      ],
    );

    // 宽度随 expanded 切换：收起 2/3（正文气泡 0.75 屏宽的 2/3，小屏按屏宽算、
    // 平板封顶 240），展开跟正文气泡同宽（0.75 屏宽，与 _buildMessageRow 正文
    // 气泡 maxWidth 一致）。
    final screenW = MediaQuery.of(context).size.width;
    final cardW = widget.expanded
        ? screenW * 0.76
        : math.min(screenW * 0.5, 240.0);

    // 这里故意不用 AnimatedSize/TweenAnimationBuilder 做几何动画。思考正文
    // 可能很长且仍在流式增长，几何动画被高频 rebuild 打断后，曾出现“已收起
    // 但旧高度还占着一大块空白”的残留布局。展开/收起直接切换真实 child，
    // 让列表每一帧拿到的都是确定高度；稳定性比这一点尺寸动画更重要。
    final card = Container(
      width: cardW,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：点卡片展开/收起
            KeyedSubtree(
              key: widget.headerAnchorKey,
              child: InkWell(
                onTap: _handleToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: header,
                ),
              ),
            ),
            if (widget.expanded) ...[
              _buildBody(theme),
              // 底部收起条与正文同属展开态，active -> settled 重建也不会
              // 被替换成另一个动画 child，因此不会在思考结束时凭空消失。
              _buildBottomBar(theme),
            ],
          ],
        ),
      ),
    );

    return card;
  }

  /// 思考内容区（仅展开态显示）：思考中直接显示打字机已吐出部分，不显示
  /// 「正在想……」占位（v0.2.112）；流式刚开始还没吐出内容时留空，随后由
  /// 打字机补上。不设限高不内部滚动，高度自适应跟随对话列表整体滚动。
  Widget _buildBody(ThemeData theme) {
    if (widget.text.isEmpty) {
      return const SizedBox.shrink();
    }
    final style = _bodyTextStyle(theme);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _bodyHorizontalPadding,
        0,
        _bodyHorizontalPadding,
        _bodyBottomPadding,
      ),
      // 流式期间保持纯 Text；settled 后用 Text + SelectionArea，保留完整
      // 选择/复制能力，但避开长正文 SelectableText/EditableText 的布局成本。
      child: widget.active
          ? Text(widget.text, style: style)
          : SelectionArea(
              contextMenuBuilder: (ctx, selectableRegionState) =>
                  SelectionAreaToolbar(
                    selectableRegionState: selectableRegionState,
                    onCopyAll: widget.onCopyAll,
                  ),
              child: Text(widget.text, style: style),
            ),
    );
  }

  /// 底部收起条：整条可点，点它收起（不用去点头部）。
  Widget _buildBottomBar(ThemeData theme, {bool interactive = true}) {
    final content = SizedBox(
      width: double.infinity,
      height: _bottomBarHeight,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 0.6,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.chevron_up,
              size: 13,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 3),
            Text(
              '收起',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
    return interactive
        ? InkWell(onTap: _handleToggle, child: content)
        : content;
  }
}

/// 呼吸小绿灯（v0.2.117）：思考气泡头部左缘的 7px 绿色圆点。
/// 思考中透明度/大小缓慢呼吸（周期同省略号动画 1.4s，低调不抢眼）；
/// 思考结束（气泡收起/正文开始）停止呼吸变静态。
class _ThinkingDot extends StatelessWidget {
  final AnimationController anim;
  final bool active;
  final Color color;

  const _ThinkingDot({
    required this.anim,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        var opacity = 0.55;
        var scale = 1.0;
        if (active) {
          final v = 0.5 + 0.5 * math.sin(anim.value * 2 * math.pi);
          opacity = 0.35 + 0.65 * v;
          scale = 0.8 + 0.2 * v;
        }
        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          ),
        );
      },
    );
  }
}

/// 呼吸省略号：三点相位错开淡入淡出；非思考期静止（opacity 固定）。
class _BreathingDots extends StatelessWidget {
  final AnimationController anim;
  final bool active;
  final Color color;

  const _BreathingDots({
    required this.anim,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            var opacity = 0.9;
            if (active) {
              final phase = (anim.value - i / 3) % 1.0;
              opacity =
                  0.25 + 0.75 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi));
            }
            return Opacity(
              opacity: opacity,
              child: Container(
                width: 3,
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            );
          }),
        );
      },
    );
  }
}
