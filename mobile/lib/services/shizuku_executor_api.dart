import 'package:flutter/services.dart';

/// Typed Dart bridge for the UI-only Shizuku/virtual-display Phase 1 probe.
class ShizukuExecutorApi {
  ShizukuExecutorApi._();

  static const channelName = 'continuum/shizuku_executor';
  static const MethodChannel _channel = MethodChannel(channelName);

  static Future<ShizukuExecutorStatus> status() => _readStatus('status');

  static Future<ShizukuExecutorStatus> requestPermission() =>
      _readStatus('requestPermission');

  static Future<VirtualDisplayProbeResult> probeVirtualDisplay({
    String? packageName,
  }) async {
    final target = packageName?.trim();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'probeVirtualDisplay',
        {if (target != null && target.isNotEmpty) 'package': target},
      );
      return VirtualDisplayProbeResult.fromMap(raw);
    } on PlatformException catch (error) {
      return VirtualDisplayProbeResult.failed(
        targetPackage: target ?? VirtualDisplayProbeResult.defaultTargetPackage,
        error: error.message ?? '第二屏探针调用失败',
      );
    } on MissingPluginException {
      return VirtualDisplayProbeResult.failed(
        targetPackage: target ?? VirtualDisplayProbeResult.defaultTargetPackage,
        error: '当前平台不支持 Shizuku 执行器',
      );
    }
  }

  static Future<bool> closeProbe() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('closeProbe');
      return raw?['closed'] == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<ShizukuExecutorStatus> _readStatus(String method) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method);
      return ShizukuExecutorStatus.fromMap(raw);
    } on PlatformException catch (error) {
      return ShizukuExecutorStatus.unavailable(
        error.message ?? '读取 Shizuku 状态失败',
      );
    } on MissingPluginException {
      return const ShizukuExecutorStatus.unavailable('当前平台不支持 Shizuku');
    }
  }
}

class ShizukuExecutorStatus {
  const ShizukuExecutorStatus({
    required this.binderAvailable,
    required this.authorized,
    required this.canRequestPermission,
    required this.permissionBlocked,
    required this.serverMode,
    required this.probeActive,
    this.serverUid,
    this.apiVersion,
    this.error,
  });

  const ShizukuExecutorStatus.unavailable(this.error)
    : binderAvailable = false,
      authorized = false,
      canRequestPermission = false,
      permissionBlocked = false,
      serverUid = null,
      serverMode = 'unknown',
      apiVersion = null,
      probeActive = false;

  factory ShizukuExecutorStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const ShizukuExecutorStatus.unavailable('原生状态为空');
    }
    return ShizukuExecutorStatus(
      binderAvailable: map['binderAvailable'] == true,
      authorized: map['authorized'] == true,
      canRequestPermission: map['canRequestPermission'] == true,
      permissionBlocked: map['permissionBlocked'] == true,
      serverUid: _asInt(map['serverUid']),
      serverMode: map['serverMode']?.toString() ?? 'unknown',
      apiVersion: _asInt(map['apiVersion']),
      probeActive: map['probeActive'] == true,
      error: _asNonEmptyString(map['error']),
    );
  }

  final bool binderAvailable;
  final bool authorized;
  final bool canRequestPermission;
  final bool permissionBlocked;
  final int? serverUid;
  final String serverMode;
  final int? apiVersion;
  final bool probeActive;
  final String? error;
}

class VirtualDisplayProbeResult {
  const VirtualDisplayProbeResult({
    required this.targetPackage,
    required this.launchRequested,
    required this.frameReceived,
    required this.frameWidth,
    required this.frameHeight,
    required this.routingVerified,
    required this.mainDisplayStolen,
    required this.targetTasks,
    required this.relocation,
    this.displayId,
    this.preMainTopActivity,
    this.preMainResumedActivity,
    this.preMainFocusedActivity,
    this.postMainTopActivity,
    this.postMainResumedActivity,
    this.postMainFocusedActivity,
    this.relocationDetail,
    this.error,
  });

