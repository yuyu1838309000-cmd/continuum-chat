import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Continuum Chat主题系统：5 套主题均提供独立的浅色/深色 palette。
/// 用户持久化 id 保持不变，页面只消费语义角色，不依赖某个主题的具体色值。

/// 全局圆角刻度 token：统一 8 / 14 / 20 / 胶囊（全 App 禁止散落其他圆角值）。
/// 气泡小尾巴 8 是设计特征，例外保留。
abstract final class AppRadius {
  /// 小圆角：细把手、标签、小元素
  static const double xs = 8;

  /// 中圆角：列表项、卡片、面板、输入框
  static const double sm = 14;

  /// 大圆角：底部面板、对话框
  static const double md = 20;

  /// 胶囊：按钮、气泡（圆角≈高度一半）
  static const double full = 999;
}

/// 间距刻度 token：统一 8 / 12 / 16 / 24 / 32。
abstract final class AppSpacing {
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

/// 字号刻度 token：标题 18 / 正文 15 / 辅助 12 / 时间戳 11。
abstract final class AppType {
  static const double title = 18;
  static const double body = 15;
  static const double caption = 12;
  static const double timestamp = 11;
}

/// 视觉层级的最小 ThemeExtension。
///
/// base 是页面底，layer/card/elevated 逐层承载内容，field 专用于输入和
/// 弱交互区。气泡与过程卡单独建模，避免用 alpha 覆盖猜测层级。
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.base,
    required this.layer,
    required this.card,
    required this.elevated,
    required this.field,
    required this.process,
    required this.assistantBubble,
    required this.onAssistantBubble,
    required this.userBubble,
    required this.onUserBubble,
    required this.text,
    required this.mutedText,
    required this.outline,
    required this.stroke,
    required this.cardShadow,
  });

  final Color base;
  final Color layer;
  final Color card;
  final Color elevated;
  final Color field;
  final Color process;
  final Color assistantBubble;
  final Color onAssistantBubble;
  final Color userBubble;
  final Color onUserBubble;
  final Color text;
  final Color mutedText;
  final Color outline;
  final Color stroke;
  final BoxShadow cardShadow;

  @override
  AppSemanticColors copyWith({
    Color? base,
    Color? layer,
    Color? card,
    Color? elevated,
    Color? field,
    Color? process,
    Color? assistantBubble,
    Color? onAssistantBubble,
    Color? userBubble,
    Color? onUserBubble,
    Color? text,
    Color? mutedText,
    Color? outline,
    Color? stroke,
    BoxShadow? cardShadow,
  }) {
    return AppSemanticColors(
      base: base ?? this.base,
      layer: layer ?? this.layer,
      card: card ?? this.card,
      elevated: elevated ?? this.elevated,
      field: field ?? this.field,
      process: process ?? this.process,
      assistantBubble: assistantBubble ?? this.assistantBubble,
      onAssistantBubble: onAssistantBubble ?? this.onAssistantBubble,
      userBubble: userBubble ?? this.userBubble,
      onUserBubble: onUserBubble ?? this.onUserBubble,
      text: text ?? this.text,
      mutedText: mutedText ?? this.mutedText,
      outline: outline ?? this.outline,
      stroke: stroke ?? this.stroke,
      cardShadow: cardShadow ?? this.cardShadow,
    );
  }

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other == null) return this;
    return AppSemanticColors(
      base: Color.lerp(base, other.base, t)!,
      layer: Color.lerp(layer, other.layer, t)!,
      card: Color.lerp(card, other.card, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      field: Color.lerp(field, other.field, t)!,
      process: Color.lerp(process, other.process, t)!,
      assistantBubble: Color.lerp(assistantBubble, other.assistantBubble, t)!,
      onAssistantBubble: Color.lerp(
        onAssistantBubble,
        other.onAssistantBubble,
        t,
      )!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      onUserBubble: Color.lerp(onUserBubble, other.onUserBubble, t)!,
      text: Color.lerp(text, other.text, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      stroke: Color.lerp(stroke, other.stroke, t)!,
      cardShadow: BoxShadow.lerp(cardShadow, other.cardShadow, t)!,
    );
  }
}

