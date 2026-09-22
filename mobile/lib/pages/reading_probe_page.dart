import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/reading_probe_api.dart';
import '../utils/app_theme.dart';

/// 共读 2.0 的 Android 技术探针。
///
/// 手动开启后，AccessibilityService 在Continuum Chat退到后台时本地采样外部阅读 App；
/// 回到本页只查看结果。不会上传正文，也不会调用AI 助手/模型。
class ReadingProbePage extends StatefulWidget {
  const ReadingProbePage({super.key});

  @override
  State<ReadingProbePage> createState() => _ReadingProbePageState();
}

class _ReadingProbePageState extends State<ReadingProbePage>
    with WidgetsBindingObserver {
  Map<String, dynamic> _state = const {};
  bool _loading = true;
  bool _busy = false;
  String _error = '';

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(showLoading: false);
  }

  Future<void> _refresh({bool showLoading = true}) async {
    if (showLoading && mounted) setState(() => _loading = true);
    final next = await ReadingProbeApi.state();
    if (!mounted) return;
    setState(() {
      _state = next;
      _loading = false;
      _error = next.isEmpty ? '读取探针状态失败' : '';
    });
  }

  Future<void> _toggle(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = await ReadingProbeApi.setEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _state = next;
      _busy = false;
      _error = next.isEmpty ? '切换探针失败' : '';
    });
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = await ReadingProbeApi.clear();
    if (!mounted) return;
    setState(() {
      _state = next;
      _busy = false;
      _error = next.isEmpty ? '清空探针失败' : '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('共读探针'),
          centerTitle: false,
          elevation: 0,
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _busy ? null : () => _refresh(showLoading: false),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final enabled = _state['enabled'] == true;
    final running = _state['accessibility_running'] == true;
    final events = _maps(_state['events']);
    final failures = _maps(_state['failures']);
    final latest = _latestCapture(_state['attempts']);
    return RefreshIndicator(
      onRefresh: () => _refresh(showLoading: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _panel(
            theme,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('记录外部阅读现场'),
                    subtitle: Text(running ? '无障碍服务已连接' : '无障碍服务未连接，先到权限中心开启'),
                    value: enabled,
                    onChanged: _busy ? null : _toggle,
                  ),
                ),
                Text(
                  '只保存在这台手机的 App 私有目录，不上传服务器，也不会调用模型。',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _instructionPanel(theme, enabled),
          if (enabled) ...[const SizedBox(height: 12), _diagnosticPanel(theme)],
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_error, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 20),
          _sectionTitle(theme, '最近捕获'),
          _latestPanel(theme, latest),
          const SizedBox(height: 20),
          _sectionTitle(theme, '最近变化'),
          _historyPanel(theme, events, failures),
        ],
      ),
    );
  }

  Widget _diagnosticPanel(ThemeData theme) {
    final diagnostic = _state['probe_diagnostic']?.toString() ?? '';
    final diagnosticTs = _milliseconds(_state['probe_diagnostic_ts']);
    final foreground = _state['poll_foreground_package']?.toString() ?? '';
    final currentPackage = _state['current_package']?.toString() ?? '';
    final accessibilityRunning = _state['accessibility_running'] == true;
    return _panel(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '轮询诊断',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          _kv('probe_diagnostic', _diagnosticLabel(diagnostic)),
          _kv(
            'poll_foreground_package',
            foreground.isEmpty ? '未取得' : foreground,
          ),
          _kv(
            'probe_diagnostic_ts',
            diagnosticTs <= 0 ? '等待首次轮询' : _dateTime(diagnosticTs),
          ),
          _kv(
            'current_package',
            currentPackage.isEmpty ? '未取得' : currentPackage,
          ),
          _kv('accessibility_running', accessibilityRunning ? '是' : '否'),
        ],
      ),
    );
  }

  Widget _instructionPanel(ThemeData theme, bool enabled) {
    return _panel(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            enabled ? '现在切去晋江或长佩，正常翻几页。' : '先打开上面的记录开关。',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            '翻页后回到这里会自动刷新。截图与 bundled 中文 OCR 全程在本机完成，只保留私有缓存预览和 capped 文本。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _busy ? null : _clear,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: const Text('清空本轮记录'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _latestPanel(ThemeData theme, Map<String, dynamic> latest) {
    if (latest.isEmpty) {
      return _panel(
        theme,
        child: Text(
          '还没捕获到外部页面',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
        ),
      );
    }
    final eventPackage = latest['event_package']?.toString() ?? '';
    final rootPackage = latest['root_package']?.toString() ?? '';
    final packageMatch = latest['package_match'] == true;
    final elements = _maps(latest['elements']);
    final previewPath = latest['preview_path']?.toString() ?? '';
    final ocrText = latest['ocr_text']?.toString() ?? '';
    final ocrError = latest['ocr_error']?.toString() ?? '';
    return _panel(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('应用', '${latest['app'] ?? ''}  $eventPackage'),
          _kv('事件包名', eventPackage),
          _kv('Root 包名', rootPackage.isEmpty ? '未取得' : rootPackage),
          _kv('包名校验', packageMatch ? 'MATCH' : 'MISMATCH'),
          _kv('页面类', latest['class_name']?.toString() ?? ''),
          _kv('事件', latest['event_name']?.toString() ?? ''),
          _kv('状态', _status(latest)),
          if (latest.containsKey('node_count'))
            _kv(
              '节点',
              '${latest['node_count'] ?? 0} 个；文字 ${latest['text_node_count'] ?? 0} 个；可见 ${latest['visible_text_count'] ?? 0} 个',
            ),
          _kv('截屏', latest['screenshot_ok'] == true ? '已保存本地预览' : '未得到有效截图'),
          if (latest['screenshot_ok'] == true)
            _kv(
              '本机 OCR',
              '${latest['ocr_char_count'] ?? 0} 字符'
                  '${latest['ocr_truncated'] == true ? '（已截断保存）' : ''}',
            ),
          _kv('页面指纹', latest['page_fingerprint']?.toString() ?? ''),
          if ((latest['error']?.toString() ?? '').isNotEmpty)
            _kv('采样错误', latest['error'].toString()),
          if (ocrError.isNotEmpty) _kv('OCR 错误', ocrError),
          if (previewPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Image.file(
                File(previewPath),
                fit: BoxFit.fitWidth,
                errorBuilder: (_, _, _) => Text(
                  '本地预览已不可用：$previewPath',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ],
          if (ocrText.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              '本机 OCR 文本',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              ocrText,
              style: const TextStyle(fontSize: 13, height: 1.55),
            ),
          ],
          if (elements.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              '当前可读文字节点',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              elements
                  .take(80)
                  .map((e) {
                    final visible = e['visible'] == true ? '可见' : '隐藏';
                    final bounds = e['bounds']?.toString() ?? '';
                    return '[${e['index'] ?? ''}] $visible $bounds\n${e['text'] ?? ''}';
                  })
                  .join('\n\n'),
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyPanel(
    ThemeData theme,
    List<Map<String, dynamic>> events,
    List<Map<String, dynamic>> failures,
  ) {
    final records = [
      ...events,
      ...failures,
    ]..sort((a, b) => _milliseconds(b['ts']).compareTo(_milliseconds(a['ts'])));
    if (records.isEmpty) {
      return _panel(
        theme,
        child: Text(
          '翻页后这里会出现页面指纹和新增/消失文字数量。',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
        ),
      );
    }
    final recent = records.take(8).toList();
    return _panel(
      theme,
      child: Column(
        children: [
          for (var i = 0; i < recent.length; i++) ...[
            if (i > 0) const Divider(height: 24),
            _historyRow(theme, recent[i]),
          ],
        ],
      ),
    );
  }

  Widget _historyRow(ThemeData theme, Map<String, dynamic> event) {
    final added = _list(event['added']).length;
    final removed = _list(event['removed']).length;
    final packageMatch = event['package_match'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${event['app'] ?? event['package'] ?? ''}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              _time(event['ts']),
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${packageMatch ? 'MATCH' : 'MISMATCH'} · ${_status(event)}'
          '${event.containsKey('text_node_count') ? ' · OCR ${event['ocr_char_count'] ?? 0} 字 · 节点文字 ${event['text_node_count'] ?? 0} · +$added / -$removed' : ''}'
          '${(event['page_fingerprint']?.toString() ?? '').isNotEmpty ? ' · ${event['page_fingerprint']}' : ''}',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurface,
      ),
    ),
  );

  Widget _panel(ThemeData theme, {required Widget child}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(AppRadius.md),
      boxShadow: [context.cardShadow],
    ),
    child: child,
  );

  Widget _kv(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 12, height: 1.45),
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map) return const {};
    return value.map((k, v) => MapEntry(k.toString(), v));
  }

  static List<dynamic> _list(Object? value) => value is List ? value : const [];

  static List<Map<String, dynamic>> _maps(Object? value) =>
      _list(value).whereType<Map>().map((e) => _map(e)).toList();

  static Map<String, dynamic> _latestCapture(Object? value) {
    final captures = _map(
      value,
    ).values.map(_map).where((e) => e.isNotEmpty).toList();
    if (captures.isEmpty) return const {};
    captures.sort(
      (a, b) => _milliseconds(b['ts']).compareTo(_milliseconds(a['ts'])),
    );
    return captures.first;
  }

  static String _status(Map<String, dynamic> capture) {
    final status = capture['status']?.toString() ?? '';
    return switch (status) {
      'ocr_ok' => '截图成功，OCR 完成',
      'ocr_empty' => '截图成功，OCR 结果为空',
      'duplicate' => '与上一有效页面相同，未新增记录',
      'failed' => '失败：${capture['stage'] ?? ''} / ${capture['error'] ?? ''}',
      _ => status.isEmpty ? '等待结果' : status,
    };
  }

  static String _diagnosticLabel(String diagnostic) {
    final translated = switch (diagnostic) {
      'usage_stats_ok' => 'UsageStats 正常',
      'usage_stats_denied' => 'UsageStats 权限未授权',
      'usage_stats_no_result' => 'UsageStats 暂无前台应用结果',
      'usage_stats_unavailable' => 'UsageStats 服务不可用',
      _ when diagnostic.startsWith('usage_stats_error:') =>
        'UsageStats 查询异常：${diagnostic.substring('usage_stats_error:'.length)}',
      _ => diagnostic.isEmpty ? '等待首次轮询' : diagnostic,
    };
    return diagnostic.isEmpty ? translated : '$translated（$diagnostic）';
  }

  static int _milliseconds(Object? raw) =>
      raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;

  static String _time(Object? raw) {
    final ms = _milliseconds(raw);
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String _dateTime(int milliseconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
