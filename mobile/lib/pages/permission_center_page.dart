import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import '../services/permission_center.dart';
import '../services/shizuku_executor_api.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'shizuku_executor_page.dart';

/// 权限中心页：运行时权限 / 系统特殊权限 / 小米 HyperOS 手动设置。
/// 样式：基准简洁卡片（圆角 20 + cardShadow + cardColor + 左 Icon 24 + 标题 15 w600 +
/// 右侧状态（色点 + 已授权/未授权/手动设置）+ chevron，无解释小字，design-guide v0.2.92 基准）。
/// 状态实时刷新：页面回到前台（AppLifecycleState.resumed）时重新检查全部，不缓存。
/// 点击行为：未授权 → 申请权限 / 跳系统设置；已授权 → 跳应用详情（可查看/收回）。
/// 小米 HyperOS 项无法代码检测，点击展开手动设置步骤。
class PermissionCenterPage extends StatefulWidget {
  const PermissionCenterPage({super.key});

  @override
  State<PermissionCenterPage> createState() => _PermissionCenterPageState();
}

class _PermissionCenterPageState extends State<PermissionCenterPage>
    with WidgetsBindingObserver {
  /// 运行时权限状态：key = 逻辑 id（notifications/location/calendar/activity/alarm/storage）。
  final Map<String, bool> _runtime = {};

  /// 系统特殊权限状态：key = PermissionCenter 类型常量。
  final Map<String, bool> _special = {};

  /// 小米手动项展开集合。
  final Set<String> _expanded = {};

  ShizukuExecutorStatus? _shizukuStatus;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 页面回到前台（从系统设置/权限弹窗返回）→ 重新检查全部状态。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    try {
      final media = await PermissionCenter.mediaPermissions();
      final shizukuStatus = await ShizukuExecutorApi.status();
      final results = await Future.wait([
        PermissionCenter.allGranted([PermissionCenter.permNotifications]),
        PermissionCenter.allGranted([
          PermissionCenter.permFineLocation,
          PermissionCenter.permCoarseLocation,
        ]),
        PermissionCenter.allGranted([
          PermissionCenter.permCalendar,
          PermissionCenter.permCalendarWrite,
        ]),
        PermissionCenter.allGranted([PermissionCenter.permActivityRecognition]),
        PermissionCenter.checkSpecial(PermissionCenter.exactAlarm),
        PermissionCenter.allGranted(media),
        PermissionCenter.allGranted([PermissionCenter.permMicrophone]),
        PermissionCenter.allGranted([PermissionCenter.permCamera]),
        PermissionCenter.checkSpecial(PermissionCenter.bluetooth),
        PermissionCenter.checkSpecial(PermissionCenter.installUnknown),
        PermissionCenter.checkSpecial(PermissionCenter.overlay),
        PermissionCenter.checkSpecial(PermissionCenter.notifListener),
        PermissionCenter.checkSpecial(PermissionCenter.accessibility),
        PermissionCenter.checkSpecial(PermissionCenter.usageStats),
      ]);
      if (!mounted) return;
      setState(() {
        _runtime
          ..['notifications'] = results[0]
          ..['location'] = results[1]
          ..['calendar'] = results[2]
          ..['activity'] = results[3]
          ..['alarm'] = results[4]
          ..['storage'] = results[5]
          ..['microphone'] = results[6]
          ..['camera'] = results[7]
          ..['bluetooth'] = results[8];
        _special
          ..[PermissionCenter.installUnknown] = results[9]
          ..[PermissionCenter.overlay] = results[10]
          ..[PermissionCenter.notifListener] = results[11]
          ..[PermissionCenter.accessibility] = results[12]
          ..[PermissionCenter.usageStats] = results[13];
        _shizukuStatus = shizukuStatus;
        _loading = false;
      });
    } catch (_) {
      // 平台通道异常（极老系统等）：保持空状态可看列表，不阻塞页面
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// 申请运行时权限（通知/定位/日历/活动识别/存储），完成后单行刷新。
  Future<void> _requestRuntime(String id, List<String> permissions) async {
    final result = await PermissionCenter.request(permissions);
    if (!mounted) return;
    setState(() => _runtime[id] = permissions.every((p) => result[p] == true));
  }

  /// 跳系统设置（特殊权限/精确闹钟/应用详情），失败提示。
  Future<void> _openSettings(String type) async {
    final ok = await PermissionCenter.openSettings(type);
    if (!ok && mounted) _toast('无法打开系统设置');
  }

  /// 运行时权限行点击：未授权 → 申请；已授权 → 应用详情（可查看/收回）。
  void _onRuntimeTap(String id, List<String> permissions) {
    if (_runtime[id] == true) {
      _openSettings(PermissionCenter.appDetails);
    } else {
      _requestRuntime(id, permissions);
    }
  }

  /// 系统特殊权限行点击：未授权 → 对应设置页；已授权 → 应用详情。
  void _onSpecialTap(String type) {
    _openSettings(_special[type] == true ? PermissionCenter.appDetails : type);
  }

  /// 闹钟行点击：未授权 → 精确闹钟授权页；已授权 → 应用详情。
  void _onAlarmTap() {
    _openSettings(
      _runtime['alarm'] == true
          ? PermissionCenter.appDetails
          : PermissionCenter.exactAlarm,
    );
  }

  /// 存储行点击：未授权 → 先按 SDK 解析媒体权限（13+ 三分 / 12 及以下单权限）再申请；
  /// 已授权 → 应用详情。
  Future<void> _onStorageTap() async {
    if (_runtime['storage'] == true) {
      _openSettings(PermissionCenter.appDetails);
      return;
    }
    final media = await PermissionCenter.mediaPermissions();
    if (!mounted) return;
    final result = await PermissionCenter.request(media);
    if (!mounted) return;
    setState(() => _runtime['storage'] = media.every((p) => result[p] == true));
  }

  /// 蓝牙行点击：已授权 → 应用详情；未授权（仅 Android 12+ 可能）→ 运行时申请。
  Future<void> _onBluetoothTap() async {
    if (_runtime['bluetooth'] == true) {
      _openSettings(PermissionCenter.appDetails);
      return;
    }
    final result = await PermissionCenter.request([
      PermissionCenter.permBluetoothConnect,
    ]);
    if (!mounted) return;
    setState(
      () => _runtime['bluetooth'] =
          result[PermissionCenter.permBluetoothConnect] == true,
    );
  }

  void _toggleManual(String id) {
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
  }

  Future<void> _openShizukuExecutor() async {
    await Navigator.of(
      context,
    ).push(SwipeBackRoute(builder: (_) => const ShizukuExecutorPage()));
    if (mounted) _refresh();
  }

  void _toast(String msg) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 13)),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          backgroundColor: theme.colorScheme.inverseSurface,
          margin: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          elevation: 0,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('权限中心')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // ── 运行时权限 ──
                _groupTitle('运行时权限'),
                _runtimeRow(
                  icon: LucideIcons.bell,
                  title: '通知',
                  id: 'notifications',
                  permissions: [PermissionCenter.permNotifications],
                ),
                const SizedBox(height: 16),
                _runtimeRow(
                  icon: LucideIcons.map_pin,
                  title: '定位',
                  id: 'location',
                  permissions: [
                    PermissionCenter.permFineLocation,
                    PermissionCenter.permCoarseLocation,
                  ],
                ),
                const SizedBox(height: 16),
                _runtimeRow(
                  icon: LucideIcons.calendar,
                  title: '日历',
                  id: 'calendar',
                  permissions: [
                    PermissionCenter.permCalendar,
                    PermissionCenter.permCalendarWrite,
                  ],
                ),
                const SizedBox(height: 16),
                _runtimeRow(
                  icon: LucideIcons.footprints,
                  title: '活动识别',
                  id: 'activity',
                  permissions: [PermissionCenter.permActivityRecognition],
                ),
                const SizedBox(height: 16),
                _rowCard(
                  icon: LucideIcons.alarm_clock,
                  title: '闹钟',
                  granted: _runtime['alarm'],
                  onTap: _onAlarmTap,
                ),
                const SizedBox(height: 16),
                _rowCard(
                  icon: LucideIcons.folder,
                  title: '存储',
                  granted: _runtime['storage'],
                  onTap: _onStorageTap,
                ),
                const SizedBox(height: 16),
                _runtimeRow(
                  icon: LucideIcons.mic,
                  title: '麦克风',
                  id: 'microphone',
                  permissions: [PermissionCenter.permMicrophone],
                ),
                const SizedBox(height: 16),
                _runtimeRow(
                  icon: LucideIcons.camera,
                  title: '相机',
                  id: 'camera',
                  permissions: [PermissionCenter.permCamera],
                ),
                const SizedBox(height: 16),
                _rowCard(
                  icon: LucideIcons.bluetooth,
                  title: '蓝牙',
                  granted: _runtime['bluetooth'],
                  onTap: _onBluetoothTap,
                ),
                const SizedBox(height: 16),
                _rowCard(
                  icon: LucideIcons.vibrate,
                  title: '震动',
                  granted: true,
                  statusOverride: '已内置',
                  onTap: () => _openSettings(PermissionCenter.appDetails),
                ),
                // ── 系统特殊权限 ──
                _groupTitle('系统特殊权限'),
                _specialRow(
                  icon: LucideIcons.package,
                  title: '安装未知应用',
                  type: PermissionCenter.installUnknown,
                ),
                const SizedBox(height: 16),
                _specialRow(
                  icon: LucideIcons.picture_in_picture,
                  title: '悬浮窗',
                  type: PermissionCenter.overlay,
                ),
                const SizedBox(height: 16),
                _specialRow(
                  icon: LucideIcons.radio,
                  title: '通知使用权',
                  type: PermissionCenter.notifListener,
                ),
                const SizedBox(height: 16),
                _specialRow(
                  icon: LucideIcons.accessibility,
                  title: '无障碍服务',
                  type: PermissionCenter.accessibility,
                ),
                const SizedBox(height: 16),
                _specialRow(
                  icon: LucideIcons.chart_no_axes_combined,
                  title: '使用情况统计',
                  type: PermissionCenter.usageStats,
                ),
                const SizedBox(height: 16),
                _rowCard(
                  icon: LucideIcons.smartphone,
                  title: 'Shizuku 手机执行器（实验）',
                  granted: _shizukuStatus?.authorized,
                  statusOverride: _shizukuStatus?.binderAvailable != true
                      ? '未运行'
                      : _shizukuStatus?.authorized == true
                      ? '已授权'
                      : '待授权',
                  onTap: _openShizukuExecutor,
                ),
                // ── 小米 HyperOS 手动设置 ──
                _groupTitle('小米 HyperOS 手动设置'),
                _manualRow(
                  icon: LucideIcons.rocket,
                  title: '自启动',
                  id: 'auto_start',
                  steps: '设置 → 应用管理 → Continuum Chat → 自启动 → 开',
                ),
                const SizedBox(height: 16),
                _manualRow(
                  icon: LucideIcons.battery_charging,
                  title: '省电策略',
                  id: 'battery',
                  steps: '设置 → 省电与电池 → 省电策略 → Continuum Chat → 无限制（保活关键）',
                ),
                const SizedBox(height: 16),
                _manualRow(
                  icon: LucideIcons.layers,
                  title: '后台弹出界面',
                  id: 'background_popup',
                  steps: '设置 → 应用管理 → Continuum Chat → 后台弹出界面 → 允许',
                ),
                const SizedBox(height: 16),
                _manualRow(
                  icon: LucideIcons.lock,
                  title: '多任务锁定',
                  id: 'task_lock',
                  steps: '最近任务 → 长按Continuum Chat卡片 → 锁定',
                ),
              ],
            ),
    );
  }

  /// 运行时权限行：状态实时查，点击申请/跳应用详情。
  Widget _runtimeRow({
    required IconData icon,
    required String title,
    required String id,
    required List<String> permissions,
  }) {
    return _rowCard(
      icon: icon,
      title: title,
      granted: _runtime[id],
      onTap: () => _onRuntimeTap(id, permissions),
    );
  }

  /// 系统特殊权限行：点击跳对应设置页/应用详情。
  Widget _specialRow({
    required IconData icon,
    required String title,
    required String type,
  }) {
    return _rowCard(
      icon: icon,
      title: title,
      granted: _special[type],
      onTap: () => _onSpecialTap(type),
    );
  }

  /// 基准简洁卡片行：圆角 20 + cardShadow + cardColor + 左 Icon 24 + 标题 15 w600 +
  /// 右侧状态（色点 + 已授权/未授权）+ chevron 22，无解释小字。
  Widget _rowCard({
    required IconData icon,
    required String title,
    required bool? granted,
    required VoidCallback onTap,
    String? statusOverride,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _status(granted == true, statusOverride),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevron_right,
                  size: 22,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 状态标识：色点（已授权=success / 未授权=灰）+ 文字 12px 次级色。
  /// statusOverride 非空时优先显示固定文案（如震动"已内置"）。
  Widget _status(bool granted, [String? statusOverride]) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: granted
                ? context.successColor
                : context.subTextColor.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          statusOverride ?? (granted ? '已授权' : '未授权'),
          style: TextStyle(fontSize: 12, color: context.subTextColor),
        ),
      ],
    );
  }

  /// 小米手动设置行：状态"手动设置"，点击展开步骤说明（AnimatedSize 200ms）。
  Widget _manualRow({
    required IconData icon,
    required String title,
    required String id,
    required String steps,
  }) {
    final expanded = _expanded.contains(id);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            InkWell(
              onTap: () => _toggleManual(id),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 24,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '手动设置',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.subTextColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      expanded
                          ? LucideIcons.chevron_down
                          : LucideIcons.chevron_right,
                      size: 22,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(54, 0, 16, 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          steps,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: context.subTextColor,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// 分组标题：12px 次级色小字。
  Widget _groupTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: context.subTextColor),
      ),
    );
  }
}