/// 全局语义色统一入口。
extension ThemeX on BuildContext {
  /// 当前是否深色模式（含跟随系统）。
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  AppSemanticColors get semanticColors {
    final theme = Theme.of(this);
    final configured = theme.extension<AppSemanticColors>();
    if (configured != null) return configured;

    // 保持独立 widget/test 在标准 MaterialApp 下可用；正式 App 均使用上方
    // 显式 palette，这里只按 Material 语义槽位做无透明覆盖的兼容映射。
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return AppSemanticColors(
      base: scheme.surface,
      layer: scheme.surfaceContainerLow,
      card: scheme.surfaceContainer,
      elevated: scheme.surfaceContainerHigh,
      field: scheme.surfaceContainerHighest,
      process: scheme.tertiaryContainer,
      assistantBubble: scheme.primaryContainer,
      onAssistantBubble: scheme.onPrimaryContainer,
      userBubble: scheme.secondaryContainer,
      onUserBubble: scheme.onSecondaryContainer,
      text: scheme.onSurface,
      mutedText: scheme.onSurfaceVariant,
      outline: scheme.outline,
      stroke: scheme.outlineVariant,
      cardShadow: BoxShadow(
        color: dark ? const Color(0x30000000) : const Color(0x10000000),
        blurRadius: dark ? 9 : 12,
        offset: const Offset(0, 2),
      ),
    );
  }

  /// 页面背景。
  Color get bgColor => semanticColors.base;

  /// 主文字：浅色=深字；深色=浅字（#E8EEF8 系）。
  Color get textColor => Theme.of(this).colorScheme.onSurface;

  /// 次要文字/图标。
  Color get subTextColor => Theme.of(this).colorScheme.onSurfaceVariant;

  Color get layerColor => semanticColors.layer;
  Color get cardColor => semanticColors.card;
  Color get elevatedColor => semanticColors.elevated;
  BoxShadow get cardShadow => semanticColors.cardShadow;
  Color get cardStrokeColor => semanticColors.stroke;
  Color get fieldColor => semanticColors.field;
  Color get processColor => semanticColors.process;
  Color get assistantBubbleColor => semanticColors.assistantBubble;
  Color get onAssistantBubbleColor => semanticColors.onAssistantBubble;
  Color get userBubbleColor => semanticColors.userBubble;
  Color get onUserBubbleColor => semanticColors.onUserBubble;

  /// 状态栏图标颜色：深色模式用浅色图标，浅色模式用深色图标。
  SystemUiOverlayStyle get overlayStyle =>
      isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

  /// 点缀色：当前主题的低饱和主锚点。
  /// 全页只做一处重点强调（高智感规范），按钮/选中态/焦点统一走它。
  Color get accentColor => Theme.of(this).colorScheme.primary;

  /// 状态色·成功：服务正常 / 在线 / 新鲜。
  Color get successColor =>
      isDark ? const Color(0xFF30D158) : const Color(0xFF34C759);

  /// 状态色·危险：离线 / 失败 / 报错。
  Color get dangerColor =>
      isDark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);

  /// 遮罩色：图片查看器黑底、头像上传遮罩、抽屉遮罩（功能色，亮暗通用）。
  Color get scrimColor => Colors.black;
}

/// 代码块固定深色画板（亮暗统一深底，参考终端/编辑器风格）。
/// 代码区是独立"深色小屏"，不随主题变浅，避免浅色下代码不可读。
abstract final class AppCodePalette {
  static const Color bg = Color(0xFF1E232B);
  static const Color text = Color(0xFFE6E6E6);
  static const Color keyword = Color(0xFFC792EA);
  static const Color string = Color(0xFF9ECE6A);
  static const Color comment = Color(0xFF7A869E);
  static const Color number = Color(0xFFFF9E64);
  static const Color function = Color(0xFF82AAFF);

  /// 工具条/提示条用色：白底 + alpha 叠在深色 bg 上。
  static const Color overlay = Colors.white;
}