  factory VirtualDisplayProbeResult.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const VirtualDisplayProbeResult.failed(
        targetPackage: defaultTargetPackage,
        error: '原生探针结果为空',
      );
    }
    return VirtualDisplayProbeResult(
      displayId: _asInt(map['displayId']),
      targetPackage: map['targetPackage']?.toString() ?? defaultTargetPackage,
      launchRequested: map['launchRequested'] == true,
      frameReceived: map['frameReceived'] == true,
      frameWidth: _asInt(map['frameWidth']) ?? 0,
      frameHeight: _asInt(map['frameHeight']) ?? 0,
      routingVerified: map['routingVerified'] == true,
      mainDisplayStolen: map['mainDisplayStolen'] == true,
      preMainTopActivity: _asNonEmptyString(map['preMainTopActivity']),
      preMainResumedActivity: _asNonEmptyString(map['preMainResumedActivity']),
      preMainFocusedActivity: _asNonEmptyString(map['preMainFocusedActivity']),
      postMainTopActivity: _asNonEmptyString(map['postMainTopActivity']),
      postMainResumedActivity: _asNonEmptyString(
        map['postMainResumedActivity'],
      ),
      postMainFocusedActivity: _asNonEmptyString(
        map['postMainFocusedActivity'],
      ),
      targetTasks: _readTasks(map['targetTasks']),
      relocation: map['relocation']?.toString() ?? 'not_attempted',
      relocationDetail: _asNonEmptyString(map['relocationDetail']),
      error: _asNonEmptyString(map['error']),
    );
  }

  const VirtualDisplayProbeResult.failed({
    required this.targetPackage,
    required String this.error,
  }) : displayId = null,
       launchRequested = false,
       frameReceived = false,
       frameWidth = 0,
       frameHeight = 0,
       routingVerified = false,
       mainDisplayStolen = false,
       preMainTopActivity = null,
       preMainResumedActivity = null,
       preMainFocusedActivity = null,
       postMainTopActivity = null,
       postMainResumedActivity = null,
       postMainFocusedActivity = null,
       targetTasks = const [],
       relocation = 'not_attempted',
       relocationDetail = null;

  static const defaultTargetPackage = 'com.android.settings';

  final int? displayId;
  final String targetPackage;
  final bool launchRequested;
  final bool frameReceived;
  final int frameWidth;
  final int frameHeight;
  final bool routingVerified;
  final bool mainDisplayStolen;
  final String? preMainTopActivity;
  final String? preMainResumedActivity;
  final String? preMainFocusedActivity;
  final String? postMainTopActivity;
  final String? postMainResumedActivity;
  final String? postMainFocusedActivity;
  final List<VirtualDisplayTaskRecord> targetTasks;
  final String relocation;
  final String? relocationDetail;
  final String? error;

  bool get passed => routingVerified && !mainDisplayStolen && frameReceived;
}

class VirtualDisplayTaskRecord {
  const VirtualDisplayTaskRecord({
    required this.taskId,
    required this.rootTaskId,
    required this.displayId,
    required this.component,
    required this.active,
  });

  factory VirtualDisplayTaskRecord.fromMap(Map<dynamic, dynamic> map) =>
      VirtualDisplayTaskRecord(
        taskId: _asInt(map['taskId']) ?? -1,
        rootTaskId: _asInt(map['rootTaskId']) ?? -1,
        displayId: _asInt(map['displayId']) ?? -1,
        component: map['component']?.toString() ?? 'unknown',
        active: map['active'] == true,
      );

  final int taskId;
  final int rootTaskId;
  final int displayId;
  final String component;
  final bool active;
}

List<VirtualDisplayTaskRecord> _readTasks(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map) VirtualDisplayTaskRecord.fromMap(item),
  ];
}

int? _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};

String? _asNonEmptyString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
