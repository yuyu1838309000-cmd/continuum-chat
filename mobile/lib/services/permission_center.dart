import 'package:flutter/services.dart';

/// 权限中心平台通道：封装 Android 原生权限检查/申请/系统设置跳转。
/// 原生实现见 android/.../MainActivity.kt（MethodChannel continuum/permission_center）。
/// 检查状态一律实时查（页面可见时 onResume 刷新，不缓存）。
class PermissionCenter {
  PermissionCenter._();

  static const MethodChannel _channel = MethodChannel(
    'continuum/permission_center',
  );

  /// 系统特殊权限类型（checkSpecial / openSettings 共用）。
  static const String notifListener = 'notification_listener';
  static const String accessibility = 'accessibility';
  static const String usageStats = 'usage_stats';
  static const String exactAlarm = 'exact_alarm';
  static const String appDetails = 'app_details';

  /// v0.2.104 应给尽给：安装未知应用（ACTION_MANAGE_UNKNOWN_APP_SOURCES）。
  static const String installUnknown = 'install_unknown';

  /// 悬浮窗（Settings.canDrawOverlays）。
  static const String overlay = 'overlay';

  /// 蓝牙连接检查（Android 12+ 运行时；11 及以下普通权限视为已内置）。
  static const String bluetooth = 'bluetooth';

  /// 运行时权限常量（AndroidManifest 已声明）。
  static const String permNotifications =
      'android.permission.POST_NOTIFICATIONS';
  static const String permFineLocation =
      'android.permission.ACCESS_FINE_LOCATION';
  static const String permCoarseLocation =
      'android.permission.ACCESS_COARSE_LOCATION';
  static const String permCalendar = 'android.permission.READ_CALENDAR';
  static const String permCalendarWrite = 'android.permission.WRITE_CALENDAR';
  static const String permActivityRecognition =
      'android.permission.ACTIVITY_RECOGNITION';
  static const String permMicrophone = 'android.permission.RECORD_AUDIO';
  static const String permCamera = 'android.permission.CAMERA';
  static const String permBluetoothConnect =
      'android.permission.BLUETOOTH_CONNECT';

  /// 存储权限按 SDK 分级：13+ READ_MEDIA_IMAGES/AUDIO/VIDEO，12 及以下 READ_EXTERNAL_STORAGE。
  static Future<List<String>> mediaPermissions() async {
    final list = await _channel.invokeMethod<List<dynamic>>('mediaPermissions');
    return (list ?? const []).cast<String>();
  }

  /// 检查一组运行时权限（checkSelfPermission），全部已授权返回 true。
  static Future<bool> allGranted(List<String> permissions) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'checkRuntime',
      permissions,
    );
    return permissions.every((p) => result?[p] == true);
  }

  /// 申请一组运行时权限（requestPermissions），返回每个权限的授权结果。
  static Future<Map<String, bool>> request(List<String> permissions) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'requestRuntime',
      permissions,
    );
    return (result ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v == true),
    );
  }

  /// 检查系统特殊权限状态（通知使用权 / 无障碍 / 使用情况统计 / 精确闹钟）。
  static Future<bool> checkSpecial(String type) async {
    final granted = await _channel.invokeMethod<bool>('checkSpecial', type);
    return granted ?? false;
  }

  /// 跳转系统设置页（特殊权限授权 / 精确闹钟申请 / 应用详情）。
  static Future<bool> openSettings(String type) async {
    final ok = await _channel.invokeMethod<bool>('openSettings', type);
    return ok ?? false;
  }

  /// 安装 APK（应用内更新）：FileProvider 授权 + ACTION_VIEW 唤起系统安装器。
  static Future<bool> installApk(String path) async {
    final ok = await _channel.invokeMethod<bool>('installApk', path);
    return ok ?? false;
  }
}