enum AppThemeId {
  midnightGold('midnight_gold', '雾蓝', '石板蓝与薄雾灰蓝'),
  creamWarm('cream_warm', '暖雾', '暖象牙与粉蓝'),
  mint('mint', '薄荷雾', '灰绿与薄荷白'),
  lavender('lavender', '薰衣草雾', '灰紫与淡薰衣草'),
  mono('mono', '墨雾', '柔和黑白灰');

  const AppThemeId(this.key, this.label, this.desc);
  final String key;
  final String label;
  final String desc;
}

/// 深色/浅色模式：手动指定或跟随系统，存 shared_preferences。
enum AppThemeMode {
  light('light', '浅色'),
  dark('dark', '深色'),
  system('system', '跟随系统');

  const AppThemeMode(this.key, this.label);
  final String key;
  final String label;

  /// 转成 MaterialApp 的 themeMode，跟随系统用 ThemeMode.system。
  ThemeMode get themeMode => switch (this) {
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
    AppThemeMode.system => ThemeMode.system,
  };
}

/// 一套主题：浅色 + 深色 ThemeData
class AppTheme {
  final AppThemeId id;
  final ThemeData light;
  final ThemeData dark;

  const AppTheme({required this.id, required this.light, required this.dark});
}

/// 全局主题管理：当前主题 + shared_preferences 持久化 + ChangeNotifier 即时刷新。
/// 单例，任何页面直接 AppThemeManager.instance 访问。
class AppThemeManager extends ChangeNotifier {
  AppThemeManager._();
  static final AppThemeManager instance = AppThemeManager._();

  static const String _prefsKey = 'app_theme_id';
  static const String _modePrefsKey = 'app_theme_mode';
  static const String _fontScalePrefsKey = 'app_font_scale';
  static const String _fontWeightPrefsKey = 'app_font_weight';

  AppThemeId _current = AppThemeId.midnightGold;
  AppThemeMode _mode = AppThemeMode.system;
  double _fontScale = 1.0;
  FontWeight _fontWeight = FontWeight.w400;
  AppThemeId get current => _current;
  AppThemeMode get mode => _mode;
  double get fontScale => _fontScale;
  FontWeight get fontWeight => _fontWeight;
  AppTheme? _cachedTheme;

  /// 当前主题。缓存仅按主题 id 失效；全局字体一律走系统无衬线，不烘像素字体。
  AppTheme get currentTheme {
    if (_cachedTheme == null || _cachedTheme!.id != _current) {
      _cachedTheme = themes[_current]!;
    }
    return _cachedTheme!;
  }

  /// 启动时读一次。读不到/出错用默认（雾蓝）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString(_prefsKey);
      for (final t in AppThemeId.values) {
        if (t.key == key) {
          _current = t;
          break;
        }
      }
      // 深色模式入口：读上次选择，默认跟随系统
      final modeKey = prefs.getString(_modePrefsKey);
      for (final m in AppThemeMode.values) {
        if (m.key == modeKey) {
          _mode = m;
          break;
        }
      }
      // 字体大小（0.85-1.3，默认 1.0）
      final fs = prefs.getDouble(_fontScalePrefsKey);
      if (fs != null && fs >= 0.85 && fs <= 1.3) {
        _fontScale = fs;
      }
      // 字体粗细（400 常规 / 500 中等 / 600 加粗，默认常规）
      final fw = prefs.getInt(_fontWeightPrefsKey);
      _fontWeight = switch (fw) {
        500 => FontWeight.w500,
        600 => FontWeight.w600,
        _ => FontWeight.w400,
      };
    } catch (_) {
      // 读失败保持默认
    }
    notifyListeners();
  }

  /// 切主题：本地立刻生效，异步落盘。
  Future<void> setTheme(AppThemeId id) async {
    if (_current == id) return;
    _current = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, id.key);
    } catch (_) {
      // 落盘失败不影响本次切换
    }
  }

  /// 切深色/浅色/跟随系统：本地立刻生效，异步落盘。
  Future<void> setMode(AppThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modePrefsKey, mode.key);
    } catch (_) {
      // 落盘失败不影响本次切换
    }
  }

  /// 字体大小缩放（0.85-1.3），立即生效并落盘。
  Future<void> setFontScale(double v) async {
    final nv = v.clamp(0.85, 1.3);
    if ((_fontScale - nv).abs() < 0.001) return;
    _fontScale = nv;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontScalePrefsKey, nv);
    } catch (_) {}
  }

  /// 字体粗细（400/500/600），立即生效并落盘。
  Future<void> setFontWeight(FontWeight w) async {
    if (_fontWeight == w) return;
    _fontWeight = w;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _fontWeightPrefsKey,
        w.value >= 600 ? 600 : (w.value >= 500 ? 500 : 400),
      );
    } catch (_) {}
  }
}

