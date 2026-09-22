import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/api_cache.dart';
import '../services/chat_api.dart';
import '../services/music_api.dart';
import '../services/music_player.dart';
import '../services/profile_api.dart';
import '../services/server_config.dart';
import '../utils/app_theme.dart';

/// 一起听歌全屏面板（v0.2.133，抽屉【一起听】入口；v0.2.136 砍悬浮窗 + 红心/历史）。
/// 顶部：当前播放卡（封面/歌名/歌手/谁在放微标/红心）→ 控制条（上一首/播放暂停/下一首）
/// → 进度条（Slider+时间，拖动 seek）→ 滚动歌词（按进度高亮当前句）
/// → 选歌区（最近播放/搜索/我的歌单/每日推荐 四段式，整页可下拉刷新）。
/// 风格：简洁卡片风基准（圆角20 + cardShadow + cardColor，design-guide v0.2.92），
/// 全页点缀色只出现一处（播放键），其余中性。
/// 状态源：MusicPlayer 单例（同一播放器实例，MusicPage 面板共用）。
class MusicPage extends StatefulWidget {
  const MusicPage({
    super.key,
    @visibleForTesting this.skipInitialLoads = false,
  });

  @visibleForTesting
  final bool skipInitialLoads;

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  static const List<String> _tabs = ['最近播放', '搜索', '我的歌单', '每日推荐'];

  int _tab = 0;

  // 搜索
  final TextEditingController _searchCtrl = TextEditingController();
  List<MusicTrack> _searchResults = const [];
  bool _searching = false;
  bool _searched = false;

  // 歌单
  List<MusicPlaylist> _playlists = const [];
  bool _playlistsLoading = false;
  bool _playlistsLoaded = false;
  MusicPlaylist? _openPlaylist;
  List<MusicTrack> _playlistTracks = const [];
  bool _playlistTracksLoading = false;

  // 每日推荐
  List<MusicTrack> _daily = const [];
  bool _dailyLoading = false;
  bool _dailyLoaded = false;

  // 最近播放（历史）
  List<MusicHistoryEntry> _history = const [];
  bool _historyLoading = false;
  bool _historyLoaded = false;

  // 歌词自动滚动
  final ScrollController _lyricScroll = ScrollController();
  int _shownLyricIndex = -1;

  // 进度条拖动中（不跟播放器位置抖动）
  double? _dragValue;

  // 切歌监听（历史列表跟当前播放联动刷新）
  int? _lastSongId;
  bool _playerListening = false;

  @override
  void initState() {
    super.initState();
    if (widget.skipInitialLoads) {
      _playlistsLoaded = true;
      _dailyLoaded = true;
      _historyLoaded = true;
    } else {
      _loadPlaylists();
      _loadDaily();
      _loadHistory();
    }
    MusicPlayer.instance.addListener(_onPlayerChanged);
    _playerListening = true;
  }

  @override
  void dispose() {
    if (_playerListening) {
      MusicPlayer.instance.removeListener(_onPlayerChanged);
    }
    _searchCtrl.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// 播放的歌变了 → 历史列表同步刷新（红心/最新在前）。
  void _onPlayerChanged() {
    final id = MusicPlayer.instance.songId;
    if (id == _lastSongId) return;
    _lastSongId = id;
    if (_historyLoaded) _loadHistory(silent: true);
  }

  Future<void> _loadPlaylists() async {
    final url = ServerConfig.url(8816, '/music/playlists');
    // 首次加载先吃缓存秒显；缓存新鲜就直接用，过期/无缓存才静默拉新。
    if (!_playlistsLoaded) {
      final cached = await ApiCache.read(url);
      final cachedList = _parsePlaylists(cached);
      if (!mounted) return;
      if (cachedList != null) {
        setState(() {
          _playlists = cachedList;
          _playlistsLoading = false;
          _playlistsLoaded = true;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() => _playlistsLoading = true);
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 12),
    );
    final list = _parsePlaylists(raw);
    if (!mounted) return;
    setState(() {
      if (list != null) _playlists = list;
      _playlistsLoading = false;
      _playlistsLoaded = true;
    });
  }

  Future<void> _loadDaily() async {
    final url = ServerConfig.url(8816, '/music/daily');
    if (!_dailyLoaded) {
      final cached = await ApiCache.read(url);
      final cachedList = _parseTracks(cached);
      if (!mounted) return;
      if (cachedList != null) {
        setState(() {
          _daily = cachedList;
          _dailyLoading = false;
          _dailyLoaded = true;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    setState(() => _dailyLoading = true);
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 12),
    );
    final list = _parseTracks(raw);
    if (!mounted) return;
    setState(() {
      if (list != null) _daily = list;
      _dailyLoading = false;
      _dailyLoaded = true;
    });
  }

  /// 最近播放（历史）：silent 时不闪加载圈（切歌/红心后静默刷新）。
  Future<void> _loadHistory({bool silent = false}) async {
    final url = ServerConfig.url(8816, '/music/history');
    if (!silent && !_historyLoaded) {
      final cached = await ApiCache.read(url);
      final cachedList = _parseHistory(cached);
      if (!mounted) return;
      if (cachedList != null) {
        setState(() {
          _history = cachedList;
          _historyLoading = false;
          _historyLoaded = true;
        });
        if (!await ApiCache.isExpired(url)) return;
      }
    }
    if (!silent) {
      setState(() => _historyLoading = true);
    }
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 10),
    );
    final list = _parseHistory(raw);
    if (!mounted) return;
    setState(() {
      if (list != null) _history = list;
      _historyLoading = false;
      _historyLoaded = true;
    });
  }

  static List<MusicHistoryEntry>? _parseHistory(dynamic raw) {
    if (raw is! List) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) historyEntryOf(e),
    ];
  }

