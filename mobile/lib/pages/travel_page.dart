import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/api_cache.dart';
import '../services/chat_api.dart';
import '../services/server_config.dart';
import '../services/travel_api.dart';
import '../utils/app_theme.dart';

typedef TravelDataLoader = Future<Map<String, dynamic>?> Function({bool force});

/// 旅行（个人空间入口，v0.2.148）：nowhere（8077）旅行记录只读展示。
/// 当前位置卡 / 到访过的地方（按次数倒序）/ 明信片（重点做精致）/ 见闻 / 登陆点。
/// 简洁卡片风基准：圆角 20 + cardShadow + cardColor，全页点缀色只出现一处。
class TravelPage extends StatefulWidget {
  const TravelPage({
    super.key,
    @visibleForTesting this.initialData,
    @visibleForTesting this.dataLoader,
  });

  @visibleForTesting
  final Map<String, dynamic>? initialData;

  @visibleForTesting
  final TravelDataLoader? dataLoader;

  @override
  State<TravelPage> createState() => _TravelPageState();
}

class _TravelPageState extends State<TravelPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _error = false;
  // v0.2.153：旧内容（明信片/见闻/登陆点）默认只显示最近 3 条，更早收进"展开全部"
  bool _postcardsExpanded = false;
  bool _sightingsExpanded = false;
  bool _landingsExpanded = false;
  bool _visitsExpanded = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialData case final initialData?) {
      _data = initialData;
      _loading = false;
    } else {
      _load();
    }
  }

  /// 页面级缓存：首次打开先吃缓存秒显（不转圈），后台静默拉新；
  /// 下拉刷新/重试走 [force] 直接拉网。失败保留缓存数据不报错。
  Future<void> _load({bool force = false}) async {
    if (widget.dataLoader case final loader?) {
      setState(() {
        _loading = _data == null;
        _error = false;
      });
      final data = await loader(force: force);
      if (!mounted) return;
      setState(() {
        if (data != null) _data = data;
        _loading = false;
        _error = _data == null;
      });
      return;
    }
    final url = ServerConfig.url(8816, '/nowhere/data');
    if (!force && _data == null) {
      final cached = await ApiCache.read(url);
      final cachedData = _parseData(cached);
      if (!mounted) return;
      if (cachedData != null) {
        setState(() {
          _data = cachedData;
          _loading = false;
          _error = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() {
      _loading = _data == null;
      _error = false;
    });
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 10),
    );
    final data = _parseData(raw);
    if (!mounted) return;
    setState(() {
      if (data != null) _data = data;
      _loading = false;
      _error = _data == null;
    });
  }

  static Map<String, dynamic>? _parseData(dynamic raw) =>
      raw is Map<String, dynamic> ? raw : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('旅行'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
        ),
        body: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error || _data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('旅行记录连不上', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final data = _data!;
    final journey = _mapOf(data['journey']);
    final visits = _mapOf(data['visits']);
    final postcards = _postcards(data['postcards']);
    final sightings = _sightings(data['sightings']);
    final landings = _landings(data['landings']);
    final hasAny =
        journey.isNotEmpty ||
        visits.isNotEmpty ||
        postcards.isNotEmpty ||
        sightings.isNotEmpty ||
        landings.isNotEmpty;
    if (!hasAny) {
      return Center(
        child: Text(
          '还没出发，路上空空',
          style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (journey.isNotEmpty) ...[
            _sectionTitle(theme, '现在走到哪里', primary: true),
            _journeyCard(theme, journey),
          ],
          if (postcards.isNotEmpty) ...[
            _sectionTitle(theme, '最近明信片', primary: journey.isEmpty),
            for (final p
                in _postcardsExpanded ? postcards : postcards.take(3).toList())
              _postcardCard(theme, p),
            if (postcards.length > 3)
              _expandRow(
                theme,
                total: postcards.length,
                expanded: _postcardsExpanded,
                onTap: () =>
                    setState(() => _postcardsExpanded = !_postcardsExpanded),
              ),
          ],
          if (sightings.isNotEmpty) ...[
            _sectionTitle(theme, '最近见闻'),
            _sightingsCard(
              theme,
              _sightingsExpanded ? sightings : sightings.take(3).toList(),
              total: sightings.length,
              expanded: _sightingsExpanded,
              onExpand: () =>
                  setState(() => _sightingsExpanded = !_sightingsExpanded),
            ),
          ],
          if (visits.isNotEmpty || landings.isNotEmpty)
            _sectionTitle(theme, '旅途足迹', primary: true),
          if (visits.isNotEmpty) ...[
            _sectionTitle(theme, '到访记录'),
            _visitsCard(
              theme,
              visits,
              total: visits.length,
              expanded: _visitsExpanded,
              onExpand: () =>
                  setState(() => _visitsExpanded = !_visitsExpanded),
            ),
          ],
          if (landings.isNotEmpty) ...[
            _sectionTitle(theme, '登陆点'),
            _landingsCard(
              theme,
              _landingsExpanded ? landings : landings.take(3).toList(),
              total: landings.length,
              expanded: _landingsExpanded,
              onExpand: () =>
                  setState(() => _landingsExpanded = !_landingsExpanded),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Map<String, dynamic> _mapOf(Object? v) =>
      v is Map<String, dynamic> ? v : <String, dynamic>{};

  List<Postcard> _postcards(Object? v) {
    final items = v is Map<String, dynamic> ? v['items'] : null;
    if (items is! List) return const [];
    return sortedTravelPostcardsForDisplay([
      for (final e in items)
        if (e is Map<String, dynamic>) Postcard.fromJson(e),
    ]);
  }

  List<Sighting> _sightings(Object? v) {
    final items = v is Map<String, dynamic> ? v['items'] : null;
    if (items is! List) return const [];
    return [
      for (final e in items)
        if (e is Map<String, dynamic>) Sighting.fromJson(e),
    ];
  }

  List<Landing> _landings(Object? v) {
    final m = _mapOf(v);
    final out = <Landing>[];
    m.forEach((k, val) {
      if (val is Map<String, dynamic>) out.add(Landing.fromJson(k, val));
    });
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  Widget _sectionTitle(ThemeData theme, String title, {bool primary = false}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: primary ? 20 : 15,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }

  // ── 当前位置 ──
  Widget _journeyCard(ThemeData theme, Map<String, dynamic> j) {
    final place = (j['place_name'] as String? ?? '').trim();
    final pos = j['pos'];
    final lat = pos is List && pos.isNotEmpty ? pos[0] : null;
    final lon = pos is List && pos.length > 1 ? pos[1] : null;
    final mode = (j['mode'] as String? ?? '').trim();
    final biome = (j['biome'] as String? ?? '').trim();
    final landed = _formatIso(j['landed_at']);
    final lastText = (j['last_text'] as String? ?? '').trim();

    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  LucideIcons.map_pin,
                  size: 19,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.isEmpty ? '在路上' : place,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (biome.isNotEmpty) biome,
                        if (mode.isNotEmpty) mode,
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (lat != null && lon != null) ...[
            const SizedBox(height: 12),
            Text(
              '${_num(lat)}, ${_num(lon)}',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (landed.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '落地于 $landed',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
          ],
          if (lastText.isNotEmpty) ...[
            const SizedBox(height: 12),
            // v0.2.153：当前位置描述直接显示全文（去掉 maxLines 截断）
            Text(lastText, style: const TextStyle(fontSize: 13, height: 1.55)),
          ],
        ],
      ),
    );
  }

  // ── 到访过的地方 ──
  Widget _visitsCard(
    ThemeData theme,
    Map<String, dynamic> visits, {
    required int total,
    required bool expanded,
    required VoidCallback onExpand,
  }) {
    final entries = visits.entries.toList()
      ..sort((a, b) => (b.value as num? ?? 0).compareTo(a.value as num? ?? 0));
    final shown = expanded ? entries : entries.take(3).toList();
    return _card(
      theme,
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            Row(
              children: [
                Icon(
                  LucideIcons.footprints,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    shown[i].key,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                Text(
                  '${shown[i].value} 次',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          // v0.2.153 修复批次：到访过的地方也统一折叠（默认 3 条，展开全部/收起）
          if (total > shown.length) ...[
            const SizedBox(height: 2),
            _expandRow(
              theme,
              total: total,
              expanded: expanded,
              onTap: onExpand,
            ),
          ],
        ],
      ),
    );
  }

  // ── 明信片（重点做精致）──
  Widget _postcardCard(ThemeData theme, Postcard p) {
    final stamp = p.stamp;
    final place = stamp?.place.isNotEmpty == true ? stamp!.place : '远方来信';
    final localTime = stamp?.localTime.trim() ?? '';
    final chips = <Widget>[
      if (stamp != null && stamp.weather.isNotEmpty)
        _stampChip(theme, LucideIcons.cloud, stamp.weather),
      if (stamp != null && stamp.tempLabel.isNotEmpty)
        _stampChip(theme, LucideIcons.sun, stamp.tempLabel),
      if (stamp != null && stamp.elevation != 0)
        _stampChip(theme, LucideIcons.mountain, '${stamp.elevation}m'),
      if (stamp != null && stamp.surface.isNotEmpty)
        _stampChip(theme, LucideIcons.navigation, stamp.surface),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place,
                          style: const TextStyle(
                            fontSize: 17,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (localTime.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Text(
                            localTime,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary.withValues(alpha: 0.07),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.26,
                        ),
                      ),
                    ),
                    child: Text(
                      _stampChar(place),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.82,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (p.text.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  p.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.68,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
              if (chips.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: chips),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 折叠展开行：旧内容收进"展开全部（N 条）"，点开显示全部、再点收起。
  Widget _expandRow(
    ThemeData theme, {
    required int total,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Center(
        child: TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurfaceVariant,
          ),
          icon: Icon(
            expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
            size: 16,
          ),
          label: Text(expanded ? '收起' : '展开全部（$total 条）'),
        ),
      ),
    );
  }

  String _stampChar(String place) {
    if (place.isEmpty) return '远';
    return place.substring(0, 1);
  }

  Widget _stampChip(ThemeData theme, IconData icon, String label) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: theme.colorScheme.outline),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 见闻 ──
  Widget _sightingsCard(
    ThemeData theme,
    List<Sighting> items, {
    required int total,
    required bool expanded,
    required VoidCallback onExpand,
  }) {
    return _card(
      theme,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            Row(
              children: [
                Icon(
                  LucideIcons.bird,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].displayName,
                        style: const TextStyle(fontSize: 14),
                      ),
                      if (items[i].distanceM > 0)
                        Text(
                          '${items[i].distanceM}m 外',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                ),
                if (items[i].seenAt.isNotEmpty)
                  Text(
                    items[i].seenAt,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
          if (total > items.length) ...[
            const SizedBox(height: 2),
            _expandRow(
              theme,
              total: total,
              expanded: expanded,
              onTap: onExpand,
            ),
          ],
        ],
      ),
    );
  }

  // ── 登陆点 ──
  Widget _landingsCard(
    ThemeData theme,
    List<Landing> items, {
    required int total,
    required bool expanded,
    required VoidCallback onExpand,
  }) {
    return _card(
      theme,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 20),
            Row(
              children: [
                Icon(
                  LucideIcons.plane,
                  size: 16,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        items[i].place,
                        style: const TextStyle(fontSize: 14),
                      ),
                      Text(
                        [
                          if (items[i].elevation != 0) '${items[i].elevation}m',
                          if (items[i].surface.isNotEmpty) items[i].surface,
                          if (items[i].last.isNotEmpty)
                            _formatIso(items[i].last),
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${items[i].count} 次',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          if (total > items.length) ...[
            const SizedBox(height: 2),
            _expandRow(
              theme,
              total: total,
              expanded: expanded,
              onTap: onExpand,
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(ThemeData theme, {required Widget child}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    );
  }

  String _num(Object? v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n.toStringAsFixed(2);
  }

  /// ISO 时间（UTC）→ 本地 "MM-dd HH:mm"；解析失败原样返回。
  String _formatIso(Object? v) {
    final s = (v as String? ?? '').trim();
    if (s.isEmpty) return '';
    final dt = DateTime.tryParse(s);
    if (dt == null) return s;
    final t = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

@visibleForTesting
List<Postcard> sortedTravelPostcardsForDisplay(Iterable<Postcard> postcards) {
  return sortTravelPostcardsNewestFirst(postcards);
}