ColorScheme _scheme({
  required Brightness brightness,
  required Color primary,
  required Color onPrimary,
  required AppSemanticColors colors,
}) {
  final dark = brightness == Brightness.dark;
  return ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    primaryContainer: colors.assistantBubble,
    onPrimaryContainer: colors.onAssistantBubble,
    secondary: primary,
    onSecondary: onPrimary,
    secondaryContainer: colors.userBubble,
    onSecondaryContainer: colors.onUserBubble,
    tertiary: colors.mutedText,
    onTertiary: colors.base,
    tertiaryContainer: colors.process,
    onTertiaryContainer: colors.mutedText,
    error: dark ? const Color(0xFFE7A7A4) : const Color(0xFF9F4542),
    onError: dark ? const Color(0xFF351010) : const Color(0xFFFFFFFF),
    errorContainer: dark ? const Color(0xFF4A2525) : const Color(0xFFF4DEDC),
    onErrorContainer: dark ? const Color(0xFFF4D4D2) : const Color(0xFF692522),
    surface: colors.base,
    onSurface: colors.text,
    surfaceDim: dark ? colors.base : colors.layer,
    surfaceBright: dark ? colors.elevated : colors.card,
    surfaceContainerLowest: colors.base,
    surfaceContainerLow: colors.layer,
    surfaceContainer: colors.card,
    surfaceContainerHigh: colors.elevated,
    surfaceContainerHighest: colors.field,
    onSurfaceVariant: colors.mutedText,
    outline: colors.outline,
    outlineVariant: colors.stroke,
    shadow: colors.cardShadow.color,
    scrim: const Color(0xFF000000),
    inverseSurface: colors.text,
    onInverseSurface: colors.base,
    inversePrimary: primary,
    surfaceTint: const Color(0x00000000),
  );
}