  static List<MusicTrack>? _parseTracks(dynamic raw) {
    if (raw is! Map || raw['ok'] != true || raw['tracks'] is! List) return null;
    return [
      for (final e in raw['tracks'] as List)
        if (e is Map<String, dynamic>) MusicApi.trackOf(e),
    ];
  }

  static List<MusicPlaylist>? _parsePlaylists(dynamic raw) {
    if (raw is! Map || raw['ok'] != true || raw['playlists'] is! List) {
      return null;
    }
    return [
      for (final e in raw['playlists'] as List)
        if (e is Map<String, dynamic>)
          MusicPlaylist(
            id: (e['id'] as num? ?? 0).toInt(),
            name: (e['name'] as String? ?? '').trim(),
            trackCount: (e['track_count'] as num? ?? 0).toInt(),
          ),
    ];
  }

  /// 整页下拉刷新：历史/歌单/每日推荐一起重拉。
  Future<void> _refreshAll() async {
    await Future.wait([
      _loadHistory(silent: true),
      _loadPlaylists(),
      _loadDaily(),
    ]);
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = true;
      _searched = true;
      _searchResults = const [];
    });
    final list = await MusicApi.search(q);
    if (!mounted) return;
    setState(() {
      _searchResults = list;
      _searching = false;
    });
  }

  Future<void> _openPlaylistDetail(MusicPlaylist pl) async {
    final url = ServerConfig.url(8816, '/music/playlist?id=${pl.id}');
    setState(() {
      _openPlaylist = pl;
      _playlistTracks = const [];
      _playlistTracksLoading = true;
    });
    // 歌单内歌曲同样先吃缓存秒显，再静默拉新。
    final cached = await ApiCache.read(url);
    final cachedTracks = _parseTracks(cached);
    if (!mounted) return;
    if (cachedTracks != null) {
      setState(() {
        _playlistTracks = cachedTracks;
        _playlistTracksLoading = false;
      });
      if (!await ApiCache.isExpired(url)) return;
    }
    final raw = await ApiCache.fetchJson(
      url,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
      timeout: const Duration(seconds: 12),
    );
    final list = _parseTracks(raw);
    if (!mounted) return;
    setState(() {
      if (list != null) _playlistTracks = list;
      _playlistTracksLoading = false;
    });
  }

  void _backToPlaylists() {
    setState(() {
      _openPlaylist = null;
      _playlistTracks = const [];
    });
  }

  /// 红心（历史列表项 / 当前播放卡共用）：点了同步 8816 + 刷新历史联动。
  Future<void> _toggleLike(MusicHistoryEntry entry) async {
    if (MusicPlayer.instance.songId == entry.songId) {
      await MusicPlayer.instance.toggleLike(who: 'participant');
    } else {
      await MusicApi.like(
        id: entry.songId,
        who: 'participant',
        like: !entry.likedParticipant,
      );
    }
    if (mounted) await _loadHistory(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: context.overlayStyle,
      child: Scaffold(
        backgroundColor: context.bgColor,
        body: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              MusicPlayer.instance,
              ProfileManager.instance,
            ]),
            builder: (context, _) => _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refreshAll,
            color: Theme.of(context).colorScheme.primary,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _buildNowHeading(context),
                const SizedBox(height: 12),
                _buildPlayerCard(context),
                _buildControls(context),
                _buildProgress(context),
                if (MusicPlayer.instance.error != null) _buildError(context),
                _buildLyrics(context),
                const SizedBox(height: 28),
                Text(
                  '接下来想听什么',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                _buildSegmented(context),
                const SizedBox(height: 12),
                _buildSection(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNowHeading(BuildContext context) {
    final player = MusicPlayer.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '现在一起听什么',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            height: 1.25,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          player.hasSong ? '这一首，正在我们之间播放' : '挑一首，让这一刻有同一段声音',
          style: TextStyle(fontSize: 13, color: context.subTextColor),
        ),
      ],
    );
  }

  // ── 顶栏：返回 + 标题（悬浮窗开关已随 v0.2.136 砍掉）──
  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          _IconBtn(
            icon: LucideIcons.chevron_left,
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          const Expanded(
            child: Text(
              '一起听',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // ── 当前播放卡：双头像气泡 + 耳机线 + 歌名/歌手 + 各自红心 ──
  Widget _buildPlayerCard(BuildContext context) {
    final player = MusicPlayer.instance;
    final profile = ProfileManager.instance;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 116,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _HeadphoneCablePainter(
                          color: context.subTextColor.withValues(alpha: 0.5),
                          endpointY: 34,
                          bubbleRadius: 38,
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        _BubbleColumn(
                          avatarUrl: profile.youAvatar,
                          label: 'AI 助手',
                          liked: player.likedMe,
                          enabled: player.hasSong,
                          onHeart: null,
                        ),
                        Expanded(
                          child: SizedBox(
                            height: 116,
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      player.hasSong ? player.name : '还没在听歌',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        height: 1.25,
                                      ),
                                    ),
                                    if (player.hasSong) ...[
                                      const SizedBox(height: 5),
                                      Text(
                                        player.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: context.subTextColor,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        _BubbleColumn(
                          avatarUrl: profile.meAvatar,
                          label: '用户',
                          liked: player.likedParticipant,
                          enabled: player.hasSong,
                          onHeart: () => _toggleCurrentLike('participant'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (player.hasSong) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: context.fieldColor,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    player.sourceLabel,
                    style: TextStyle(fontSize: 11, color: context.subTextColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleCurrentLike(String who) async {
    await MusicPlayer.instance.toggleLike(who: who);
    if (mounted) await _loadHistory(silent: true);
  }

  Future<void> _openQueue() async {
    var tracks = MusicPlayer.instance.contextList ?? const <MusicTrack>[];
    if (tracks.isEmpty) {
      final history = await MusicApi.history();
      tracks = [for (final e in history) e.toTrack()];
    }
    if (!mounted || tracks.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _QueueSheet(
        tracks: tracks,
        currentId: MusicPlayer.instance.songId,
        onTap: (track) {
          Navigator.of(context).pop();
          MusicPlayer.instance.playSong(track, fromList: tracks);
        },
      ),
    );
  }

  // ── 控制条：循环模式 / 上一首 / 播放暂停 / 下一首 ──
  Widget _buildControls(BuildContext context) {
    final player = MusicPlayer.instance;
    final hasContext = player.hasSong;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const controlsWidth = 246.0;
          final gap = ((constraints.maxWidth - controlsWidth) / 4).clamp(
            8.0,
            20.0,
          );
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _LoopBtn(
                mode: player.loopMode,
                enabled: true,
                onTap: () => player.cycleLoopMode(),
              ),
              SizedBox(width: gap),
              _CtrlBtn(
                icon: LucideIcons.skip_back,
                enabled: hasContext,
                onTap: () => player.prev(),
              ),
              SizedBox(width: gap),
              // 播放/暂停：全页唯一点缀色
              _PlayBtn(
                playing: player.playing,
                loading: player.loading,
                enabled: player.hasSong,
                onTap: () => player.togglePlayPause(),
              ),
              SizedBox(width: gap),
              _CtrlBtn(
                icon: LucideIcons.skip_forward,
                enabled: hasContext,
                onTap: () => player.next(),
              ),
              SizedBox(width: gap),
              _CtrlBtn(
                icon: LucideIcons.list_music,
                enabled: player.hasSong,
                onTap: _openQueue,
              ),
            ],
          );
        },
      ),
    );
  }

  // ── 进度条 ──
  Widget _buildProgress(BuildContext context) {
    final player = MusicPlayer.instance;
    final duration = player.duration;
    final max = duration != null && duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final value = (_dragValue ?? player.position.inMilliseconds.toDouble())
        .clamp(0.0, max);
    return Row(
      children: [
        Text(
          fmtDuration(Duration(milliseconds: value.round())),
          style: TextStyle(fontSize: 11, color: context.subTextColor),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: context.textColor.withValues(alpha: 0.45),
              inactiveTrackColor: context.fieldColor,
              thumbColor: context.textColor.withValues(alpha: 0.8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value,
              max: max,
              onChangeStart: (_) => setState(
                () => _dragValue = player.position.inMilliseconds.toDouble(),
              ),
              onChanged: (v) => setState(() => _dragValue = v),
              onChangeEnd: (v) {
                setState(() => _dragValue = null);
                player.seek(Duration(milliseconds: v.round()));
              },
            ),
          ),
        ),
        Text(
          fmtDuration(duration ?? Duration.zero),
          style: TextStyle(fontSize: 11, color: context.subTextColor),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.triangle_alert,
            size: 15,
            color: context.dangerColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              MusicPlayer.instance.error!,
              style: TextStyle(fontSize: 12, color: context.dangerColor),
            ),
          ),
        ],
      ),
    );
  }

  // ── 滚动歌词 ──
  Widget _buildLyrics(BuildContext context) {
    final player = MusicPlayer.instance;
    final lines = player.lyricLines;
    final idx = player.lyricIndex;
    // 歌词行切换时自动滚动，让当前句保持在可视区中上部
    if (idx != _shownLyricIndex) {
      _shownLyricIndex = idx;
      if (lines.isNotEmpty && _lyricScroll.hasClients) {
        final maxScroll = (lines.length * 34.0 - 116).clamp(
          0.0,
          double.infinity,
        );
        final target = (idx * 34.0 - 60).clamp(0.0, maxScroll);
        _lyricScroll.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
    }
    return Container(
      height: 180,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: _buildLyricContent(context, player, lines),
      ),
    );
  }

  Widget _buildLyricContent(
    BuildContext context,
    MusicPlayer player,
    List<LyricLine> lines,
  ) {
    if (!player.hasSong) {
      return Center(
        child: Text(
          '挑一首歌，歌词会跟着放',
          style: TextStyle(fontSize: 13, color: context.subTextColor),
        ),
      );
    }
    if (!player.lyricsLoaded) {
      return Center(
        child: Text(
          '歌词加载中…',
          style: TextStyle(fontSize: 13, color: context.subTextColor),
        ),
      );
    }
    if (lines.isEmpty) {
      return Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(fontSize: 13, color: context.subTextColor),
        ),
      );
    }
    final idx = player.lyricIndex;
    return ListView.builder(
      controller: _lyricScroll,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: lines.length,
      itemExtent: 34,
      itemBuilder: (context, i) {
        final current = i == idx;
        return Center(
          child: Text(
            lines[i].text,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: current ? 15 : 13,
              fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              color: current
                  ? Theme.of(context).colorScheme.onSurface
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }

  // ── 选歌区：最近播放 / 搜索 / 我的歌单 / 每日推荐 ──
  Widget _buildSegmented(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: _SegItem(
                label: _tabs[i],
                selected: _tab == i,
                onTap: () => setState(() => _tab = i),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection(BuildContext context) {
    switch (_tab) {
      case 1:
        return _buildSearch(context);
      case 2:
        return _buildPlaylists(context);
      case 3:
        return _buildDaily(context);
      default:
        return _buildHistory(context);
    }
  }

  // 最近播放（历史）
  Widget _buildHistory(BuildContext context) {
    if (_historyLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_historyLoaded && _history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            '还没有播放记录',
            style: TextStyle(fontSize: 13, color: context.subTextColor),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _history.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _HistoryCard(
            entry: _history[i],
            onTap: () => MusicPlayer.instance.playSong(
              _history[i].toTrack(),
              fromList: _historyTracks(),
            ),
            onHeart: () => _toggleLike(_history[i]),
          ),
        ],
      ],
    );
  }

  /// 历史列表当切歌上下文（重播后上一首/下一首在历史里走）。
  List<MusicTrack> _historyTracks() => [for (final e in _history) e.toTrack()];

  // 搜索
  Widget _buildSearch(BuildContext context) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: context.fieldColor,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: TextField(
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: '搜歌名 / 歌手',
              hintStyle: TextStyle(fontSize: 14, color: context.subTextColor),
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: context.subTextColor,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          )
        else if (_searched && _searchResults.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                '没有搜到，换个关键词试试',
                style: TextStyle(fontSize: 13, color: context.subTextColor),
              ),
            ),
          )
        else
          _buildTrackList(context, _searchResults),
      ],
    );
  }

  // 我的歌单
  Widget _buildPlaylists(BuildContext context) {
    if (_openPlaylist != null) {
      return Column(
        children: [
          _BackRow(title: _openPlaylist!.name, onTap: _backToPlaylists),
          const SizedBox(height: 8),
          if (_playlistTracksLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            )
          else
            _buildTrackList(context, _playlistTracks),
        ],
      );
    }
    if (_playlistsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_playlistsLoaded && _playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            '还没有歌单',
            style: TextStyle(fontSize: 13, color: context.subTextColor),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final pl in _playlists)
          _PlaylistCard(playlist: pl, onTap: () => _openPlaylistDetail(pl)),
      ],
    );
  }

  // 每日推荐
  Widget _buildDaily(BuildContext context) {
    if (_dailyLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_dailyLoaded && _daily.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            '今天没有推荐',
            style: TextStyle(fontSize: 13, color: context.subTextColor),
          ),
        ),
      );
    }
    return _buildTrackList(context, _daily);
  }

  // 歌曲列表（搜索/歌单内/每日推荐共用，点播会记进切歌上下文）
  Widget _buildTrackList(BuildContext context, List<MusicTrack> tracks) {
    return Column(
      children: [
        for (var i = 0; i < tracks.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _TrackCard(
            track: tracks[i],
            onTap: () =>
                MusicPlayer.instance.playSong(tracks[i], fromList: tracks),
          ),
        ],
      ],
    );
  }
}

