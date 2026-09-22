import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 主题设置页（设置 → 主题）：
/// - 区1「外观模式」：浅色/深色/跟随系统三张卡片（图标 + 模式名 + 选中打勾），点击即时切换
/// - 区2「主题颜色」：5 套主题卡片（当前亮暗模式的真实层级预览）
/// - 区3「主题样式」：占位卡片（更多样式开发中）
/// - 区4「字体」：字体大小 slider（0.85-1.3）+ 字体粗细 ChoiceChip（常规/中等/加粗）
/// 全部改动走 AppThemeManager 全局通知即时生效。
/// 样式遵循 design-guide：圆角 20 卡片、surface 底、留白、主色只用点缀。
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题'),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      // 包一层 ListenableBuilder：切主题/字体后选中态和数值即时刷新
      body: ListenableBuilder(
        listenable: AppThemeManager.instance,
        builder: (context, _) {
          final mgr = AppThemeManager.instance;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // ── 外观模式 ──
              _SectionLabel('外观模式'),
              ...AppThemeMode.values.map((m) => _modeCard(context, mgr, m)),
              // ── 主题颜色 ──
              _SectionLabel('主题颜色'),
              ...AppThemeId.values.map((id) => _themeCard(context, mgr, id)),
              // ── 主题样式 ──
              _SectionLabel('主题样式'),
              _styleCard(context),
              // ── 字体 ──
              _SectionLabel('字体'),
              _fontScaleCard(context, mgr),
              _fontWeightCard(context, mgr),
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }

  /// 外观模式卡片：左侧图标，中间模式名，右侧选中打勾（样式同主题卡片）。
  Widget _modeCard(
    BuildContext context,
    AppThemeManager mgr,
    AppThemeMode mode,
  ) {
    final theme = Theme.of(context);
    final selected = mgr.mode == mode;
    final icon = switch (mode) {
      AppThemeMode.light => LucideIcons.sun,
      AppThemeMode.dark => LucideIcons.moon,
      AppThemeMode.system => LucideIcons.monitor,
    };
    return SettingCard(
      onTap: () => mgr.setMode(mode),
      child: Row(
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              mode.label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (selected)
            Icon(
              LucideIcons.circle_check,
              size: 22,
              color: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }

  /// 主题卡片：预览会跟随当前 light/dark，展示 base/card/双向气泡/点缀。
  Widget _themeCard(BuildContext context, AppThemeManager mgr, AppThemeId id) {
    final theme = Theme.of(context);
    final previewTheme = context.isDark ? themes[id]!.dark : themes[id]!.light;
    final selected = mgr.current == id;
    return SettingCard(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      onTap: () => mgr.setTheme(id),
      child: Row(
        children: [
          _ThemePreview(id: id, theme: previewTheme),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              id.label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (selected)
            Icon(
              LucideIcons.circle_check,
              size: 22,
              color: theme.colorScheme.primary,
            ),
        ],
      ),
    );
  }

  /// 主题样式占位卡片：右侧「默认」，点击提示开发中。
  Widget _styleCard(BuildContext context) {
    final theme = Theme.of(context);
    return SettingCard(
      onTap: () => _toast(context, '开发中'),
      child: Row(
        children: [
          const Expanded(child: Text('默认样式', style: TextStyle(fontSize: 15))),
          Text(
            '默认',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            LucideIcons.chevron_right,
            size: 20,
            color: theme.colorScheme.outline,
          ),
        ],
      ),
    );
  }

  /// 字体大小卡片：slider 0.85-1.3（9 档），右侧显示当前百分比。
  Widget _fontScaleCard(BuildContext context, AppThemeManager mgr) {
    final theme = Theme.of(context);
    final percent = (mgr.fontScale * 100).round();
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('字体大小', style: TextStyle(fontSize: 15)),
              const Spacer(),
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: mgr.fontScale,
            min: 0.85,
            max: 1.3,
            divisions: 9,
            label: '$percent%',
            onChanged: (v) => mgr.setFontScale(v),
          ),
        ],
      ),
    );
  }

  /// 字体粗细卡片：三个 ChoiceChip，小屏下自动换行。
  Widget _fontWeightCard(BuildContext context, AppThemeManager mgr) {
    const options = [
      ('常规', FontWeight.w400),
      ('中等', FontWeight.w500),
      ('加粗', FontWeight.w600),
    ];
    return SettingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('字体粗细', style: TextStyle(fontSize: 15)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, w) in options)
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 13)),
                  selected: mgr.fontWeight == w,
                  onSelected: (_) => mgr.setFontWeight(w),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 轻提示：开发中等占位提示。
  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(milliseconds: 1500),
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        ),
      );
  }
}

/// 分组标题：12px 灰色小字（同配置中心各页）。
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 紧凑真实预览：不画花哨 mockup，只传达层级、气泡 identity 与点缀色。
class _ThemePreview extends StatelessWidget {
  final AppThemeId id;
  final ThemeData theme;

  const _ThemePreview({required this.id, required this.theme});

  @override
  Widget build(BuildContext context) {
    final colors = theme.extension<AppSemanticColors>()!;
    final dark = theme.brightness == Brightness.dark;
    return Semantics(
      label: '${id.label}${dark ? '深色' : '浅色'}预览',
      child: Container(
        key: ValueKey('theme-preview-${id.key}'),
        width: 84,
        height: 52,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: colors.base,
          borderRadius: BorderRadius.circular(14),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(9),
            boxShadow: [colors.cardShadow],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PreviewBubble(color: colors.assistantBubble, width: 38),
                const SizedBox(height: 5),
                Align(
                  alignment: Alignment.centerRight,
                  child: _PreviewBubble(color: colors.userBubble, width: 31),
                ),
                const Spacer(),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  final Color color;
  final double width;

  const _PreviewBubble({required this.color, required this.width});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: SizedBox(width: width, height: 7),
    );
  }
}
