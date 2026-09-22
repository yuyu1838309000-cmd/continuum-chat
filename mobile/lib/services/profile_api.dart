import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// 资料管理（头像 + 备注，体验改造第 4 条）。
/// - 数据源：服务器 8816（heartbeat_server），GET /avatars 拉双方头像 URL + 备注
/// - me = 用户（App 使用者），you = AI 助手；头像 URL 空/失败时用本地发光猫兜底
/// - 改备注 POST /profile；上传头像 POST /avatars（base64 png/jpeg）
/// - 启动拉一次 + shared_preferences 缓存，离线不白屏；ChangeNotifier 全局即时刷新
class ProfileManager extends ChangeNotifier {
  ProfileManager._();
  static final ProfileManager instance = ProfileManager._();

  static String get base => ServerConfig.url(8816, '');
  static const String _cacheKey = 'profile_cache_v1';

  String _meName = '用户';
  String _youName = 'TA';
  String _meAvatar = ''; // 空 = 用本地默认发光猫
  String _youAvatar = '';
  bool _loaded = false;
  int _avatarVersion = 0; // 头像缓存版本：每次上传 +1，URL 拼 ?v= 破 CachedNetworkImage 缓存

  String get meName => _meName;
  String get youName => _youName;
  String get meAvatar => _avatarUrl(_meAvatar);
  String get youAvatar => _avatarUrl(_youAvatar);
  bool get loaded => _loaded;

  /// 头像 URL 拼版本参数：同 URL 换图后带新 ?v=，图片缓存立即失效刷新。
  String _avatarUrl(String url) => url.isEmpty ? '' : '$url?v=$_avatarVersion';

  /// 启动/心跳拉一次。先读缓存（秒显），再拉服务器覆盖，失败静默。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        _apply(jsonDecode(cached) as Map<String, dynamic>);
      }
    } catch (_) {
      // 缓存坏了忽略
    }
    try {
      final resp = await http
          .get(Uri.parse('$base/avatars'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        _apply(jsonDecode(resp.body) as Map<String, dynamic>);
        // v0.2.83 修复：换头像重启后变回默认。
        // 旧代码把服务器裸响应直接写缓存——服务器响应没有 avatar_version 字段，
        // 覆盖后版本号丢回 0，重启后 URL 不带 ?v=，CachedNetworkImage 命中磁盘里
        // 换图前的旧图（默认发光猫），看起来"变回默认"。改用 _cache() 落盘，
        // 版本号跟着一起存，重启后仍带 ?v= 刷新到新图。
        await _cache();
      }
    } catch (_) {
      // 离线：保持缓存/默认
    }
    _loaded = true;
    notifyListeners();
  }

  void _apply(Map<String, dynamic> j) {
    _meName = (j['me_name'] as String? ?? _meName).trim().isEmpty
        ? _meName
        : (j['me_name'] as String).trim();
    _youName = (j['you_name'] as String? ?? _youName).trim().isEmpty
        ? _youName
        : (j['you_name'] as String).trim();
    _meAvatar = (j['me_avatar'] as String? ?? '').trim();
    _youAvatar = (j['you_avatar'] as String? ?? '').trim();
    if (j['avatar_version'] is num) {
      _avatarVersion = (j['avatar_version'] as num).toInt();
    }
  }

  Future<void> _cache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'me_name': _meName,
          'you_name': _youName,
          'me_avatar': _meAvatar,
          'you_avatar': _youAvatar,
          'avatar_version': _avatarVersion,
        }),
      );
    } catch (_) {
      // 缓存失败不影响
    }
  }

  /// 改备注：meName = 我的名字，youName = AI 助手的名字（可只传一个）。
  /// 成功返回 true 并全局广播（聊天页/抽屉名字即时变）。
  Future<bool> setNames({String? meName, String? youName}) async {
    final body = <String, dynamic>{};
    if (meName != null && meName.trim().isNotEmpty) {
      body['me_name'] = meName.trim();
    }
    if (youName != null && youName.trim().isNotEmpty) {
      body['you_name'] = youName.trim();
    }
    if (body.isEmpty) return false;
    try {
      final resp = await http
          .post(
            Uri.parse('$base/profile'),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 6));
      if (resp.statusCode == 200) {
        _apply(jsonDecode(resp.body) as Map<String, dynamic>);
        await _cache();
        notifyListeners();
        return true;
      }
    } catch (_) {
      // 网络失败不阻塞
    }
    return false;
  }

  /// 上传头像：who = me/you，bytes = 图片数据（png/jpeg）。
  /// 成功更新 URL 并全局广播（对话气泡头像即时换）。
  Future<bool> uploadAvatar({
    required String who,
    required Uint8List bytes,
  }) async {
    if (who != 'me' && who != 'you') return false;
    try {
      final resp = await http
          .post(
            Uri.parse('$base/avatars'),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'who': who, 'data': base64Encode(bytes)}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final url = (j['url'] as String? ?? '').trim();
        if (url.isNotEmpty) {
          _avatarVersion += 1;
          if (who == 'me') {
            _meAvatar = url;
          } else {
            _youAvatar = url;
          }
          await _cache();
          notifyListeners();
          return true;
        }
      }
    } catch (_) {
      // 网络失败不阻塞
    }
    return false;
  }
}
