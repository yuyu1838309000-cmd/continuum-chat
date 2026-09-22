import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../utils/app_theme.dart';

/// 设置/配置页统一卡片容器。
class SettingCard extends StatelessWidget {
  /// 卡片内容（TextField / SwitchListTile / Slider / ChoiceChip 等）
  final Widget child;

  /// 外边距，默认左右 16、底部 12（卡片之间留白）
  final EdgeInsetsGeometry margin;

  /// 内边距，默认 16；SwitchListTile 自带内边距时可传 EdgeInsets.zero
  final EdgeInsetsGeometry padding;

  /// 点击回调（可选）：整卡可点的卡片（如主题卡片）传入，水波纹铺满圆角卡片
  final VoidCallback? onTap;

  const SettingCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(
      AppSpacing.md,
      0,
      AppSpacing.md,
      AppSpacing.sm,
    ),
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}

/// Hub、设置与配置入口共用的单行导航卡片。
class AppNavigationCard extends StatelessWidget {
  const AppNavigationCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
    this.showChevron = true,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showChevron;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingCard(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 22, color: iconColor ?? scheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing case final trailing?) ...[
            const SizedBox(width: AppSpacing.xs),
            trailing,
          ] else if (showChevron) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(LucideIcons.chevron_right, size: 20, color: scheme.outline),
          ],
        ],
      ),
    );
  }
}

/// 设置与配置页共用的弱层级分组标题。
class AppSectionLabel extends StatelessWidget {
  const AppSectionLabel(this.text, {super.key, this.compact = false});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        compact ? AppSpacing.xs : AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.caption,
          fontWeight: FontWeight.w500,
          color: context.semanticColors.mutedText,
        ),
      ),
    );
  }
}
