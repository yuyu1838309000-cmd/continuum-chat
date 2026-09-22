import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/swipe_back.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/app_update.dart';
import '../services/chat_api.dart';
import '../services/permission_center.dart';
import '../utils/app_theme.dart';
import '../utils/reasoning_pref.dart';
import '../utils/timestamp_pref.dart';
import '../widgets/setting_card.dart';
import 'config_center_page.dart';
import 'permission_center_page.dart';
import 'quick_messages_page.dart';
import 'theme_settings_page.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/server_config.dart';

/// 设置页：普通体验项按聊天、外观、权限与通知分组，技术项统一从高级设置进入。
/// "允许AI 助手主动找我"开关存 shared_preferences（默认开），关掉后 App 不再轮询心跳队列。
/// 主题设置页（主题颜色/样式/字体）也在这里。
/// 入口与分组复用设置页共用组件，开关状态样式交给 ThemeData。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  static const String allowProactiveKey = 'allow_proactive';
  bool _allowProactive = true;
  bool _showTimestamps = true;
  String _appVersion = '';

  /// 应用内更新：等待"安装未知应用"授权后自动续传下载的 APK 地址（null = 无待续）。
  String? _pendingApkUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _loadVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从"安装未知应用"设置页返回 → 授权通过就自动开始下载（不用再点一次）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _pendingApkUrl != null) {
      final url = _pendingApkUrl!;
      _pendingApkUrl = null;
      _downloadAndInstall(url);
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getBool(allowProactiveKey);
    final localTimestamps = prefs.getBool(TimestampPref.key);
    if (!mounted) return;
    // 先立刻用本地缓存渲染，避免网络请求期间先显示初始值 true 再跳变（开关闪烁）
    setState(() {
      _allowProactive = local ?? true;
      _showTimestamps = localTimestamps ?? true;
    });
    // 服务器为准（审计报告 🟡#3）：拉到就覆盖本地并展示；
    // 只有服务器不可达时才保持本地值，并上报上次离线改的状态。
    final server = await ChatApi.fetchAllowProactive();
    if (!mounted) return;
    if (server != null) {
      await prefs.setBool(allowProactiveKey, server);
      setState(() => _allowProactive = server);
      return;
    }
    unawaited(_syncToServer(_allowProactive));
  }

  Future<void> _setAllowProactive(bool v) async {
    setState(() => _allowProactive = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(allowProactiveKey, v);
    await _syncToServer(v);
  }

  Future<void> _setShowTimestamps(bool v) async {
    setState(() => _showTimestamps = v);
    await TimestampPref.set(v);
  }

  /// 版本号动态读取（package_info_plus），不写死字符串。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _appVersion = info.version);
    } catch (_) {
      // 读不到就保持空，不影响设置页功能
    }
  }

  /// 开关状态同步到服务器（总开关兜底，服务器端调度线程认这个值）。
  /// 失败静默：离线时开关照常生效在本地，下次启动再同步。
  Future<void> _syncToServer(bool v) async {
    try {
      await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/control')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'allow_proactive': v}),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // 网络失败不影响本地开关
    }
  }

  void _toast(String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: TextStyle(fontSize: 13)),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          elevation: 0,
        ),
      );
  }

  /// 检查更新：调 8816 /latest-version 对比当前版本，有新版本弹窗。
  Future<void> _checkUpdate() async {
    try {
      final latest = await AppUpdate.checkLatest();
      final current = await AppUpdate.currentVersion();
      if (!mounted) return;
      final version = latest['version'] ?? '';
      if (version.isEmpty) {
        _toast('检查更新失败');
        return;
      }
      if (!AppUpdate.isNewer(version, current)) {
        _toast('已是最新版本');
        return;
      }
      _showUpdateDialog(version, latest['apkUrl'] ?? '');
    } catch (_) {
      if (mounted) _toast('检查更新失败');
    }
  }

  /// 发现新版本弹窗：[下载] 进入下载流程。
  void _showUpdateDialog(String version, String apkUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text('v$version'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _startDownload(apkUrl);
            },
            child: const Text('下载'),
          ),
        ],
      ),
    );
  }

  /// 下载前先确认"安装未知应用"授权（Android 8+）：未授权跳系统设置，
  /// 返回后自动续下载（didChangeAppLifecycleState）。
  Future<void> _startDownload(String apkUrl) async {
    if (apkUrl.isEmpty) {
      _toast('下载地址无效');
      return;
    }
    try {
      final canInstall = await PermissionCenter.checkSpecial(
        PermissionCenter.installUnknown,
      );
      if (!mounted) return;
      if (!canInstall) {
        _pendingApkUrl = apkUrl;
        final ok = await PermissionCenter.openSettings(
          PermissionCenter.installUnknown,
        );
        if (!ok && mounted) {
          _pendingApkUrl = null;
          _toast('无法打开安装设置');
        }
        return;
      }
      _downloadAndInstall(apkUrl);
    } catch (_) {
      if (mounted) _toast('检查安装权限失败');
    }
  }

  /// 下载 APK（进度弹窗）→ FileProvider 唤起系统安装器。
  /// 从"安装未知应用"设置页返回自动续下载时也先复查授权，没授就提示中止。
  Future<void> _downloadAndInstall(String apkUrl) async {
    try {
      final canInstall = await PermissionCenter.checkSpecial(
        PermissionCenter.installUnknown,
      );
      if (!canInstall) {
        if (mounted) _toast('需要先允许安装未知应用');
        return;
      }
    } catch (_) {
      // 平台通道异常不阻塞下载，安装时系统会再拦一道
    }
    if (!mounted) return;
    final progress = ValueNotifier<double>(0);
    BuildContext? dialogCtx;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('正在下载更新…'),
                const SizedBox(height: AppSpacing.md),
                ValueListenableBuilder<double>(
                  valueListenable: progress,
                  builder: (_, v, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.full),
                        child: LinearProgressIndicator(value: v, minHeight: 6),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${(v * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    try {
      final path = await AppUpdate.download(
        apkUrl,
        onProgress: (p) => progress.value = p,
      );
      if (dialogCtx != null && dialogCtx!.mounted) {
        Navigator.of(dialogCtx!).pop();
      }
      final ok = await AppUpdate.install(path);
      if (!ok && mounted) _toast('无法打开安装器，请手动安装');
    } catch (_) {
      if (dialogCtx != null && dialogCtx!.mounted) {
        Navigator.of(dialogCtx!).pop();
      }
      if (mounted) _toast('下载失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mgr = AppThemeManager.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListenableBuilder(
        listenable: mgr,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          children: [
            // ── 聊天 ──
            const AppSectionLabel('聊天', compact: true),
            // ⚡ 快捷消息（v0.2.153，借鉴 RikkaHub QuickMessages）：聊天页入口点发
            _tile(
              icon: LucideIcons.zap,
              title: '快捷消息管理',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const QuickMessagesPage()),
                );
              },
            ),
            // v0.2.83：资料入口挪到抽屉头像（点头像直接编辑），设置页不再重复放
            // 🔔 允许AI 助手主动找我
            _switchCard(
              icon: LucideIcons.bell,
              title: '允许AI 助手主动找我',
              value: _allowProactive,
              onChanged: _setAllowProactive,
            ),
            _switchCard(
              icon: LucideIcons.clock,
              title: '显示气泡时间戳',
              value: _showTimestamps,
              onChanged: _setShowTimestamps,
            ),
            // v0.2.183：显示思考气泡（默认开，关掉聊天页完全不渲染思考气泡）
            ValueListenableBuilder<bool>(
              valueListenable: ReasoningPref.show,
              builder: (context, showReasoning, _) => _switchCard(
                icon: LucideIcons.brain,
                title: '显示思考气泡',
                value: showReasoning,
                onChanged: (v) => unawaited(ReasoningPref.set(v)),
              ),
            ),
            // ── 外观 ──
            const AppSectionLabel('外观'),
            // 🎨 主题
            _tile(
              icon: LucideIcons.palette,
              title: mgr.current.label,
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const ThemeSettingsPage()),
                );
              },
            ),
            // ── 权限与通知 ──
            const AppSectionLabel('权限与通知'),
            _tile(
              icon: LucideIcons.shield,
              title: '权限中心',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const PermissionCenterPage()),
                );
              },
            ),
            // ── 高级 ──
            const AppSectionLabel('高级'),
            _tile(
              icon: LucideIcons.sliders_horizontal,
              title: '高级设置',
              onTap: () {
                Navigator.of(context).push(
                  SwipeBackRoute(builder: (_) => const ConfigCenterPage()),
                );
              },
            ),
            // ── 关于 ──
            const AppSectionLabel('关于'),
            // ⬇️ 应用内更新：8816 /latest-version → 稳定 APK → 系统安装器
            _tile(
              icon: LucideIcons.download,
              title: '检查更新',
              onTap: _checkUpdate,
            ),
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Center(
                child: Text(
                  _appVersion.isEmpty
                      ? 'Continuum Chat'
                      : 'Continuum Chat v$_appVersion',
                  style: TextStyle(
                    fontSize: AppType.caption,
                    color: context.semanticColors.mutedText,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 设置项入口复用全局导航卡片。
  Widget _tile({
    required IconData icon,
    required String title,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return AppNavigationCard(
      icon: icon,
      title: title,
      trailing: trailing,
      onTap: onTap,
    );
  }

  /// 开关卡片：同款基准卡片 + 右侧 Switch。
  Widget _switchCard({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SettingCard(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
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
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
