import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:camera/camera.dart';

import 'chat_api.dart';
import 'permission_center.dart';
import 'server_config.dart';

/// 后置摄像头拍照工具（v0.2.161，工具 id camera_snapshot）：
/// - AI 助手调 camera_snapshot 工具 → 8816 SSE 推 nudge_pending → App 这里直接
///   用 camera 插件打开后置摄像头并自动拍照（v0.2.181：不再拉起系统相机 UI
///   等手动按快门，初始化完成即 takePicture）；
/// - 照片压缩后转 base64 直接 POST 8816 /ocr（复用 App 发图 OCR 链路，服务器
///   ~/ocr.py 的 qwen-vl：识别图片文字 + 「画面补充：」场景描述，key 在服务器不过 App）；
/// - 只回传文字结果（OCR + 画面分析），不回传图片，保持链路轻。
/// - 与截图工具 screenshot_analyze 同链路：tool_registry 注册 → nudge_api 常量 →
///   8816 委托执行 → POST /tool-result 回传；执行放 Dart 侧（image_picker 需要
///   Activity/UI 上下文，不能走 NudgeTools.kt 的后台线程）。
class CameraSnapshotApi {
  CameraSnapshotApi._();

  static const String toolId = 'camera_snapshot';

  /// 执行一次「后置拍照 + OCR/画面分析」，返回 JSON 字符串
  /// （与 NudgeApi.call 同格式：{"success":true,"description":...} / {"error":...}）。
  static Future<String> run() async {
    // 1. 相机权限（Manifest 已声明 CAMERA；Android 声明后必须先授权才能用相机 intent）
    final granted = await PermissionCenter.request([
      PermissionCenter.permCamera,
    ]);
    if (granted[PermissionCenter.permCamera] != true) {
      return '{"error":"未授权相机权限，请到权限中心开启相机"}';
    }
    try {
      // 2. 后置摄像头自动拍照：列出相机，选后置（没有就第一个），
      //    初始化完成后直接 takePicture，不等系统相机 UI、不手动按快门。
      final cameras = await availableCameras();
      CameraDescription? rear;
      for (final c in cameras) {
        if (c.lensDirection == CameraLensDirection.back) {
          rear = c;
          break;
        }
      }
      rear ??= cameras.isEmpty ? null : cameras.first;
      if (rear == null) {
        return '{"error":"设备上没有可用摄像头"}';
      }
      final controller = CameraController(
        rear,
        ResolutionPreset.high,
        enableAudio: false,
      );
      try {
        await controller.initialize();
      } catch (e) {
        return '{"error":"摄像头初始化失败: $e"}';
      }
      final XFile? file;
      try {
        file = await controller.takePicture();
      } catch (e) {
        await controller.dispose();
        return '{"error":"自动拍照失败: $e"}';
      }
      await controller.dispose();
      // 3. base64 直接送服务器 /ocr（识别文字 + 画面补充描述），不落服务器文件
      final text = await _ocrBase64(await file.readAsBytes());
      if (text == null) {
        return '{"error":"照片识别失败，检查网络后重试"}';
      }
      return jsonEncode({'success': true, 'description': text});
    } catch (e) {
      return '{"error":"拍照失败: $e"}';
    }
  }

  /// POST 8816 /ocr（{data: base64} → {text}），失败返回 null。
  static Future<String?> _ocrBase64(Uint8List bytes) async {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/ocr')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'data': base64Encode(bytes)}),
          )
          .timeout(const Duration(seconds: 45));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final text = j['text'] as String?;
        return (text == null || text.trim().isEmpty) ? null : text.trim();
      }
    } catch (e) {
      debugPrint('[camera-snapshot] ocr failed: $e');
    }
    return null;
  }
}
