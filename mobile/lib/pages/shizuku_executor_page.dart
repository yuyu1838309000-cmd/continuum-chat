import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/shizuku_executor_api.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// Manual-only UI for the Phase 1 Shizuku and virtual-display capability probe.
class ShizukuExecutorPage extends StatefulWidget {
  const ShizukuExecutorPage({super.key});

  @override
  State<ShizukuExecutorPage> createState() => _ShizukuExecutorPageState();
}

class _ShizukuExecutorPageState extends State<ShizukuExecutorPage> {
  final _packageController = TextEditingController();
  ShizukuExecutorStatus? _status;
  VirtualDisplayProbeResult? _probeResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _packageController.dispose();
    unawaited(ShizukuExecutorApi.closeProbe());
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await ShizukuExecutorApi.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _requestPermission() async {
    if (_busy) return;
    setState(() => _busy = true);
    final status = await ShizukuExecutorApi.requestPermission();
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
    });
  }

  Future<void> _probe() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _probeResult = null;
    });
    final result = await ShizukuExecutorApi.probeVirtualDisplay(
      packageName: _packageController.text,
    );
    final status = await ShizukuExecutorApi.status();
    if (!mounted) return;
    setState(() {
      _probeResult = result;
      _status = status;
      _busy = false;
    });
  }

  Future<void> _closeProbe() async {
    if (_busy) return;
    setState(() => _busy = true);
    await ShizukuExecutorApi.closeProbe();
    final status = await ShizukuExecutorApi.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shizuku 手机执行器'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(LucideIcons.refresh_cw),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(
          top: AppSpacing.xs,
          bottom: AppSpacing.xl,
        ),
        children: [
          const AppSectionLabel('运行状态', compact: true),
          SettingCard(
            child: status == null
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _statusContent(status),
          ),
          const AppSectionLabel('虚拟第二屏'),
          SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _packageController,
                  enabled: !_busy && status?.probeActive != true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: '目标包名（可选）',
                    hintText: VirtualDisplayProbeResult.defaultTargetPackage,
                    helperText: '留空打开系统设置；实机可手动输入 com.taobao.taobao',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed:
                      _busy ||
                          status?.authorized != true ||
                          status?.probeActive == true
                      ? null
                      : _probe,
                  icon: const Icon(LucideIcons.play),
                  label: Text(_busy ? '正在等待 frame…' : '测试第二屏'),
                ),
                if (status?.probeActive == true) ...[
                  const SizedBox(height: AppSpacing.xs),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _closeProbe,
                    icon: const Icon(LucideIcons.x),
                    label: const Text('关闭并销毁第二屏'),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '仅在本机内存中检查是否收到 frame，不保存、打印或上传画面。'
                  '新版 Android 仍可能因第二屏安全策略拒绝外部 App。',
                  style: TextStyle(
                    height: 1.5,
                    fontSize: AppType.caption,
                    color: context.semanticColors.mutedText,
                  ),
                ),
              ],
            ),
          ),
          if (_probeResult case final result?) ...[
            const AppSectionLabel('本次结果'),
            SettingCard(child: _probeContent(result)),
          ],
        ],
      ),
    );
  }

  Widget _statusContent(ShizukuExecutorStatus status) {
    final identity = switch (status.serverMode) {
      'shell' => 'shell（ADB 正常模式）',
      'root' => 'root',
      _ => status.serverMode,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _valueRow('服务', status.binderAvailable ? '已运行' : '未连接'),
        _valueRow('授权', status.authorized ? '已授权' : '未授权'),
        if (status.binderAvailable) _valueRow('执行身份', identity),
        if (status.apiVersion case final version?)
          _valueRow('API', 'v$version'),
        if (status.error case final error?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ] else if (status.permissionBlocked) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '请在 Shizuku 的已授权应用中重新允许Continuum Chat。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (!status.authorized) ...[
          const SizedBox(height: AppSpacing.md),
          FilledButton(
            onPressed: _busy || !status.canRequestPermission
                ? null
                : _requestPermission,
            child: Text(
              status.binderAvailable ? '请求 Shizuku 授权' : '请先启动 Shizuku',
            ),
          ),
        ],
      ],
    );
  }

  Widget _probeContent(VirtualDisplayProbeResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _valueRow('displayId', result.displayId?.toString() ?? '未创建'),
        _valueRow('目标包', result.targetPackage),
        _valueRow('本次结论', result.passed ? 'PASS' : 'FAIL'),
        _valueRow('路由核验', result.routingVerified ? 'PASS' : 'FAIL'),
        _valueRow('物理主屏被占用', result.mainDisplayStolen ? '是' : '否'),
        _valueRow('收到 frame', result.frameReceived ? '是' : '否'),
        _valueRow(
          'frame 尺寸',
          result.frameReceived
              ? '${result.frameWidth} × ${result.frameHeight}'
              : '—',
        ),
        _valueRow('迁移结果', _relocationLabel(result.relocation)),
        _valueRow('启动前主屏', _mainDisplaySummary(result, before: true)),
        _valueRow('稳定后主屏', _mainDisplaySummary(result, before: false)),
        if (result.targetTasks.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '目标包 task/activity',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final task in result.targetTasks)
            Text(
              'task ${task.taskId} / root ${task.rootTaskId} / '
              'display ${task.displayId}${task.active ? ' / active' : ''}\n'
              '${task.component}',
              style: TextStyle(
                height: 1.4,
                fontSize: AppType.caption,
                color: context.semanticColors.mutedText,
              ),
            ),
        ],
        if (result.relocationDetail case final detail?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            detail,
            style: TextStyle(color: context.semanticColors.mutedText),
          ),
        ],
        if (result.error case final error?) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  String _mainDisplaySummary(
    VirtualDisplayProbeResult result, {
    required bool before,
  }) {
    final values = before
        ? [
            result.preMainTopActivity,
            result.preMainResumedActivity,
            result.preMainFocusedActivity,
          ]
        : [
            result.postMainTopActivity,
            result.postMainResumedActivity,
            result.postMainFocusedActivity,
          ];
    final unique = values.whereType<String>().toSet();
    return unique.isEmpty ? '未解析' : unique.join('\n');
  }

  String _relocationLabel(String value) => switch (value) {
    'not_needed' => '无需迁移',
    'moved' => '已迁移并复核',
    'unsupported' => '设备不支持',
    'unsafe' => '安全条件不满足',
    'failed' => '迁移失败',
    _ => '未尝试',
  };

  Widget _valueRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: TextStyle(color: context.semanticColors.mutedText),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