/// 常见 Material 组件在 ThemeData 内共享同一套层级与交互状态。
ThemeData _buildTheme({
  required Brightness brightness,
  required Color primary,
  required Color onPrimary,
  required AppSemanticColors colors,
}) {
  final scheme = _scheme(
    brightness: brightness,
    primary: primary,
    onPrimary: onPrimary,
    colors: colors,
  );
  const transitions = PageTransitionsTheme(
    builders: {
      // Android 保持 Material 原生轻量过渡，不再强制套 iOS Cupertino 重页滑动。
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    },
  );
  final disabledForeground = colors.mutedText.withValues(alpha: 0.46);
  final disabledBackground = colors.field;
  final controlOverlay = primary.withValues(
    alpha: brightness == Brightness.dark ? 0.14 : 0.09,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [colors],
    scaffoldBackgroundColor: colors.base,
    canvasColor: colors.base,
    dividerColor: colors.stroke,
    disabledColor: disabledForeground,
    focusColor: controlOverlay,
    hoverColor: controlOverlay,
    splashColor: controlOverlay,
    highlightColor: controlOverlay,
    pageTransitionsTheme: transitions,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.base,
      foregroundColor: colors.text,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledBackground
              : primary,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledForeground
              : onPrimary,
        ),
        overlayColor: WidgetStatePropertyAll(controlOverlay),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        elevation: const WidgetStatePropertyAll(0),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledForeground
              : primary,
        ),
        overlayColor: WidgetStatePropertyAll(controlOverlay),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledForeground
              : colors.text,
        ),
        overlayColor: WidgetStatePropertyAll(controlOverlay),
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? colors.stroke
                : colors.outline,
          ),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledForeground
              : colors.mutedText,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.field
              : Colors.transparent,
        ),
        overlayColor: WidgetStatePropertyAll(controlOverlay),
        shape: const WidgetStatePropertyAll(CircleBorder()),
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.card,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.cardShadow.color,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.elevated,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.cardShadow.color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.elevated,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: colors.elevated,
      shadowColor: colors.cardShadow.color,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.md)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.stroke,
      thickness: 0.6,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.field,
      hintStyle: TextStyle(color: colors.mutedText),
      labelStyle: TextStyle(color: colors.mutedText),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: colors.stroke, width: 0.7),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: primary, width: 1),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: scheme.error, width: 0.8),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        borderSide: BorderSide(color: scheme.error, width: 1),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabledForeground;
        return states.contains(WidgetState.selected) ? onPrimary : colors.card;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return colors.layer;
        return states.contains(WidgetState.selected) ? primary : colors.field;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : colors.stroke,
      ),
      overlayColor: WidgetStatePropertyAll(controlOverlay),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.layer,
      disabledColor: disabledBackground,
      selectedColor: colors.assistantBubble,
      secondarySelectedColor: colors.assistantBubble,
      labelStyle: TextStyle(color: colors.text),
      secondaryLabelStyle: TextStyle(color: colors.onAssistantBubble),
      checkmarkColor: primary,
      side: BorderSide(color: colors.stroke, width: 0.7),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      showCheckmark: false,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
    ),
  );
}

