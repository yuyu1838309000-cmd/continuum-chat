import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/pixel_home.dart';
import '../services/api_cache.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';
import 'pixel_room_page.dart';

/// 房间静态信息：楼层 + 中文名 + emoji。
class _RoomMeta {
  final int floor;
  final String name;
  final String emoji;

  const _RoomMeta(this.floor, this.name, this.emoji);
}

const Map<String, _RoomMeta> _roomMeta = {
  'gameroom': _RoomMeta(2, '游戏房', '🎮'),
  'bedroom': _RoomMeta(2, '卧室', '🛏️'),
  'balcony': _RoomMeta(1, '阳台', '🌿'),
  'living': _RoomMeta(1, '客厅', '🛋️'),
  'kitchen': _RoomMeta(1, '厨房', '🍳'),
  'dining': _RoomMeta(1, '餐厅', '🍽️'),
  'storage': _RoomMeta(2, '储物间', '📦'),
};

/// 状态板三人（顺序即展示顺序：AI 助手 / 用户 / 猫咪）。
class _PersonMeta {
  final String name;
  final String emoji;
  final CharacterState state;

  const _PersonMeta(this.name, this.emoji, this.state);
}

/// 小家（v0.2.155）：像素小家状态页，抽屉入口。
/// 顶部常驻三人状态板（点头像展开情绪/想法）+ 楼层切换（一楼/二楼）+
/// 房间网格卡片；点房间进详情，可点物品弹窗。
/// 数据源 8089 state_new.json：进入拉一次 + 下拉刷新 + 30s 静默轮询。
/// 风格照基准简洁卡片风：圆角 20 + cardShadow + cardColor，
/// 全页点缀色只出现一处（楼层切换选中态）。
class PixelHomePage extends StatefulWidget {
  const PixelHomePage({super.key});

  @override
  State<PixelHomePage> createState() => _PixelHomePageState();
}

