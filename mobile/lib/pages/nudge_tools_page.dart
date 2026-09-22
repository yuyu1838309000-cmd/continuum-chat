import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/nudge_api.dart';
import '../services/tool_registry.dart';
import '../services/camera_snapshot_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';
import 'permission_center_page.dart';

/// 手机工具页（v0.2.128 移植 Nudge 20 工具，MethodChannel "nudge" 本地调用）。
/// - 分板块：媒体 / 设备 / 屏幕 / 通知 / 提醒 / 位置 / 应用（不散着平铺）
/// - 每工具一张卡片：工具名 + 侵略性中文备注（v0.2.181 起无开关，工具全量可用）
/// - 点卡片直接调工具（set_alarm/open_app 先弹参数输入），结果弹底部面板显示
/// - 简洁卡片风：圆角 20 + 柔和阴影 + cardColor（design-guide 基准）
class NudgeToolsPage extends StatefulWidget {
  const NudgeToolsPage({super.key});

  @override
  State<NudgeToolsPage> createState() => _NudgeToolsPageState();
}

class _NudgeToolsPageState extends State<NudgeToolsPage> {
  /// 板块结构：标题 + 工具 id（顺序即展示顺序）。
  static const List<(String, List<String>)> _sections = [
    (
      '媒体',
      [NudgeApi.mediaPlayPause, NudgeApi.mediaNext, NudgeApi.mediaPrevious],
    ),
    ('设备', [NudgeApi.deviceStatus, NudgeApi.sensorData, NudgeApi.ping]),
    (
      '屏幕',
      [
        NudgeApi.getForegroundApp,
        NudgeApi.screenshotAnalyze,
        NudgeApi.cameraSnapshot,
        NudgeApi.readScreen,
        NudgeApi.lockScreen,
        NudgeApi.wakeUp,
      ],
    ),
    ('通知', [NudgeApi.getNotifications]),
    ('提醒', [NudgeApi.setAlarm]),
    (
      '位置',
      [
        NudgeApi.getLocation,
        NudgeApi.getSteps,
        NudgeApi.calendarQuery,
        NudgeApi.calendarCreate,
      ],
    ),
    (
      '应用',
      [
        NudgeApi.pressBack,
        NudgeApi.pressHome,
        NudgeApi.openApp,
        NudgeApi.switchToContinuum,
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('手机工具')),
      body: ListenableBuilder(
        listenable: ToolRegistry.instance,
        builder: (context, _) {
          final byId = {for (final t in ToolRegistry.tools) t.id: t};
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              for (final (title, ids) in _sections) ...[
                // 板块标题（小标题，不抢卡片）
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final id in ids)
                  if (byId[id] case final t?) _toolCard(context, t),
              ],
              const SizedBox(height: 4),
            ],
          );
        },
      ),
    );
  }

  /// 工具卡片：图标 + 名称 + 侵略性中文备注 + 开关（独立交互）。
  Widget _toolCard(BuildContext context, ToolEntry t) {
    return SettingCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      onTap: () => _runTool(context, t),
      child: Row(
        children: [
          Icon(
            t.icon,
            size: 24,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t.desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: context.subTextColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 点卡片：set_alarm / open_app 先弹参数输入，其余直接调。
  Future<void> _runTool(BuildContext context, ToolEntry t) async {
    switch (t.id) {
      case NudgeApi.setAlarm:
        await _runSetAlarm(context, t);
      case NudgeApi.openApp:
        await _runOpenApp(context, t);
      default:
        await _run(context, t, const {});
    }
  }

  /// 设闹钟：时间选择 + 消息输入。
  Future<void> _runSetAlarm(BuildContext context, ToolEntry t) async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: now.hour, minute: now.minute),
      helpText: '选闹钟时间',
    );
    if (picked == null || !context.mounted) return;
    final msgCtrl = TextEditingController();
    final message = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('闹钟内容'),
        content: TextField(
          controller: msgCtrl,
          autofocus: true,
          maxLines: 2,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '比如：起床回AI 助手消息'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(msgCtrl.text.trim()),
            child: const Text('响起'),
          ),
        ],
      ),
    );
    if (message == null || !context.mounted) return;
    await _run(context, t, {
      'hour': picked.hour,
      'minute': picked.minute,
      'message': message.isEmpty ? '闹钟' : message,
      'title': message.isEmpty ? '闹钟' : message,
      'note': message.isEmpty ? '时间到啦' : message,
      'repeat': 'once',
    });
  }

  /// 打开应用：输入包名。
  Future<void> _runOpenApp(BuildContext context, ToolEntry t) async {
    final pkgCtrl = TextEditingController();
    final pkg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('应用包名'),
        content: TextField(
          controller: pkgCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '如 com.tencent.mm / com.ss.android.ugc.aweme',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(pkgCtrl.text.trim()),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (pkg == null || pkg.isEmpty || !context.mounted) return;
    await _run(context, t, {'package': pkg});
  }

  /// 统一执行：加载圈 → 调平台通道 → 结果底部面板。
  Future<void> _run(
    BuildContext context,
    ToolEntry t,
    Map<String, dynamic> arguments,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text('${t.name} 执行中…')),
            ],
          ),
        ),
      ),
    );
    final result = t.id == NudgeApi.cameraSnapshot
        ? await CameraSnapshotApi.run()
        : await NudgeApi.call(t.id, arguments: arguments);
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关加载圈
    if (!context.mounted) return;
    _showResult(context, t, result);
  }

  /// 结果底部面板：中文人话反馈 + 权限提示（未授权/未运行 → 去权限中心）。
  /// v0.2.130：不再显示裸 JSON，每个工具把返回字段翻译成中文，成功直接看结果、
  /// 失败给原因和处理；解析失败兜底"操作完成/失败，原因：xx"。
  void _showResult(BuildContext context, ToolEntry t, String raw) {
    final friendly = _friendlyText(t, raw);
    final isError = friendly.startsWith('操作失败');
    // v0.2.129：去掉 '请先' 误匹配（原"请先配置API Key"会误报成权限问题）。
    // v0.2.130：补"通知监听服务未开启"（权限中心可开通知使用权）。
    final needPerm =
        raw.contains('未授权') ||
        raw.contains('未运行') ||
        raw.contains('需要Android') ||
        raw.contains('通知监听服务未开启');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        final statusColor = isError
            ? theme.colorScheme.error
            : ctx.successColor;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部细把手
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text(
                      t.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // 成功/失败状态
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                    child: Row(
                      children: [
                        Icon(
                          isError
                              ? LucideIcons.circle_x
                              : LucideIcons.circle_check,
                          size: 16,
                          color: statusColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          isError ? '执行失败' : '执行成功',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (needPerm)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.shield_alert,
                            size: 16,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '需要先授权相关权限才能用',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.of(ctx).pop();
                              if (context.mounted) {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const PermissionCenterPage(),
                                  ),
                                );
                              }
                            },
                            child: const Text('去权限中心'),
                          ),
                        ],
                      ),
                    ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: SelectableText(
                        friendly,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.55,
                          color: Theme.of(ctx).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 工具返回 JSON → 中文人话。成功直接展示结果；失败给原因 + 处理；
  /// 解析失败兜底"操作完成/失败，原因：xx"。
  String _friendlyText(ToolEntry t, String raw) {
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      final isErr = raw.contains('error') || raw.contains('失败');
      return '${isErr ? '操作失败' : '操作完成'}，原因：$raw';
    }
    if (decoded is! Map<String, dynamic>) {
      return '操作完成：$raw';
    }
    final err = decoded['error'];
    if (err is String && err.isNotEmpty) {
      return '操作失败，原因：$err';
    }
    switch (t.id) {
      case NudgeApi.ping:
        return '连接正常，用户手机在线';
      case NudgeApi.getForegroundApp:
        final app =
            decoded['app_name']?.toString() ??
            decoded['package']?.toString() ??
            '未知应用';
        final dur = (decoded['duration_sec'] as num?)?.toInt() ?? 0;
        final buf = StringBuffer('她正在用「$app」');
        if (dur > 0) buf.write('，已停留 $dur 秒');
        final suggest = decoded['suggest']?.toString();
        if (suggest != null && suggest.isNotEmpty) buf.write('\n\n$suggest');
        return buf.toString();
      case NudgeApi.screenshotAnalyze:
        final desc =
            decoded['description']?.toString() ??
            decoded['text']?.toString() ??
            '';
        return desc.isEmpty ? '截图识别完成（没有识别到内容）' : '截图识别完成：\n$desc';
      case NudgeApi.cameraSnapshot:
        final camDesc = decoded['description']?.toString() ?? '';
        return camDesc.isEmpty ? '拍照识别完成（没有识别到内容）' : '拍照识别完成：\n$camDesc';
      case NudgeApi.sensorData:
        const names = {
          'accelerometer': '加速度',
          'light': '光线',
          'gyroscope': '陀螺仪',
          'proximity': '距离',
          'gravity': '重力',
          'magnetic': '磁场',
        };
        final keys = decoded.keys.where((k) => names.containsKey(k)).toList();
        if (keys.isEmpty) return '没读到传感器数据（传感器可能不可用）';
        final lines = keys.map((k) {
          final vals = (decoded[k] as List?)?.join('，') ?? '无';
          return '${names[k]}：$vals';
        });
        return '传感器读数：\n${lines.join('\n')}';
      case NudgeApi.deviceStatus:
        final battery = decoded['battery']?.toString() ?? '?';
        final locked = decoded['screen_locked'] == true ? '已锁屏' : '未锁屏';
        final charging = switch (decoded['charging']?.toString()) {
          'charging' => '充电中',
          'discharging' => '未充电',
          'full' => '已充满',
          _ => '充电状态未知',
        };
        final network = switch (decoded['network']?.toString()) {
          'wifi' => 'WiFi',
          'cellular' => '移动网络',
          'none' => '无网络',
          'other' => '其他网络',
          _ => '网络未知',
        };
        final buf = StringBuffer('电量 $battery%，$locked，$charging，$network');
        final suggest = decoded['suggest']?.toString();
        if (suggest != null && suggest.isNotEmpty) buf.write('\n\n$suggest');
        return buf.toString();
      case NudgeApi.getLocation:
        final lat = decoded['latitude']?.toString() ?? '';
        final lng = decoded['longitude']?.toString() ?? '';
        final addr = decoded['address']?.toString() ?? '';
        final acc = decoded['accuracy'] as num?;
        final accTxt = acc != null ? '，精度约 ±${acc.toStringAsFixed(0)} 米' : '';
        if (addr.isNotEmpty) {
          return '你在 $addr（$lat, $lng$accTxt）';
        }
        return '定位到：$lat, $lng$accTxt';
      case NudgeApi.getNotifications:
        final list = decoded['notifications'];
        if (list is! List || list.isEmpty) return '当前没有新通知';
        final lines = list
            .take(8)
            .map((n) {
              final m = n is Map ? n : const <String, dynamic>{};
              final title = m['title']?.toString() ?? '';
              final text = m['text']?.toString() ?? '';
              final app = m['app']?.toString() ?? '';
              final buf = StringBuffer();
              if (app.isNotEmpty) buf.write('[$app] ');
              if (title.isNotEmpty) buf.write(title);
              if (text.isNotEmpty && text != title) buf.write('：$text');
              return buf.toString().trim();
            })
            .where((line) => line.isNotEmpty)
            .toList();
        final total = (decoded['count'] as num?)?.toInt() ?? list.length;
        return lines.isEmpty
            ? '有 $total 条通知，但都是系统常驻通知（已过滤）'
            : '当前 $total 条通知：\n${lines.join('\n')}';
      case NudgeApi.getSteps:
        final steps = (decoded['steps'] as num?)?.toInt();
        if (steps == null) return '操作完成';
        if (steps <= 0) {
          final note = decoded['note']?.toString() ?? '请走几步后再试';
          return '今日 0 步（$note）';
        }
        return '今日已走 $steps 步';
      case NudgeApi.calendarQuery:
        final list = decoded['events'];
        if (list is! List || list.isEmpty) return '接下来 7 天没有日程安排';
        final lines = list.take(8).map((e) {
          final m = e is Map ? e : const <String, dynamic>{};
          final title = m['title']?.toString() ?? '（无标题）';
          final start = (m['start'] as num?)?.toInt() ?? 0;
          final t = start > 0
              ? _fmtTime(DateTime.fromMillisecondsSinceEpoch(start))
              : '';
          return t.isEmpty ? title : '$t  $title';
        });
        return '接下来 ${(decoded['count'] as num?)?.toInt() ?? list.length} 条日程：\n${lines.join('\n')}';
      case NudgeApi.calendarCreate:
        final created = decoded['success'] == true;
        if (!created) {
          return decoded['error']?.toString() ?? '建日程失败';
        }
        final title = decoded['title']?.toString() ?? '新日程';
        final start = (decoded['start'] as num?)?.toInt() ?? 0;
        final t = start > 0
            ? _fmtTime(DateTime.fromMillisecondsSinceEpoch(start))
            : '';
        return t.isEmpty ? '已建日程「$title」' : '已建日程「$title」：$t';
      case NudgeApi.setAlarm:
        final time = decoded['time']?.toString() ?? '';
        final title = decoded['title']?.toString() ?? '闹钟';
        final repeat = decoded['repeat']?.toString() == 'weekly'
            ? '（工作日重复）'
            : '（仅响一次）';
        return '已设 $time 闹钟「$title」$repeat';
      case NudgeApi.lockScreen:
        return '已锁屏';
      case NudgeApi.mediaPlayPause:
        return '已发送播放/暂停指令';
      case NudgeApi.mediaNext:
        return '已切到下一首';
      case NudgeApi.mediaPrevious:
        return '已切回上一首';
      case NudgeApi.pressBack:
        return '已按返回键';
      case NudgeApi.pressHome:
        return '已回桌面';
      case NudgeApi.openApp:
        final pkg = decoded['package']?.toString() ?? '';
        final method = decoded['method']?.toString() == 'desktop'
            ? '（桌面图标）'
            : '';
        return pkg.isEmpty ? '已打开应用$method' : '已打开「$pkg」$method';
      case NudgeApi.wakeUp:
        return '已唤醒屏幕';
      case NudgeApi.readScreen:
        final list = decoded['elements'];
        if (list is! List || list.isEmpty) return '当前屏幕没读到文字';
        final lines = list
            .take(10)
            .map((e) => e.toString())
            .where((line) => line.isNotEmpty);
        final count = (decoded['count'] as num?)?.toInt() ?? list.length;
        return '当前屏幕读到 $count 条文字：\n${lines.join('\n')}${list.length > 10 ? '\n…' : ''}';
      case NudgeApi.switchToContinuum:
        return '已切回Continuum Chat';
      default:
        return '操作完成';
    }
  }

  /// 时间戳（毫秒）→ "M月d日 HH:mm"。
  String _fmtTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.month}月${dt.day}日 ${two(dt.hour)}:${two(dt.minute)}';
  }
}
