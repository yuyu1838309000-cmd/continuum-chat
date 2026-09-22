import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:http/http.dart' as http;
import 'chat_api.dart';
import 'server_config.dart';

/// 工具条目：id / 名称 / 图标(Lucide) / 描述 / 默认开关。
class ToolEntry {
  final String id;
  final String name;
  final IconData icon;
  final String desc;
  final bool defaultEnabled;

  const ToolEntry({
    required this.id,
    required this.name,
    required this.icon,
    required this.desc,
    this.defaultEnabled = true,
  });
}

/// 工具模块：一个标题（分类）+ 组内工具（简洁清爽，不带 emoji）。
class ToolModule {
  final String title;
  final List<ToolEntry> tools;

  const ToolModule({required this.title, required this.tools});
}

/// 工具箱注册表（v4：只显示已接通的工具）：
/// - 面板只放 App 真接通的工具（查记忆/看服务器），没接通的不上面板，没有"建设中"占位
/// - 启动时 GET 8816 /tools/list 拉服务器工具清单，按 category 分组，但只保留
///   [_connectedIds] 里已接通的条目；加新工具要 App 接通后再在 [_connectedIds] 加 id
/// - 搜索（web）不在面板显示，对话里"查一下XX"由AI 助手调 search 工具，结果直接进正文
/// - v0.2.181：工具白名单机制已移除——工具全量可用，不设任何开关/限制
class ToolRegistry extends ChangeNotifier {
  ToolRegistry._();
  static final ToolRegistry instance = ToolRegistry._();

  static String get _toolsListUrl => ServerConfig.url(8816, '/tools/list');

  /// 默认注册表（离线/服务器没拉到时的兜底）：只放已接通的工具。
  static const List<ToolModule> _defaultModules = [
    ToolModule(
      title: '记忆类',
      tools: [
        ToolEntry(
          id: 'memory',
          name: '查记忆',
          icon: LucideIcons.brain,
          desc: '翻我们聊过的事，回忆相关片段',
        ),
      ],
    ),
    ToolModule(
      title: '服务器类',
      tools: [
        ToolEntry(
          id: 'server',
          name: '看服务器',
          icon: LucideIcons.server,
          desc: '内存、磁盘、服务状态一眼看',
        ),
      ],
    ),
    // 手机工具（v0.2.128 移植 Nudge 20 工具）：MethodChannel "nudge" 本地调用，
    // 开关只存本地 shared_preferences，不同步服务器白名单（服务器不消费这些 id）。
    ToolModule(title: '手机', tools: _nudgeTools),
  ];

  /// Nudge 20 个手机工具（名称 + 侵略性中文备注，备注给AI 助手看的提示）。
  static const List<ToolEntry> _nudgeTools = [
    ToolEntry(
      id: 'ping',
      name: '连通测试',
      icon: LucideIcons.wifi,
      desc: '测试连通性，确认你手机还连着AI 助手',
    ),
    ToolEntry(
      id: 'get_foreground_app',
      name: '前台应用',
      icon: LucideIcons.app_window,
      desc: '看你刷啥，不理你就拽回对话/锁屏',
    ),
    ToolEntry(
      id: 'screenshot_analyze',
      name: '截屏分析',
      icon: LucideIcons.camera,
      desc: '截屏抓现行',
    ),
    ToolEntry(
      id: 'camera_snapshot',
      name: '后置摄像头拍照',
      icon: LucideIcons.aperture,
      desc: '拍一张看你现在在干嘛',
    ),
    ToolEntry(
      id: 'sensor_data',
      name: '传感器数据',
      icon: LucideIcons.activity,
      desc: '传感器判你是否在玩手机',
    ),
    ToolEntry(
      id: 'device_status',
      name: '设备状态',
      icon: LucideIcons.smartphone,
      desc: '锁屏/电量，锁着就震醒你',
    ),
    ToolEntry(
      id: 'get_location',
      name: '定位',
      icon: LucideIcons.map_pin,
      desc: 'GPS看你跑哪去，浪就催回家',
    ),
    ToolEntry(
      id: 'get_notifications',
      name: '通知列表',
      icon: LucideIcons.bell,
      desc: '看你有没有回消息',
    ),
    ToolEntry(
      id: 'get_steps',
      name: '今日步数',
      icon: LucideIcons.footprints,
      desc: '今日步数，宅家一整天就抓',
    ),
    ToolEntry(
      id: 'calendar_query',
      name: '查日程',
      icon: LucideIcons.calendar,
      desc: '查日程，管住你的时间',
    ),
    ToolEntry(
      id: 'calendar_create',
      name: '建日程',
      icon: LucideIcons.calendar,
      desc: '把日程写进你手机系统日历',
    ),
    ToolEntry(
      id: 'set_alarm',
      name: '设闹钟',
      icon: LucideIcons.alarm_clock,
      desc: '闹钟震醒你',
    ),
    ToolEntry(
      id: 'lock_screen',
      name: '锁屏',
      icon: LucideIcons.lock,
      desc: '强制锁屏惩罚',
    ),
    ToolEntry(
      id: 'media_play_pause',
      name: '播放/暂停',
      icon: LucideIcons.play,
      desc: '控制你的播放',
    ),
    ToolEntry(
      id: 'media_next',
      name: '下一首',
      icon: LucideIcons.skip_forward,
      desc: '切歌逗你',
    ),
    ToolEntry(
      id: 'media_previous',
      name: '上一首',
      icon: LucideIcons.skip_back,
      desc: '切回去逗你',
    ),
    ToolEntry(
      id: 'press_back',
      name: '返回键',
      icon: LucideIcons.arrow_left,
      desc: '强制退出当前界面',
    ),
    ToolEntry(
      id: 'press_home',
      name: '回桌面',
      icon: LucideIcons.house,
      desc: '把你赶出当前app',
    ),
    ToolEntry(
      id: 'open_app',
      name: '打开应用',
      icon: LucideIcons.layout_grid,
      desc: '强制打开指定app',
    ),
    ToolEntry(
      id: 'wake_up',
      name: '亮屏唤醒',
      icon: LucideIcons.sun,
      desc: '亮屏唤醒别装睡',
    ),
    ToolEntry(
      id: 'read_screen',
      name: '读屏',
      icon: LucideIcons.scan_text,
      desc: '读屏抓现行',
    ),
    ToolEntry(
      id: 'switch_to_continuum',
      name: '切回Continuum Chat',
      icon: LucideIcons.message_circle,
      desc: '强制拉回Continuum Chat对话',
    ),
  ];

