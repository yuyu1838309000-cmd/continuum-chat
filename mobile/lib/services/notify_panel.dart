import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'background_device_tool_client.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 常驻通知面板（v0.2.103，AI 助手状态牌；v0.2.139 起砍掉音乐媒体通知，恢复纯状态牌）
///
/// 方案：flutter_foreground_task ^10.0.0（前台服务 + 常驻通知一体，最稳）。
/// - 前台服务：App 启动自动拉起，UI 退后台/被划掉服务仍在，通知在（Android 前台服务机制）
/// - setOngoing(true)：插件对前台服务通知自动设置，用户清不掉（只能手动停服务）
/// - 通知内容：标题"Continuum Chat"，正文来自 8816 GET /notify-status（~/notify-status.json，AI 助手维护）
/// - 更新链路：主 isolate 扩展现有心跳轮询（chat_page._pollHeartbeat 顺带拉）；
///   后台 TaskHandler 每 30 秒自拉一次，App 被杀也能刷状态；内容没变不 updateService。
/// - foreground-task 会创建独立 FlutterEngine；Android Application 会为该 engine
///   补注册Continuum Chat自有的 nudge / device-execution 通道，普通 Flutter 插件仍由
///   FlutterEngine 的自动插件注册机制提供。
///
/// 音乐媒体通知已砍（v0.2.139，用户拍板）：MusicMediaService + MediaSession
/// 连续 v0.2.136/137/138 三版未正常显示，不再做媒体通知。通知栏始终只有
/// 这一条状态牌：启动即拉起、心跳轮询动态刷新，播放/切歌不碰它。
class NotifyPanel {
  NotifyPanel._();
  static final NotifyPanel instance = NotifyPanel._();

  static const String _lastTextKey = 'notify_panel_last_text';
  static const String _defaultContent = 'AI 助手在整理记忆 🌙';

  String _lastShown = ''; // 上次展示的正文（主 isolate 内存判重）
  bool _started = false;

  /// App 启动后自动拉起（main.dart runApp 之后 fire-and-forget，不阻塞启动）。
  /// Android 13+ 先申请通知权限（前台服务通知必须授权才显示），
  /// 权限中心页也可以手动开关。
  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    try {
      _initPlugin();

      final perm = await FlutterForegroundTask.checkNotificationPermission();
      if (perm != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // 服务器地址同步给后台任务（换服务器时设置页改 host 也会推一次）
      _syncHostToTask();
      ServerConfig.instance.addListener(_syncHostToTask);

      await _startStatusService();
      // startService 之前 sendDataToTask 可能还没有接收方；服务真正起来后再补发一次，
      // 确保自定义 host 在 UI 随后退后台/被划掉时也不会丢。
      _syncHostToTask();

      // 拉一次最新状态（内容没变不会更新通知）
      await pollStatus();
    } catch (e, st) {
      debugPrint('[notify-panel] start failed: $e\n$st');
    }
  }

  /// 拉起状态牌前台服务（start 用；服务在跑不重复拉）。
  Future<void> _startStatusService() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastShown = prefs.getString(_lastTextKey) ?? '';

      if (!(await FlutterForegroundTask.isRunningService)) {
        final result = await FlutterForegroundTask.startService(
          serviceId: 8816,
          serviceTypes: const [ForegroundServiceTypes.specialUse],
          notificationTitle: 'Continuum Chat',
          notificationText: _defaultContent,
          notificationIcon: null, // 用 App 图标
          notificationInitialRoute: '/',
          callback: notifyPanelStartCallback,
        );
        if (result is ServiceRequestFailure) {
          debugPrint('[notify-panel] startService failed: ${result.error}');
        }
        _lastShown = _defaultContent;
        await prefs.setString(_lastTextKey, _defaultContent);
      }
    } catch (e, st) {
      debugPrint('[notify-panel] start status service failed: $e\n$st');
    }
  }

  /// 手动停服务（通知随之消失；目前未接 UI，给以后留口子）
  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e, st) {
      debugPrint('[notify-panel] stop failed: $e\n$st');
    }
  }

  /// 心跳轮询顺带调用：拉 8816 /notify-status，内容变了才更新通知；失败/空不动。
  /// 只从主 isolate 调（ServerConfig.instance.host 只在主 isolate 有值）。
  Future<void> pollStatus() async {
    if (!Platform.isAndroid) return;
    try {
      if (!(await FlutterForegroundTask.isRunningService)) return;
      final status = await fetchNotifyStatus(
        host: ServerConfig.instance.host,
        runtimePort: ServerConfig.runtimePort,
      );
      if (status.isEmpty) return; // 拉取失败/空：保持现状
      await updateIfChanged(notifyContentOf(status));
    } catch (e) {
      debugPrint('[notify-panel] poll failed: $e');
    }
  }

  /// 内容变了才 updateService（避免心跳频繁导致通知闪烁）。
  /// [rememberLast] 主 isolate 传 true（记本地，重启后不重复刷）；
  /// 后台 TaskHandler 传 false（后台引擎没注册平台插件，只判自己内存）。
  Future<bool> updateIfChanged(
    String content, {
    bool rememberLast = true,
  }) async {
    if (content.isEmpty || content == _lastShown) return false;
    try {
      if (!(await FlutterForegroundTask.isRunningService)) return false;
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Continuum Chat',
        notificationText: content,
      );
      // 更新成功后才记"已展示"，失败保持旧值下次轮询重试
      _lastShown = content;
      if (rememberLast) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastTextKey, content);
      }
      return true;
    } catch (e, st) {
      debugPrint('[notify-panel] update failed: $e\n$st');
      return false;
    }
  }

  void _initPlugin() {
    // start() 有 _started 守卫，进程内只会 init 一次
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'continuum_status',
        channelName: 'Continuum Chat状态',
        channelDescription: 'AI 助手的状态牌常驻通知',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        showBadge: false,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // 后台 TaskHandler 每 30 秒拉一次 /notify-status，App 被杀也能刷状态
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: true,
      ),
    );
  }

  /// Runtime host/port 同步给后台任务（后台引擎读不到 shared_preferences）
  void _syncHostToTask() {
    FlutterForegroundTask.sendDataToTask(<String, dynamic>{
      'type': 'runtime_endpoint',
      'host': ServerConfig.instance.host,
      'runtime_port': ServerConfig.runtimePort,
    });
  }
}