// ── 顶栏/通用图标按钮 ──
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _IconBtn({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

// ── 头像气泡 + 红心（左AI 助手 / 右用户，头像动态读资料页）──
class _BubbleColumn extends StatelessWidget {
  final String avatarUrl;
  final String label;
  final bool liked;
  final bool enabled;
  final VoidCallback? onHeart;

  const _BubbleColumn({
    required this.avatarUrl,
    required this.label,
    required this.liked,
    required this.enabled,
    this.onHeart,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Image.asset(
      'assets/icon-continuum.png',
      width: 68,
      height: 68,
      fit: BoxFit.cover,
    );
    return SizedBox(
      width: 76,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: ClipOval(
              child: avatarUrl.isEmpty
                  ? fallback
                  : CachedNetworkImage(
                      imageUrl: avatarUrl,
                      width: 68,
                      height: 68,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      fadeOutDuration: Duration.zero,
                      placeholder: (_, _) => const SizedBox.shrink(),
                      errorWidget: (_, _, _) => fallback,
                    ),
            ),
          ),
          const SizedBox(height: 5),
          Opacity(
            opacity: enabled ? 1 : 0.45,
            child: InkWell(
              onTap: enabled ? onHeart : null,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: liked
                          ? context.accentColor
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 两气泡之间的耳机线（弯曲连线，风格化）──
class _HeadphoneCablePainter extends CustomPainter {
  final Color color;
  final double endpointY;
  final double bubbleRadius;

  const _HeadphoneCablePainter({
    required this.color,
    required this.endpointY,
    required this.bubbleRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final left = Offset(bubbleRadius, endpointY);
    final right = Offset(size.width - bubbleRadius, endpointY);
    final path = Path()
      ..moveTo(left.dx, left.dy)
      ..quadraticBezierTo(size.width / 2, endpointY + 58, right.dx, right.dy);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HeadphoneCablePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.endpointY != endpointY ||
      oldDelegate.bubbleRadius != bubbleRadius;
}

// ── 本地占位音乐图标（不再加载网易云封面）──
class _TrackIcon extends StatelessWidget {
  const _TrackIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: context.fieldColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(LucideIcons.music, size: 20, color: context.subTextColor),
    );
  }
}

// ── 播放/暂停主键（全页唯一点缀色）──
class _PlayBtn extends StatelessWidget {
  final bool playing;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  const _PlayBtn({
    required this.playing,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        child: Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: theme.colorScheme.primary,
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(alpha: 0.28),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: loading
              ? Padding(
                  padding: const EdgeInsets.all(19),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: theme.colorScheme.onPrimary,
                  ),
                )
              : Icon(
                  playing ? LucideIcons.pause : LucideIcons.play,
                  size: 26,
                  color: theme.colorScheme.onPrimary,
                ),
        ),
      ),
    );
  }
}

// ── 上一首/下一首 ──
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _CtrlBtn({required this.icon, required this.enabled, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: 26,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// ── 循环模式：🔁 列表循环 → 🔂 单曲循环 → 🔀 随机 ──
class _LoopBtn extends StatelessWidget {
  final MusicLoopMode mode;
  final bool enabled;
  final VoidCallback? onTap;

  const _LoopBtn({required this.mode, required this.enabled, this.onTap});

  IconData get _icon => switch (mode) {
    MusicLoopMode.list => LucideIcons.repeat,
    MusicLoopMode.one => LucideIcons.repeat_1,
    MusicLoopMode.shuffle => LucideIcons.shuffle,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: InkWell(
        onTap: enabled ? onTap : null,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 48,
          child: Icon(
            _icon,
            size: 22,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// ── 播放列表弹层：当前歌单/历史队列，高亮当前播放，点歌切换 ──
class _QueueSheet extends StatelessWidget {
  final List<MusicTrack> tracks;
  final int? currentId;
  final ValueChanged<MusicTrack> onTap;

  const _QueueSheet({
    required this.tracks,
    required this.currentId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.32,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: context.bgColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.md),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Text(
                  '播放列表',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: tracks.length,
                    itemBuilder: (context, i) => _QueueItem(
                      track: tracks[i],
                      current: tracks[i].id == currentId,
                      onTap: () => onTap(tracks[i]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _QueueItem extends StatelessWidget {
  final MusicTrack track;
  final bool current;
  final VoidCallback onTap;

  const _QueueItem({
    required this.track,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const _TrackIcon(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: current
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: current ? context.accentColor : null,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current)
                  Icon(
                    LucideIcons.audio_lines,
                    size: 18,
                    color: context.accentColor,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 分段项 ──
class _SegItem extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected ? context.cardColor : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 歌曲行（搜索/歌单/每日推荐，简洁卡片风）──
class _TrackCard extends StatelessWidget {
  final MusicTrack track;
  final VoidCallback onTap;

  const _TrackCard({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _TrackIcon(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(LucideIcons.play, size: 18, color: context.subTextColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 最近播放行（历史，封面/歌名/歌手 + 红心状态，点行重播、点红心联动）──
class _HistoryCard extends StatelessWidget {
  final MusicHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onHeart;

  const _HistoryCard({
    required this.entry,
    required this.onTap,
    required this.onHeart,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final liked = entry.likedAny;
    final label = entry.likedMe && entry.likedParticipant
        ? '都喜欢'
        : entry.likedParticipant
        ? '用户喜欢'
        : entry.likedMe
        ? 'AI 助手喜欢'
        : '';
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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                _TrackIcon(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.subTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (label.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                InkWell(
                  onTap: onHeart,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      entry.likedAny ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                      color: liked
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 歌单行 ──
class _PlaylistCard extends StatelessWidget {
  final MusicPlaylist playlist;
  final VoidCallback onTap;

  const _PlaylistCard({required this.playlist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  LucideIcons.library,
                  size: 22,
                  color: context.subTextColor,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${playlist.trackCount} 首',
                  style: TextStyle(fontSize: 12, color: context.subTextColor),
                ),
                const SizedBox(width: 6),
                Icon(
                  LucideIcons.chevron_right,
                  size: 20,
                  color: context.subTextColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 歌单内返回行 ──
class _BackRow extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _BackRow({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(
              LucideIcons.chevron_left,
              size: 20,
              color: context.subTextColor,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