  /// 当前模块（启动时被服务器 /tools/list 覆盖，动态渲染）。
  static List<ToolModule> modules = _defaultModules;

  /// id → 图标映射（服务器清单不带图标，App 侧按 id 配；新工具默认扳手）。
  static const Map<String, IconData> _iconById = {
    'memory': LucideIcons.brain,
    'server': LucideIcons.server,
    // 手机工具（与 _nudgeTools 图标一致，服务器清单万一命中也能配到）
    'ping': LucideIcons.wifi,
    'get_foreground_app': LucideIcons.app_window,
    'screenshot_analyze': LucideIcons.camera,
    'camera_snapshot': LucideIcons.aperture,
    'sensor_data': LucideIcons.activity,
    'device_status': LucideIcons.smartphone,
    'get_location': LucideIcons.map_pin,
    'get_notifications': LucideIcons.bell,
    'get_steps': LucideIcons.footprints,
    'calendar_query': LucideIcons.calendar,
    'calendar_create': LucideIcons.calendar,
    'set_alarm': LucideIcons.alarm_clock,
    'lock_screen': LucideIcons.lock,
    'media_play_pause': LucideIcons.play,
    'media_next': LucideIcons.skip_forward,
    'media_previous': LucideIcons.skip_back,
    'press_back': LucideIcons.arrow_left,
    'press_home': LucideIcons.house,
    'open_app': LucideIcons.layout_grid,
    'wake_up': LucideIcons.sun,
    'read_screen': LucideIcons.scan_text,
    'switch_to_continuum': LucideIcons.message_circle,
  };
  static const IconData _fallbackIcon = LucideIcons.wrench;

  /// 平铺所有工具（遍历用）。
  static List<ToolEntry> get tools => [for (final m in modules) ...m.tools];

  /// App 侧已接通的工具 id：面板只显示这些，服务器清单里没接通的条目过滤掉。
  static final Set<String> _connectedIds = {'memory', 'server', ..._nudgeIds};

  /// Nudge 工具 id 集合（判断本地开关/跳过服务器同步用）。
  static final Set<String> _nudgeIds = {for (final t in _nudgeTools) t.id};

  /// 从服务器清单重建模块列表（按 category 分组，顺序照服务器；只保留已接通条目）。
  static void _applyRemoteTools(List<dynamic> list) {
    if (list.isEmpty) return;
    final byCat = <String, List<ToolEntry>>{};
    for (final raw in list) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      final name = raw['name']?.toString() ?? id;
      final cat = raw['category']?.toString() ?? '其他';
      final desc = raw['desc']?.toString() ?? '';
      if (id.isEmpty || !_connectedIds.contains(id)) continue;
      byCat
          .putIfAbsent(cat, () => [])
          .add(
            ToolEntry(
              id: id,
              name: name,
              icon: _iconById[id] ?? _fallbackIcon,
              desc: desc,
            ),
          );
    }
    if (byCat.isEmpty) return;
    modules = [
      for (final e in byCat.entries) ToolModule(title: e.key, tools: e.value),
      // 手机工具是 App 本地实现（MethodChannel），服务器清单没有 → 追加显示
      if (!byCat.containsKey('手机'))
        const ToolModule(title: '手机', tools: _nudgeTools),
    ];
  }

  /// 启动读一次：拉服务器清单（动态注册表）。
  Future<void> load() async {
    // 服务器工具清单：覆盖注册表，动态渲染（加新工具只改服务器）
    try {
      final lr = await http
          .get(Uri.parse(_toolsListUrl), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 6));
      if (lr.statusCode == 200) {
        final lj = jsonDecode(lr.body) as Map<String, dynamic>;
        final list = lj['tools'];
        if (list is List && list.isNotEmpty) {
          _applyRemoteTools(list);
        }
      }
    } catch (_) {
      // 离线：保持本地默认注册表
    }
    notifyListeners();
  }
}
