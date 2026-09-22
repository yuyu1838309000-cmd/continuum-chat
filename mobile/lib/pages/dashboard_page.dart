import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:http/http.dart' as http;
import '../services/chat_api.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';

/// 服务器仪表盘（阶段四 · 面板工具）：
/// - 真调 8816 GET /status → system 字段（内存/磁盘/CPU/关键服务端口）
/// - 卡片风格照工具箱：圆角 20 + 柔和阴影 + surface 底 + Lucide 图标
/// - 下拉刷新 + 手动刷新 + 30 秒自动刷新，更新时间小字
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  static String get _statusUrl => ServerConfig.url(8816, '/status');

  Map<String, dynamic>? _system;
  String? _error;
  String? _staleError;
  bool _loading = true;
  Timer? _timer;
  int _refreshRequestId = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (silent && _loading) return;
    final requestId = ++_refreshRequestId;
    if (!silent) {
      setState(() {
        _loading = true;
        if (_system == null) _error = null;
      });
    }
    Map<String, dynamic>? nextSystem;
    String? failure;
    try {
      final resp = await http
          .get(Uri.parse(_statusUrl), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final sys = decoded is Map<String, dynamic> ? decoded['system'] : null;
        if (sys is Map<String, dynamic>) {
          nextSystem = sys;
        } else {
          failure = '状态接口数据异常';
        }
      } else {
        failure = '状态接口异常（${resp.statusCode}）';
      }
    } on FormatException {
      failure = '状态接口数据异常';
    } catch (e) {
      failure = '连不上服务器：$e';
    }
    if (!mounted || requestId != _refreshRequestId) return;
    setState(() {
      _loading = false;
      if (nextSystem != null) {
        _system = nextSystem;
        _error = null;
        _staleError = null;
      } else if (_system != null) {
        _error = null;
        _staleError = failure ?? '刷新失败';
      } else {
        _error = failure ?? '刷新失败';
        _staleError = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器状态'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _refresh(),
            icon: const Icon(LucideIcons.refresh_cw, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(theme, context.cardShadow),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, BoxShadow cardShadow) {
    if (_loading && _system == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _system == null) {
      return _ErrorView(message: _error!, onRetry: _refresh);
    }
    final sys = _system!;
    final mem = (sys['memory'] as Map?) ?? {};
    final disk = (sys['disk'] as Map?) ?? {};
    final cpu = (sys['cpu'] as Map?) ?? {};
    final ports = (sys['ports'] as List?) ?? [];
    final ts = sys['ts']?.toString() ?? '';

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _loading
                    ? '刷新中…'
                    : _staleError != null
                    ? '刷新失败，显示旧数据 · 更新于 ${_fmtTs(ts)}'
                    : '更新于 ${_fmtTs(ts)}',
                style: TextStyle(
                  fontSize: 12,
                  color: _staleError == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
              if (_staleError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _staleError!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),

        // 内存
        _MetricCard(
          icon: LucideIcons.memory_stick,
          title: '内存',
          shadow: cardShadow,
          child: _buildMetric(
            theme,
            usedText: '${mem['used_mb'] ?? '-'} MB',
            totalText: '共 ${mem['total_mb'] ?? '-'} MB',
            percent: ((mem['percent'] as num?) ?? 0).toDouble(),
            extra: '可用 ${mem['avail_mb'] ?? '-'} MB',
          ),
        ),

        // 磁盘
        _MetricCard(
          icon: LucideIcons.hard_drive,
          title: '磁盘',
          shadow: cardShadow,
          child: _buildMetric(
            theme,
            usedText: '${disk['used_gb'] ?? '-'} GB',
            totalText: '共 ${disk['total_gb'] ?? '-'} GB',
            percent: ((disk['percent'] as num?) ?? 0).toDouble(),
            extra: '可用 ${disk['free_gb'] ?? '-'} GB',
          ),
        ),

        // CPU
        _MetricCard(
          icon: LucideIcons.cpu,
          title: 'CPU',
          shadow: cardShadow,
          child: _buildMetric(
            theme,
            usedText: '${cpu['percent'] ?? '-'}%',
            totalText: '${cpu['cores'] ?? '-'} 核',
            percent: ((cpu['percent'] as num?) ?? 0).toDouble(),
            extra:
                '负载 ${cpu['load1'] ?? '-'} / ${cpu['load5'] ?? '-'} / ${cpu['load15'] ?? '-'}',
          ),
        ),

        // 服务状态
        _MetricCard(
          icon: LucideIcons.server,
          title: '服务状态',
          shadow: cardShadow,
          child: Column(
            children: [
              for (final p in ports)
                if (p is Map)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p['alive'] == true
                                ? context.successColor
                                : context.dangerColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            p['name']?.toString() ?? '',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        Text(
                          p['alive'] == true ? '正常' : '离线',
                          style: TextStyle(
                            fontSize: 12,
                            color: p['alive'] == true
                                ? context.successColor
                                : context.dangerColor,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 进度条式指标：已用 + 共 + 进度条 + 可用小字
  Widget _buildMetric(
    ThemeData theme, {
    required String usedText,
    required String totalText,
    required double percent,
    required String extra,
  }) {
    final pct = percent.clamp(0, 100);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              usedText,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                totalText,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct / 100,
            minHeight: 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          extra,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _fmtTs(String iso) {
    if (iso.length < 19) return iso;
    // "2026-08-08T13:04:20.040421+08:00" → "13:04:20"
    final t = iso.substring(11, 19);
    return t;
  }
}

/// 指标卡片外壳：圆角 20 + 柔和阴影 + surface 底 + 图标标题
class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  final BoxShadow shadow;

  const _MetricCard({
    required this.icon,
    required this.title,
    required this.child,
    required this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [shadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.server_off,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refresh_cw, size: 16),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