class _PixelHomePageState extends State<PixelHomePage> {
  PixelHome? _home;
  bool _loading = true;
  bool _error = false;
  int _floor = 1;
  int? _expanded;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 30s 静默轮询：家是活的，状态板会自己动；失败保留旧数据不闪屏。
    _pollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refresh(silent: true),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    final url = ServerConfig.url(8089, '/state_new.json');
    // 首次打开先吃缓存秒显（不转圈）；缓存新鲜直接返回，过期/无缓存才拉网。
    if (!silent && _home == null) {
      final cached = await ApiCache.read(url);
      final cachedHome = _parseHome(cached);
      if (!mounted) return;
      if (cachedHome != null) {
        setState(() {
          _home = cachedHome;
          _error = false;
          _loading = false;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    if (!silent) {
      setState(() {
        _loading = _home == null;
        _error = false;
      });
    }
    final raw = await ApiCache.fetchJson(
      url,
      utf8Body: true,
      timeout: const Duration(seconds: 10),
    );
    final home = _parseHome(raw);
    if (!mounted) return;
    setState(() {
      if (home != null) {
        _home = home;
        _error = false;
      } else if (!silent || _home == null) {
        _error = true;
      }
      _loading = false;
    });
  }

  static PixelHome? _parseHome(dynamic raw) =>
      raw is Map<String, dynamic> ? PixelHome.fromJson(raw) : null;

  List<String> _roomsOnFloor(int floor) => [
    for (final e in _roomMeta.entries)
      if (e.value.floor == floor && _home?.rooms.containsKey(e.key) == true)
        e.key,
  ];

  void _openRoom(String roomId, _RoomMeta meta) {
    Navigator.of(context).push(
      SwipeBackRoute(
        builder: (_) =>
            PixelRoomPage(roomId: roomId, roomName: meta.name, home: _home!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('小家'),
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading
                  ? null
                  : () => _refresh(silent: _home != null),
              icon: const Icon(LucideIcons.refresh_cw, size: 20),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_home != null) _statusBoard(context, _home!),
            if (_home != null) _floorSwitch(context),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error || _home == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('小家没连上', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _refresh(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final rooms = _roomsOnFloor(_floor);
    return RefreshIndicator(
      onRefresh: () => _refresh(silent: true),
      child: GridView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          mainAxisExtent: 150,
        ),
        itemCount: rooms.length,
        itemBuilder: (context, i) => _roomCard(context, rooms[i]),
      ),
    );
  }

  // ── 状态板：常驻一行，点头像展开情绪/想法 ──
  Widget _statusBoard(BuildContext context, PixelHome home) {
    final theme = Theme.of(context);
    final people = [
      _PersonMeta('AI 助手', '🧑‍💻', home.me),
      _PersonMeta('用户', '🐟', home.appUser),
      _PersonMeta('猫咪', '🐱', home.cat),
    ];
    final expanded = _expanded;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  for (var i = 0; i < people.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: _personColumn(context, i, people[i])),
                  ],
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: expanded == null
                  ? const SizedBox.shrink()
                  : _expandedPanel(context, theme, people[expanded]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _personColumn(BuildContext context, int index, _PersonMeta p) {
    final selected = _expanded == index;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => setState(() => _expanded = selected ? null : index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        child: Column(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.fieldColor,
                shape: BoxShape.circle,
              ),
              child: Text(p.emoji, style: const TextStyle(fontSize: 19)),
            ),
            const SizedBox(height: 6),
            Text(
              p.name,
              style: const TextStyle(
                fontSize: AppType.caption,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _roomLabel(p.state.room),
              style: TextStyle(fontSize: 11, color: context.subTextColor),
            ),
            if (p.state.action.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                p.state.action,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: context.subTextColor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _expandedPanel(BuildContext context, ThemeData theme, _PersonMeta p) {
    final mood = p.state.mood;
    final think = p.state.think;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mood.isNotEmpty) _kvRow(context, '心情', mood),
          if (think.isNotEmpty) _kvRow(context, '想法', think),
          if (mood.isEmpty && think.isEmpty)
            Text(
              '此刻没留什么话',
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.subTextColor,
              ),
            ),
        ],
      ),
    );
  }

  Widget _kvRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.subTextColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  // ── 楼层切换：胶囊分段，选中态用主题点缀色（全页唯一一处）──
  Widget _floorSwitch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: context.fieldColor,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          children: [
            _floorSegment(context, 1, '一楼'),
            _floorSegment(context, 2, '二楼'),
          ],
        ),
      ),
    );
  }

  Widget _floorSegment(BuildContext context, int floor, String label) {
    final selected = _floor == floor;
    final theme = Theme.of(context);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: () {
          if (_floor != floor) setState(() => _floor = floor);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? context.accentColor : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? theme.colorScheme.onPrimary : context.textColor,
            ),
          ),
        ),
      ),
    );
  }

  // ── 房间网格卡片 ──
  Widget _roomCard(BuildContext context, String roomId) {
    final meta = _roomMeta[roomId]!;
    final room = _home!.rooms[roomId]!;
    final status = _roomStatus(roomId, room);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openRoom(roomId, meta),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.fieldColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(meta.emoji, style: const TextStyle(fontSize: 21)),
                ),
                const SizedBox(height: 12),
                Text(
                  meta.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.caption,
                      color: context.subTextColor,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 房间简要状态：有人在就显示他的动作，否则显示第一个 zone 的描述。
  String _roomStatus(String roomId, HomeRoom room) {
    final home = _home!;
    final actions = [
      if (home.me.room == roomId && home.me.action.isNotEmpty) home.me.action,
      if (home.appUser.room == roomId && home.appUser.action.isNotEmpty)
        home.appUser.action,
      if (home.cat.room == roomId && home.cat.action.isNotEmpty)
        home.cat.action,
    ];
    if (actions.isNotEmpty) return actions.first;
    return room.zones.isEmpty ? '' : room.zones.first.desc;
  }

  String _roomLabel(String roomId) => switch (roomId) {
    '' => '',
    'out' => '出门了',
    _ => _roomMeta[roomId]?.name ?? roomId,
  };
}
