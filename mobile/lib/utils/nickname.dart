import 'package:flutter/foundation.dart';
import '../services/profile_api.dart';

/// 我的昵称（默认"AI 助手"）：抽屉头像旁可点改名，全局生效（AppBar 标题同用）。
/// v0.2.41 起数据源迁到服务器 profile.json（ProfileManager 的 you_name），
/// 本类保留对外接口（name/load/setName），聊天页/抽屉不用大改；
/// 改名 = 改服务器备注，心跳/对话时AI 助手能感知。
class NicknameManager extends ChangeNotifier {
  NicknameManager._();
  static final NicknameManager instance = NicknameManager._();

  /// AI 助手显示的名字 = 服务器 profile 的 you_name（用户可改备注）。
  String get name => ProfileManager.instance.youName;

  /// 启动读一次（内部拉服务器 + 缓存，离线用缓存/默认）。
  Future<void> load() async {
    await ProfileManager.instance.load();
    notifyListeners();
  }

  /// 改昵称：空不写。成功（服务器确认）才广播。
  Future<void> setName(String name) async {
    final v = name.trim();
    if (v.isEmpty) return;
    final ok = await ProfileManager.instance.setNames(youName: v);
    if (ok) notifyListeners();
  }
}
