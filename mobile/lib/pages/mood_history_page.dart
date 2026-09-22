import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/mood.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/memory_ui.dart';

/// Continuum Chat 情绪记录列表页（记忆面板「情绪」区块 → 点开看全部）。
/// 数据：GET 8820 /mood/history?limit=20（全部 mood 事件，created_at 倒序）。
/// 风格：跟记忆面板一致——淡粉蓝底 + 干净卡片（不磨砂）+ 主色点缀。
class MoodHistoryPage extends StatefulWidget {
  const MoodHistoryPage({super.key});

  @override
  State<MoodHistoryPage> createState() => _MoodHistoryPageState();
}

class _MoodHistoryPageState extends State<MoodHistoryPage> {
  List<MoodEntry>? _moods;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），过期/无缓存才静默拉新；
  /// 下拉刷新/重试走 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    final url = ServerConfig.url(8820, '/mood/history?limit=20');
    if (!force && _moods == null) {
      final cached = await ApiCache.read(url);
      final cachedMoods = _parseMoods(cached);
      if (!mounted) return;
      if (cachedMoods != null) {
        setState(() {
          _moods = cachedMoods;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _moods == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      timeout: const Duration(seconds: 8),
    );
    final moods = _parseMoods(raw);
    if (!mounted) return;
    setState(() {
      if (moods != null) _moods = moods;
      _loading = false;
      _error = _moods == null;
    });
  }

  static List<MoodEntry>? _parseMoods(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic> && e['id'] != null) MoodEntry.fromJson(e),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            color: memAccentOf(context),
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_error) {
      return _errorState(context);
    }
    final moods = _moods ?? const <MoodEntry>[];
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      color: memAccentOf(context),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
        children: [
          Row(
            children: [
              _backButton(context),
              const SizedBox(width: 14),
              Text('情绪记录', style: memPx(24, memTextOf(context), height: 1)),
            ],
          ),
          const SizedBox(height: 28),
          memCleanCard(
            context: context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (moods.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '还没有情绪记录',
                      style: memBody(
                        13,
                        memTextOf(context).withValues(alpha: 0.5),
                        height: 1,
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < moods.length; i++) ...[
                    if (i > 0) const SizedBox(height: 20),
                    MoodRow(mood: moods[i], showNote: true, fullTime: true),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 返回小圆钮（无文字，干净白卡，跟情绪仪表盘一致）。
  Widget _backButton(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: memCleanCard(
        context: context,
        circle: true,
        fullWidth: false,
        padding: const EdgeInsets.all(10),
        child: Icon(
          LucideIcons.arrow_left,
          size: 20,
          color: memTextOf(context),
        ),
      ),
    );
  }

  Widget _errorState(BuildContext context) {
    final textColor = memTextOf(context);
    final grey = textColor.withValues(alpha: 0.5);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.wifi_off, size: 24, color: grey),
          const SizedBox(height: 12),
          Text('情绪记录连不上', style: memBody(14, grey)),
          const SizedBox(height: 16),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _load(force: true),
            child: memCleanCard(
              context: context,
              radius: 999,
              fullWidth: false,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: Text('重试', style: memBody(13, textColor)),
            ),
          ),
        ],
      ),
    );
  }
}
