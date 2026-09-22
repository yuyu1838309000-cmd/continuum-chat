import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'pages/splash_page.dart';
import 'utils/app_theme.dart';
import 'utils/nickname.dart';
import 'utils/reasoning_pref.dart';
import 'utils/timestamp_pref.dart';
import 'utils/token_usage.dart';
import 'services/tool_registry.dart';
import 'services/tts_api.dart';
import 'services/server_config.dart';
import 'services/notify_panel.dart';
import 'services/music_player.dart';
import 'services/new_message_notifier.dart';
import 'services/app_event_client.dart';
import 'services/chat_runtime_controller.dart';
import 'services/history_cutover_reconciler.dart';

/// 全局导航 key：点新消息通知跳回聊天页用（NewMessageNotifier 消费）。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> _runHistoryCutover() async {
  try {
    await HistoryCutoverCoordinator.instance.ensure();
  } catch (error, stackTrace) {
    debugPrint('[history-cutover] skipped: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 常驻通知面板（v0.2.103）：主 isolate ↔ 前台服务后台 isolate 通信端口，必须在 runApp 前注册
  FlutterForegroundTask.initCommunicationPort();
  // 防白屏①：不 await 任何网络请求，只并行等本地配置（秒读）
  await Future.wait([
    AppThemeManager.instance.load(),
    NicknameManager.instance.load(),
    TimestampPref.load(),
    ReasoningPref.load(),
    TokenUsagePref.load(),
    TtsConfig.instance.load(),
    ServerConfig.instance.load(),
  ]);
  runApp(const FrontendApp());
  // 历史切权只在首个新版启动后后台执行；失败不阻塞 App，成功后由 marker 永久跳过。
  unawaited(_runHistoryCutover());
  // 网络请求全部放 runApp 之后（工具箱清单/白名单），拉到自动刷新，不阻塞启动
  unawaited(ToolRegistry.instance.load());
  // 新消息系统通知（v0.2.161）：初始化渠道 + 通知权限 + 点通知回会话，不阻塞启动
  NewMessageNotifier.navigatorKey = appNavigatorKey;
  unawaited(NewMessageNotifier.instance.init());
  // 常驻通知面板（v0.2.103）：App 启动自动拉起前台服务 + 常驻通知，不阻塞启动
  unawaited(NotifyPanel.instance.start());
  // Runtime supervisor：启动与生命周期恢复都只追同一 durable generation。
  ChatRuntimeController.instance.start();
  // App 级 pending dispatcher：统一 ACK/去重/分流，音乐只进 MusicPlayer 窄入口。
  AppEventClient.instance.start();
  // 一起听歌：只负责播放器状态和音乐 pending 的窄处理入口。
  MusicPlayer.instance.start();
}

class FrontendApp extends StatelessWidget {
  const FrontendApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 全局 iOS 风格转场 + 边缘右滑返回：
    // 设置页及内部页面（模型配置/提示词/分区子页）都能从左边缘右滑回到上一级
    return ListenableBuilder(
      listenable: AppThemeManager.instance,
      builder: (context, _) {
        final appTheme = AppThemeManager.instance.currentTheme;
        return MaterialApp(
          title: 'Continuum Chat',
          navigatorKey: appNavigatorKey,
          debugShowCheckedModeBanner: false,
          theme: appTheme.light,
          darkTheme: appTheme.dark,
          // 深色模式入口：跟随 AppThemeManager.mode（浅色/深色/跟随系统）
          themeMode: AppThemeManager.instance.mode.themeMode,
          // 中文本地化：长按输入框的剪切/复制/粘贴/全选菜单显示中文
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN')],
          locale: const Locale('zh', 'CN'),
          // 防白屏③：全局打底深夜蓝，任何一帧没内容也是蓝不是白
          builder: (context, child) {
            // 字体设置：大小缩放 + 全局默认字重。字体族一律走系统无衬线，
            // 不再内置/注入像素字体（代码块等显式 monospace 不受影响）。
            final mgr = AppThemeManager.instance;
            final mq = MediaQuery.of(context);
            final scaled = mq.textScaler.scale(mgr.fontScale);
            // 用 Theme 覆盖全局字重：对 textTheme 每个样式统一套字重
            final base = Theme.of(context);
            final fw = mgr.fontWeight;
            // 标题/按钮/标签/菜单/正文：统一只套字重，字体族继承系统默认
            TextStyle f(TextStyle? s) =>
                (s ?? const TextStyle()).copyWith(fontWeight: fw);
            final overridden = base.textTheme
                .apply(bodyColor: null, displayColor: null)
                .copyWith(
                  displayLarge: f(base.textTheme.displayLarge),
                  displayMedium: f(base.textTheme.displayMedium),
                  displaySmall: f(base.textTheme.displaySmall),
                  headlineLarge: f(base.textTheme.headlineLarge),
                  headlineMedium: f(base.textTheme.headlineMedium),
                  headlineSmall: f(base.textTheme.headlineSmall),
                  titleLarge: f(base.textTheme.titleLarge),
                  titleMedium: f(base.textTheme.titleMedium),
                  titleSmall: f(base.textTheme.titleSmall),
                  bodyLarge: f(base.textTheme.bodyLarge),
                  bodyMedium: f(base.textTheme.bodyMedium),
                  bodySmall: f(base.textTheme.bodySmall),
                  labelLarge: f(base.textTheme.labelLarge),
                  labelMedium: f(base.textTheme.labelMedium),
                  labelSmall: f(base.textTheme.labelSmall),
                );
            return MediaQuery(
              data: mq.copyWith(textScaler: TextScaler.linear(scaled)),
              child: Theme(
                data: base.copyWith(textTheme: overridden),
                child: ColoredBox(
                  color: base.colorScheme.surface,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            );
          },
          home: const SplashPage(),
        );
      },
    );
  }
}
