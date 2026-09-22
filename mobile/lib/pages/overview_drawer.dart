import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../utils/nickname.dart';
import '../utils/app_theme.dart';
import '../services/profile_api.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

const double _kDrawerGutter = AppSpacing.md;
const double _kDrawerTopPadding = AppSpacing.md;
const double _kDrawerBottomPadding = AppSpacing.md;
const double _kProfileToMenuGap = AppSpacing.lg;
const double _kGroupGap = AppSpacing.md;
const double _kBottomActionsGap = AppSpacing.md;
const double _kBottomButtonPadding = AppSpacing.sm;
const double _kEntryHorizontalPadding = AppSpacing.md;
const double _kEntryIconSize = 22;
const double _kEntryIconGap = AppSpacing.sm;
const int _kSettingsActionFlex = 1;
const int _kNewChatActionFlex = 1;

/// 右滑总览抽屉内容：
/// 顶部身份卡 + 五个主导航入口 + 底部主次操作。
/// 纯内容组件，不带 Drawer 外壳；关闭抽屉走 onClose 回调。
/// 底色跟主题走（surface，chat_page 容器提供），容器宽度 80%/≤360px 由 chat_page 控制。
class OverviewDrawer extends StatelessWidget {
  final VoidCallback? onStartNewChat;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenMemory;
  final VoidCallback? onOpenAssistant;
  final VoidCallback? onOpenTogether;
  final VoidCallback? onOpenAbility;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onClose;

  const OverviewDrawer({
    super.key,
    this.onStartNewChat,
    this.onOpenHistory,
    this.onOpenMemory,
    this.onOpenAssistant,
    this.onOpenTogether,
    this.onOpenAbility,
    this.onOpenSettings,
    this.onClose,
  });

  void _runAction(VoidCallback action) {
    onClose?.call();
    action();
  }

