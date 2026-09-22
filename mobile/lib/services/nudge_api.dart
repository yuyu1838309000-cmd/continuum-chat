import 'package:flutter/services.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 手机工具平台通道（v0.2.128 移植 Nudge 20 工具）。
/// 原生实现见 android/.../NudgeTools.kt（MethodChannel "nudge"，入口 call）。
/// 与 Nudge MCP tools/call 同格式：返回 JSON 字符串（{"success":true,...} / {"error":"..."}）。
/// v0.2.129：每次调用自动注入 server（服务器 host）+ token（X-Token），
/// 供截图分析等需要回服务器干活的原生工具用（key 在服务器，App 不持有）。
class NudgeApi {
  NudgeApi._();

  static const MethodChannel _channel = MethodChannel('nudge');

  /// 调用一个手机工具。arguments 按工具需要传（set_alarm/open_app 等）。
  /// 返回 JSON 字符串；平台通道异常时返回 {"error": "..."} 兜底。
  static Future<String> call(
    String tool, {
    Map<String, dynamic> arguments = const {},
  }) async {
    try {
      final res = await _channel.invokeMethod<String>('call', {
        'tool': tool,
        'arguments': {
          ...arguments,
          'server_base_url': ServerConfig.runtimeUrl(''),
          'token': ChatApi.serverToken,
        },
      });
      return res ?? '{"error":"无返回结果"}';
    } on PlatformException catch (e) {
      return '{"error":"平台调用失败: ${e.message}"}';
    } catch (e) {
      return '{"error":"调用失败: $e"}';
    }
  }

  /// 工具 id 常量（与 ToolRegistry 的 _nudgeTools 对齐）。
  static const String ping = 'ping';
  static const String getForegroundApp = 'get_foreground_app';
  static const String screenshotAnalyze = 'screenshot_analyze';
  static const String cameraSnapshot = 'camera_snapshot';
  static const String sensorData = 'sensor_data';
  static const String deviceStatus = 'device_status';
  static const String getLocation = 'get_location';
  static const String getNotifications = 'get_notifications';
  static const String getSteps = 'get_steps';
  static const String calendarQuery = 'calendar_query';
  static const String calendarCreate = 'calendar_create';
  static const String setAlarm = 'set_alarm';
  static const String lockScreen = 'lock_screen';
  static const String mediaPlayPause = 'media_play_pause';
  static const String mediaNext = 'media_next';
  static const String mediaPrevious = 'media_previous';
  static const String pressBack = 'press_back';
  static const String pressHome = 'press_home';
  static const String openApp = 'open_app';
  static const String wakeUp = 'wake_up';
  static const String readScreen = 'read_screen';
  static const String switchToContinuum = 'switch_to_continuum';

  /// 全部工具 id。
  static const List<String> all = [
    ping,
    getForegroundApp,
    screenshotAnalyze,
    cameraSnapshot,
    sensorData,
    deviceStatus,
    getLocation,
    getNotifications,
    getSteps,
    calendarQuery,
    calendarCreate,
    setAlarm,
    lockScreen,
    mediaPlayPause,
    mediaNext,
    mediaPrevious,
    pressBack,
    pressHome,
    openApp,
    wakeUp,
    readScreen,
    switchToContinuum,
  ];
}