/// 后台前台服务入口（必须是顶层函数，插件要求）。
@pragma('vm:entry-point')
void notifyPanelStartCallback() {
  FlutterForegroundTask.setTaskHandler(NotifyPanelTaskHandler());
}

/// 前台服务后台 isolate：App UI 被杀后仍每 30 秒轮询状态，并顺带领取可后台执行的手机工具。
/// 该 isolate 有独立 FlutterEngine；生成插件自动注册，Continuum Chat自有平台通道由
/// Android 的 ContinuumApplication 对后台 engine 额外注册。
class NotifyPanelTaskHandler extends TaskHandler {
  String _host = ServerConfig.defaultHost;
  int _runtimePort = ServerConfig.runtimePort;
  String _lastShown = ''; // 本 isolate 自己的判重
  bool _polling = false;
  final BackgroundDeviceToolClient _deviceTools = BackgroundDeviceToolClient();

  Future<void> _poll() async {
    try {
      if (_polling) return;
      _polling = true;
      final status = await fetchNotifyStatus(
        host: _host,
        runtimePort: _runtimePort,
      );
      if (status.isNotEmpty) {
        final content = notifyContentOf(status);
        if (content.isNotEmpty && content != _lastShown) {
          if (await FlutterForegroundTask.isRunningService) {
            await FlutterForegroundTask.updateService(
              notificationTitle: 'Continuum Chat',
              notificationText: content,
            );
            _lastShown = content;
          }
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await _deviceTools.pollOnce(
        host: _host,
        runtimePort: _runtimePort,
        allowProactive: prefs.getBool('allow_proactive') ?? true,
      );
    } catch (e, st) {
      debugPrint('[notify-panel] task poll failed: $e\n$st');
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await ServerConfig.instance.load();
      _host = ServerConfig.instance.host;
      _runtimePort = ServerConfig.runtimePort;
    } catch (error) {
      debugPrint('[notify-panel] task endpoint load failed: $error');
    }
    await _poll();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_poll());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {
    // 主 isolate 推来的服务器地址（换服务器时同步）
    if (data is Map) {
      final type = data['type'];
      final host = data['host'];
      final runtimePort = data['runtime_port'];
      if (type == 'runtime_endpoint' &&
          host is String &&
          host.trim().isNotEmpty &&
          runtimePort is int) {
        _host = host.trim();
        _runtimePort = runtimePort;
        unawaited(ServerConfig.instance.setHost(_host));
      }
    }
  }
}

/// 拉 Runtime /notify-status（纯 Dart，后台 isolate 也能用）。失败/空返回 {}。
Future<Map<String, String>> fetchNotifyStatus({
  required String host,
  required int runtimePort,
}) async {
  try {
    final resp = await http
        .get(
          Uri(
            scheme: 'http',
            host: host,
            port: runtimePort,
            path: '/notify-status',
          ),
          headers: ChatApi.authHeaders(),
        )
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return const {};
    final j = jsonDecode(utf8.decode(resp.bodyBytes));
    if (j is! Map) return const {};
    final text = (j['text'] as String? ?? '').trim();
    final mood = (j['mood'] as String? ?? '').trim();
    if (text.isEmpty) return const {}; // 空内容不更新
    return {'text': text, 'mood': mood};
  } catch (_) {
    return const {};
  }
}

/// 拼通知正文：text + mood（如"AI 助手在整理记忆 🌙"）
String notifyContentOf(Map<String, String> status) =>
    '${status['text']} ${status['mood']}'.trim();