  /// 点铅笔改昵称：弹输入框，保存后全局生效（AppBar 标题同步）。
  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: NicknameManager.instance.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改个名字'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 12,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: '输入昵称'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await NicknameManager.instance.setName(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _kDrawerGutter,
          _kDrawerTopPadding,
          _kDrawerGutter,
          _kDrawerBottomPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ProfileEntryCard(onRename: () => _rename(context)),
            const SizedBox(height: _kProfileToMenuGap),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: _kGroupGap),
                child: Column(
                  children: [
                    _DrawerGroup(
                      items: [
                        _DrawerEntryData(
                          icon: LucideIcons.archive,
                          title: '历史',
                          onTap: onOpenHistory == null
                              ? null
                              : () => _runAction(() => onOpenHistory!()),
                        ),
                        _DrawerEntryData(
                          icon: LucideIcons.brain,
                          title: '记忆',
                          onTap: onOpenMemory == null
                              ? null
                              : () => _runAction(() => onOpenMemory!()),
                        ),
                        _DrawerEntryData(
                          icon: LucideIcons.heart,
                          title: 'AI 助手',
                          onTap: onOpenAssistant == null
                              ? null
                              : () => _runAction(() => onOpenAssistant!()),
                        ),
                        _DrawerEntryData(
                          icon: LucideIcons.users,
                          title: '一起',
                          onTap: onOpenTogether == null
                              ? null
                              : () => _runAction(() => onOpenTogether!()),
                        ),
                        _DrawerEntryData(
                          icon: LucideIcons.sparkles,
                          title: '能力',
                          onTap: onOpenAbility == null
                              ? null
                              : () => _runAction(() => onOpenAbility!()),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: _kGroupGap),
            _BottomActions(
              onOpenSettings: onOpenSettings == null
                  ? null
                  : () => _runAction(() => onOpenSettings!()),
              onStartNewChat: onStartNewChat == null
                  ? null
                  : () => _runAction(() => onStartNewChat!()),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileEntryCard extends StatelessWidget {
  final VoidCallback onRename;

  const _ProfileEntryCard({required this.onRename});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              const _ProfileAvatar(),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: ListenableBuilder(
                  listenable: NicknameManager.instance,
                  builder: (context, _) => Text(
                    NicknameManager.instance.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              _RenameButton(onTap: onRename),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ProfileManager.instance,
      builder: (context, _) {
        final url = ProfileManager.instance.youAvatar;
        return Container(
          width: 50,
          height: 50,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: ClipOval(
            child: url.isEmpty
                ? Image.asset(
                    'assets/icon-continuum.png',
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                  )
                : CachedNetworkImage(
                    imageUrl: url,
                    width: 50,
                    height: 50,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    placeholder: (_, _) => const SizedBox.shrink(),
                    errorWidget: (_, _, _) => Image.asset(
                      'assets/icon-continuum.png',
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _RenameButton extends StatelessWidget {
  final VoidCallback onTap;

  const _RenameButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TapFeedback(
      onTap: onTap,
      minHeight: 44,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      surfaceFeedback: true,
      semanticLabel: '改昵称',
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.fieldColor,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(
                LucideIcons.pencil,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DrawerEntryData {
  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  const _DrawerEntryData({
    required this.icon,
    required this.title,
    required this.onTap,
  });
}

class _DrawerGroup extends StatelessWidget {
  final List<_DrawerEntryData> items;

  const _DrawerGroup({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final item in items) _DrawerEntry(item: item)],
        ),
      ),
    );
  }
}

class _DrawerEntry extends StatelessWidget {
  final _DrawerEntryData item;

  const _DrawerEntry({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TapFeedback(
      onTap: item.onTap,
      minHeight: 56,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      surfaceFeedback: true,
      semanticLabel: item.title,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _kEntryHorizontalPadding,
        ),
        child: Row(
          children: [
            Icon(
              item.icon,
              size: _kEntryIconSize,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: _kEntryIconGap),
            Expanded(
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.body,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              LucideIcons.chevron_right,
              size: 20,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  final VoidCallback? onOpenSettings;
  final VoidCallback? onStartNewChat;

  const _BottomActions({this.onOpenSettings, this.onStartNewChat});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: _kSettingsActionFlex,
          child: _BottomButton(
            icon: LucideIcons.settings,
            label: '设置',
            onTap: onOpenSettings,
          ),
        ),
        const SizedBox(width: _kBottomActionsGap),
        Expanded(
          flex: _kNewChatActionFlex,
          child: _BottomButton(
            icon: LucideIcons.message_square_plus,
            label: '新对话',
            primary: true,
            onTap: onStartNewChat,
          ),
        ),
      ],
    );
  }
}

class _BottomButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback? onTap;

  const _BottomButton({
    required this.icon,
    required this.label,
    this.primary = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = primary
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurfaceVariant;
    final decoration = BoxDecoration(
      color: primary ? context.accentColor : context.fieldColor,
      borderRadius: BorderRadius.circular(AppRadius.full),
      border: primary ? null : Border.all(color: context.cardStrokeColor),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: _TapFeedback(
        onTap: onTap,
        minHeight: 48,
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Container(
          height: 48,
          decoration: decoration,
          padding: const EdgeInsets.symmetric(
            horizontal: _kBottomButtonPadding,
          ),
          child: Center(child: Icon(icon, size: 20, color: foreground)),
        ),
      ),
    );
  }
}

/// 点按反馈：只保留短透明度/表面反馈，避免叠加动效。
class _TapFeedback extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final double minHeight;
  final bool surfaceFeedback;
  final String? semanticLabel;

  const _TapFeedback({
    required this.child,
    this.onTap,
    this.borderRadius = BorderRadius.zero,
    this.minHeight = 44,
    this.surfaceFeedback = false,
    this.semanticLabel,
  });

  @override
  State<_TapFeedback> createState() => _TapFeedbackState();
}

class _TapFeedbackState extends State<_TapFeedback> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final overlayColor = _pressed ? context.fieldColor : Colors.transparent;
    final detector = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null
          ? null
          : (_) => setState(() => _pressed = true),
      onTapUp: widget.onTap == null
          ? null
          : (_) => setState(() => _pressed = false),
      onTapCancel: widget.onTap == null
          ? null
          : () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedOpacity(
        opacity: widget.onTap == null ? 0.45 : (_pressed ? 0.90 : 1),
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        child: Container(
          constraints: BoxConstraints(minHeight: widget.minHeight),
          alignment: Alignment.center,
          decoration: widget.surfaceFeedback
              ? BoxDecoration(
                  color: overlayColor,
                  borderRadius: widget.borderRadius,
                )
              : null,
          child: widget.child,
        ),
      ),
    );
    if (widget.semanticLabel == null) return detector;
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.semanticLabel,
      child: detector,
    );
  }
}