/// 5 套主题的 light/dark 均独立定义；dark 表面全为不透明低明度色。
final Map<AppThemeId, AppTheme> themes = {
  AppThemeId.midnightGold: AppTheme(
    id: AppThemeId.midnightGold,
    light: _buildTheme(
      brightness: Brightness.light,
      primary: const Color(0xFF596B80),
      onPrimary: const Color(0xFFF9FBFC),
      colors: const AppSemanticColors(
        base: Color(0xFFF4F6F7),
        layer: Color(0xFFEDF1F3),
        card: Color(0xFFFAFBFB),
        elevated: Color(0xFFF0F3F5),
        field: Color(0xFFE8EDF1),
        process: Color(0xFFEAE7EF),
        assistantBubble: Color(0xFFC8D2DD),
        onAssistantBubble: Color(0xFF263440),
        userBubble: Color(0xFFDBD3E5),
        onUserBubble: Color(0xFF342F3A),
        text: Color(0xFF26323D),
        mutedText: Color(0xFF667380),
        outline: Color(0xFF8995A0),
        stroke: Color(0xFFD5DDE2),
        cardShadow: BoxShadow(
          color: Color(0x120F1D2A),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ),
    ),
    dark: _buildTheme(
      brightness: Brightness.dark,
      primary: const Color(0xFF9CAFC2),
      onPrimary: const Color(0xFF17212B),
      colors: const AppSemanticColors(
        base: Color(0xFF151B22),
        layer: Color(0xFF1A222B),
        card: Color(0xFF202A34),
        elevated: Color(0xFF26313C),
        field: Color(0xFF1D2731),
        process: Color(0xFF282D38),
        assistantBubble: Color(0xFF2B3947),
        onAssistantBubble: Color(0xFFE1E7EC),
        userBubble: Color(0xFF343442),
        onUserBubble: Color(0xFFE9E4ED),
        text: Color(0xFFE3E9ED),
        mutedText: Color(0xFFA7B2BC),
        outline: Color(0xFF74818D),
        stroke: Color(0xFF34414D),
        cardShadow: BoxShadow(
          color: Color(0x38000000),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ),
    ),
  ),
  AppThemeId.creamWarm: AppTheme(
    id: AppThemeId.creamWarm,
    light: _buildTheme(
      brightness: Brightness.light,
      primary: const Color(0xFF596B80),
      onPrimary: const Color(0xFFFAFBFC),
      colors: const AppSemanticColors(
        base: Color(0xFFF7F4ED),
        layer: Color(0xFFEFEAE1),
        card: Color(0xFFFCFAF5),
        elevated: Color(0xFFF1EDE5),
        field: Color(0xFFE9E5DB),
        process: Color(0xFFE7E5E2),
        assistantBubble: Color(0xFFE9E5DB),
        onAssistantBubble: Color(0xFF39362F),
        userBubble: Color(0xFFD8E3EE),
        onUserBubble: Color(0xFF2B3947),
        text: Color(0xFF34332F),
        mutedText: Color(0xFF756F65),
        outline: Color(0xFF958E83),
        stroke: Color(0xFFDDD7CD),
        cardShadow: BoxShadow(
          color: Color(0x120E1822),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ),
    ),
    dark: _buildTheme(
      brightness: Brightness.dark,
      primary: const Color(0xFFA8B6C5),
      onPrimary: const Color(0xFF1B242D),
      colors: const AppSemanticColors(
        base: Color(0xFF1B1A18),
        layer: Color(0xFF22211E),
        card: Color(0xFF292722),
        elevated: Color(0xFF302E29),
        field: Color(0xFF25231F),
        process: Color(0xFF2B2927),
        assistantBubble: Color(0xFF36322C),
        onAssistantBubble: Color(0xFFE9E4DA),
        userBubble: Color(0xFF2D3742),
        onUserBubble: Color(0xFFE1E8EE),
        text: Color(0xFFE8E4DC),
        mutedText: Color(0xFFB0AAA0),
        outline: Color(0xFF817A70),
        stroke: Color(0xFF403D37),
        cardShadow: BoxShadow(
          color: Color(0x36000000),
          blurRadius: 9,
          offset: Offset(0, 2),
        ),
      ),
    ),
  ),
  AppThemeId.mint: AppTheme(
    id: AppThemeId.mint,
    light: _buildTheme(
      brightness: Brightness.light,
      primary: const Color(0xFF66796C),
      onPrimary: const Color(0xFFFAFCFA),
      colors: const AppSemanticColors(
        base: Color(0xFFF4F7F4),
        layer: Color(0xFFECF2EE),
        card: Color(0xFFFAFCFA),
        elevated: Color(0xFFF0F4F1),
        field: Color(0xFFE8F0EB),
        process: Color(0xFFE4EBE6),
        assistantBubble: Color(0xFFD7E2DA),
        onAssistantBubble: Color(0xFF2E3B32),
        userBubble: Color(0xFFDDE5E9),
        onUserBubble: Color(0xFF303A40),
        text: Color(0xFF2C3530),
        mutedText: Color(0xFF68736B),
        outline: Color(0xFF89938B),
        stroke: Color(0xFFD5DED8),
        cardShadow: BoxShadow(
          color: Color(0x120E1B14),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ),
    ),
    dark: _buildTheme(
      brightness: Brightness.dark,
      primary: const Color(0xFFA5B8AA),
      onPrimary: const Color(0xFF18231C),
      colors: const AppSemanticColors(
        base: Color(0xFF171D19),
        layer: Color(0xFF1D2520),
        card: Color(0xFF232D27),
        elevated: Color(0xFF29342E),
        field: Color(0xFF202923),
        process: Color(0xFF262F2A),
        assistantBubble: Color(0xFF2F3A34),
        onAssistantBubble: Color(0xFFE1E9E3),
        userBubble: Color(0xFF2A3640),
        onUserBubble: Color(0xFFE0E7EC),
        text: Color(0xFFE2E9E4),
        mutedText: Color(0xFFA7B2AA),
        outline: Color(0xFF748078),
        stroke: Color(0xFF35413A),
        cardShadow: BoxShadow(
          color: Color(0x34000000),
          blurRadius: 9,
          offset: Offset(0, 2),
        ),
      ),
    ),
  ),
  AppThemeId.lavender: AppTheme(
    id: AppThemeId.lavender,
    light: _buildTheme(
      brightness: Brightness.light,
      primary: const Color(0xFF71697C),
      onPrimary: const Color(0xFFFBFAFC),
      colors: const AppSemanticColors(
        base: Color(0xFFF7F5F8),
        layer: Color(0xFFF0EDF3),
        card: Color(0xFFFCFBFC),
        elevated: Color(0xFFF2EFF4),
        field: Color(0xFFECE8EF),
        process: Color(0xFFE8E3EB),
        assistantBubble: Color(0xFFDBD3E5),
        onAssistantBubble: Color(0xFF38323F),
        userBubble: Color(0xFFD8E1EA),
        onUserBubble: Color(0xFF303A43),
        text: Color(0xFF353139),
        mutedText: Color(0xFF716A77),
        outline: Color(0xFF928A99),
        stroke: Color(0xFFDED8E2),
        cardShadow: BoxShadow(
          color: Color(0x120F1018),
          blurRadius: 14,
          offset: Offset(0, 3),
        ),
      ),
    ),
    dark: _buildTheme(
      brightness: Brightness.dark,
      primary: const Color(0xFFB4A9BF),
      onPrimary: const Color(0xFF251F2B),
      colors: const AppSemanticColors(
        base: Color(0xFF1B191E),
        layer: Color(0xFF221F26),
        card: Color(0xFF29252E),
        elevated: Color(0xFF302B36),
        field: Color(0xFF26222B),
        process: Color(0xFF2D2832),
        assistantBubble: Color(0xFF393140),
        onAssistantBubble: Color(0xFFEAE3ED),
        userBubble: Color(0xFF303943),
        onUserBubble: Color(0xFFE3E8ED),
        text: Color(0xFFE9E4EB),
        mutedText: Color(0xFFB2AAB6),
        outline: Color(0xFF817885),
        stroke: Color(0xFF403946),
        cardShadow: BoxShadow(
          color: Color(0x36000000),
          blurRadius: 9,
          offset: Offset(0, 2),
        ),
      ),
    ),
  ),
  AppThemeId.mono: AppTheme(
    id: AppThemeId.mono,
    light: _buildTheme(
      brightness: Brightness.light,
      primary: const Color(0xFF4D5257),
      onPrimary: const Color(0xFFFBFBFB),
      colors: const AppSemanticColors(
        base: Color(0xFFF5F5F4),
        layer: Color(0xFFEDEDEC),
        card: Color(0xFFFBFBFA),
        elevated: Color(0xFFF0F0EF),
        field: Color(0xFFE7E7E5),
        process: Color(0xFFEAEAE8),
        assistantBubble: Color(0xFFDCDDDC),
        onAssistantBubble: Color(0xFF2D3032),
        userBubble: Color(0xFFE7E7E5),
        onUserBubble: Color(0xFF303234),
        text: Color(0xFF2C2E30),
        mutedText: Color(0xFF6D7174),
        outline: Color(0xFF8E9295),
        stroke: Color(0xFFD7D8D7),
        cardShadow: BoxShadow(
          color: Color(0x12000000),
          blurRadius: 13,
          offset: Offset(0, 3),
        ),
      ),
    ),
    dark: _buildTheme(
      brightness: Brightness.dark,
      primary: const Color(0xFFBDC0C2),
      onPrimary: const Color(0xFF202224),
      colors: const AppSemanticColors(
        base: Color(0xFF18191A),
        layer: Color(0xFF1F2021),
        card: Color(0xFF252729),
        elevated: Color(0xFF2C2E30),
        field: Color(0xFF222426),
        process: Color(0xFF292A2C),
        assistantBubble: Color(0xFF303234),
        onAssistantBubble: Color(0xFFE5E6E6),
        userBubble: Color(0xFF3A3C3E),
        onUserBubble: Color(0xFFECEDED),
        text: Color(0xFFE5E6E7),
        mutedText: Color(0xFFA9ACAE),
        outline: Color(0xFF777B7E),
        stroke: Color(0xFF3A3D3F),
        cardShadow: BoxShadow(
          color: Color(0x34000000),
          blurRadius: 9,
          offset: Offset(0, 2),
        ),
      ),
    ),
  ),
};
