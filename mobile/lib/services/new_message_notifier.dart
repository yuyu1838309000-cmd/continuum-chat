import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 新消息系统通知（v0.2.161）：
/// - assistant 完整回复生成完（chat_page._finishReply）且 App 不在前台（退后台/
///   锁屏）时，发一条系统通知；前台已有气泡，不弹；
/// - 渠道 new_message（importance high），标题"Continuum Chat"，正文取回复前 60 字截断；
/// - 点通知回到Continuum Chat：App 单会话，最底层路由就是聊天页，tap 后 popUntil 弹掉
///   聊天页之上的所有页面，直接落在当前会话；
/// - payload 带 conversation_id（当前 App 只有当前对话窗口，固定 "current"，
///   给将来多会话留位）。
class NewMessageNotifier {
  NewMessageNotifier._();
  static final NewMessageNotifier instance = NewMessageNotifier._();

  static const String _channelId = 'new_message';
  static const String _channelName = '新消息';
  static const String _channelDesc = 'AI 助手回复你时的消息提醒';
  static const int _maxBodyChars = 60;

  /// main.dart 注入的全局导航 key（点通知跳回聊天页用）。
  static GlobalKey<NavigatorState>? navigatorKey;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final _LifecycleWatcher _lifecycleWatcher = _LifecycleWatcher();
  int _nextId = 1;
  bool _initialized = false;
  bool _permissionGranted = false;
  bool _inForeground = true;

  /// App 启动时初始化：注册通知渠道 + 申请 Android 13+ 通知权限 + 挂生命周期观察。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: _onTap,
        onDidReceiveBackgroundNotificationResponse:
            newMessageNotifierBackgroundTap,
      );
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
      _permissionGranted =
          await androidPlugin?.requestNotificationsPermission() ?? false;
      WidgetsBinding.instance.addObserver(_lifecycleWatcher);
    } catch (e, st) {
      debugPrint('[new-message-notifier] init failed: $e\n$st');
    }
  }

  /// assistant 完整回复生成完调用。App 前台不弹，只有退后台/锁屏才通知。
  Future<void> maybeNotify(String content) async {
    if (!_initialized || !_permissionGranted || _inForeground) return;
    final text = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return;
    final body = text.length > _maxBodyChars
        ? '${text.substring(0, _maxBodyChars)}…'
        : text;
    final id = _nextId++;
    if (_nextId > 0x7fffffff) _nextId = 1;
    try {
      await _plugin.show(
        id: id,
        title: 'Continuum Chat',
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: '{"conversation_id":"current"}',
      );
    } catch (e, st) {
      debugPrint('[new-message-notifier] show failed: $e\n$st');
    }
  }

  /// 点通知（App 活着）：弹掉聊天页之上的所有页面，落在当前会话。
  static void _onTap(NotificationResponse response) {
    navigatorKey?.currentState?.popUntil((route) => route.isFirst);
  }
}

/// App 生命周期观察：前台 resumed = 不弹通知，退后台/锁屏才弹。
class _LifecycleWatcher extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NewMessageNotifier.instance._inForeground =
        state == AppLifecycleState.resumed;
  }
}

/// 后台点通知（App 被杀时点通知冷启动）：系统拉起 App，正常启动落聊天页即可，
/// 无需额外跳转（App 单会话）。
@pragma('vm:entry-point')
void newMessageNotifierBackgroundTap(NotificationResponse response) {}
