import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/services/shizuku_executor_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(ShizukuExecutorApi.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('status parses shell authorization state', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return {
        'binderAvailable': true,
        'authorized': true,
        'canRequestPermission': false,
        'permissionBlocked': false,
        'serverUid': 2000,
        'serverMode': 'shell',
        'apiVersion': 13,
        'probeActive': false,
        'error': null,
      };
    });

    final status = await ShizukuExecutorApi.status();

    expect(status.binderAvailable, isTrue);
    expect(status.authorized, isTrue);
    expect(status.serverUid, 2000);
    expect(status.serverMode, 'shell');
    expect(status.apiVersion, 13);
    expect(status.error, isNull);
  });

  test('probe omits blank package and parses frame result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'probeVirtualDisplay');
      expect(call.arguments, isEmpty);
      return {
        'displayId': 7,
        'targetPackage': 'com.android.settings',
        'launchRequested': true,
        'frameReceived': true,
        'frameWidth': 720,
        'frameHeight': 1280,
        'routingVerified': true,
        'mainDisplayStolen': false,
        'preMainTopActivity': 'com.miui.home/.Launcher',
        'postMainTopActivity': 'com.miui.home/.Launcher',
        'targetTasks': [
          {
            'taskId': 52,
            'rootTaskId': 52,
            'displayId': 7,
            'component': 'com.android.settings/.Settings',
            'active': true,
          },
        ],
        'relocation': 'not_needed',
        'error': '',
      };
    });

    final result = await ShizukuExecutorApi.probeVirtualDisplay(
      packageName: '  ',
    );

    expect(result.displayId, 7);
    expect(result.targetPackage, 'com.android.settings');
    expect(result.launchRequested, isTrue);
    expect(result.frameReceived, isTrue);
    expect(result.frameWidth, 720);
    expect(result.frameHeight, 1280);
    expect(result.routingVerified, isTrue);
    expect(result.mainDisplayStolen, isFalse);
    expect(result.passed, isTrue);
    expect(result.targetTasks.single.displayId, 7);
    expect(result.targetTasks.single.active, isTrue);
    expect(result.error, isNull);
  });

  test('malformed values fail closed without claiming success', () {
    final status = ShizukuExecutorStatus.fromMap({
      'binderAvailable': 'true',
      'authorized': 1,
      'serverUid': '2000',
    });
    final probe = VirtualDisplayProbeResult.fromMap({
      'displayId': '9',
      'targetPackage': 'com.taobao.taobao',
      'launchRequested': 'true',
      'frameReceived': 1,
      'frameWidth': '720',
      'frameHeight': 1280.0,
      'error': 'blocked',
    });

    expect(status.binderAvailable, isFalse);
    expect(status.authorized, isFalse);
    expect(status.serverUid, 2000);
    expect(probe.displayId, 9);
    expect(probe.launchRequested, isFalse);
    expect(probe.frameReceived, isFalse);
    expect(probe.frameWidth, 720);
    expect(probe.frameHeight, 1280);
    expect(probe.routingVerified, isFalse);
    expect(probe.error, 'blocked');
  });

  test('trampoline takeover remains a hard failure with task diagnostics', () {
    final probe = VirtualDisplayProbeResult.fromMap({
      'displayId': 14,
      'targetPackage': 'com.taobao.taobao',
      'launchRequested': false,
      'frameReceived': true,
      'frameWidth': 720,
      'frameHeight': 1280,
      'routingVerified': false,
      'mainDisplayStolen': true,
      'preMainTopActivity': 'com.miui.home/.Launcher',
      'postMainTopActivity': 'com.taobao.taobao/.TBMainActivity',
      'targetTasks': [
        {
          'taskId': 41,
          'rootTaskId': 41,
          'displayId': 0,
          'component': 'com.taobao.taobao/.TBMainActivity',
          'active': true,
        },
        {
          'taskId': 52,
          'rootTaskId': 52,
          'displayId': 14,
          'component': 'com.taobao.taobao/.Welcome',
          'active': false,
        },
      ],
      'relocation': 'unsupported',
      'relocationDetail': '设备未提供安全迁移接口',
      'error': '目标包在稳定期后占用了物理 display 0',
    });

    expect(probe.routingVerified, isFalse);
    expect(probe.mainDisplayStolen, isTrue);
    expect(probe.frameReceived, isTrue);
    expect(probe.passed, isFalse);
    expect(probe.targetTasks.map((task) => task.displayId), [0, 14]);
    expect(probe.relocation, 'unsupported');
  });

  test('closeProbe reports whether native display was released', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'closeProbe');
      return {'closed': true, 'error': null};
    });

    expect(await ShizukuExecutorApi.closeProbe(), isTrue);
  });
}
