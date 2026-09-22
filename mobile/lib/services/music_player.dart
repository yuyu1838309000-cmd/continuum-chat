import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'music_api.dart';

/// 循环模式：列表循环 / 单曲循环 / 随机。
enum MusicLoopMode {
  list('list'),
  one('one'),
  shuffle('shuffle');

  const MusicLoopMode(this.key);
  final String key;

  static MusicLoopMode fromKey(String? key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return MusicLoopMode.list;
  }
}

/// 一起听歌播放器（v0.2.133，全局单例，同一播放器实例/状态源）。
///
/// 职责：
/// - just_audio 流式播 http URL（进度/暂停/seek），App 内外统一走这一个实例
/// - 接收 AppEventClient 分流过来的 type=music pending 消息：
///   action=play 播 URL / pause / resume
/// - 用户操作上报 8816：点播/切歌 POST /music/play 拿 URL 播 + /music/next 上报
///   source=participant（用户切的）；暂停/继续 POST /music/pause|resume
/// - URL 20 分钟过期：轮询时提前 30 秒重新 POST /music/play 拿新 URL 续播
///   （从当前进度续，不打断）
/// - 去重：自己点的歌，后端推回的 type=music play 消息同 id 同 url → 跳过
/// - 媒体通知已砍（v0.2.139，用户拍板）：MusicMediaService + MediaSession 连续
///   三版未正常显示，不再做媒体通知；播放/暂停/切歌控制只在 App 面板内，
///   播放状态只走 8816（/music/* 上报）和 MusicPage UI
/// - 红心（v0.2.136）：Continuum Chat自己的红心，POST /music/like 同步 8816，
///   me/participant 分开记；当前播放卡显示谁点了。
class MusicPlayer extends ChangeNotifier {
  MusicPlayer._() {
    _listenAudio();
    unawaited(_loadLoopMode());
  }
  static final MusicPlayer instance = MusicPlayer._();

  /// 播放 URL 有效期（秒），跟后端 MUSIC_URL_TTL 一致；提前 30 秒刷新续播。
  static const int _urlTtlSec = 20 * 60;
  static const int _urlRefreshAheadSec = 30;
  static const String _loopPrefsKey = 'music_loop_mode';

  // ── 当前播放状态（UI 只读，走 getter）──
  int? _songId;
  String _name = '';
  String _artist = '';
  String _cover = '';
  String _source =
      'me'; // me=AI 助手放的 / participant=用户切的（读 /music/current 的 source）
  String _loadedUrl = '';
  double _expireAt = 0; // epoch 秒
  bool _playing = false;
  bool _loading = false;
  String? _error;
  Duration _position = Duration.zero;
  Duration? _duration;
  String _lyricsText = '';
  List<LyricLine> _lyricLines = const [];
  bool _lyricsLoaded = false;

  // ── 红心（Continuum Chat自己的，me=AI 助手 / participant=用户，谁点的分开记）──
  bool _likedMe = false;
  bool _likedParticipant = false;

  // ── 循环模式（列表循环 / 单曲循环 / 随机，shared_preferences 持久化）──
  MusicLoopMode _loopMode = MusicLoopMode.list;

  // ── 切歌上下文：最后一次选歌的列表（搜索/歌单/每日推荐）──
  List<MusicTrack>? _contextList;
  int _contextIndex = -1;

  // ── 内部 ──
  final AudioPlayer _player = AudioPlayer();
  bool _started = false;
  bool _expiryRefreshing = false;
  bool _restoring = false;

  // ── 对外状态 ──
  int? get songId => _songId;
  String get name => _name;
  String get artist => _artist;
  String get cover => _cover;
  String get source => _source;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;
  Duration get position => _position;
  Duration? get duration => _duration;
  String get lyricsText => _lyricsText;
  List<LyricLine> get lyricLines => _lyricLines;
  bool get lyricsLoaded => _lyricsLoaded;
  bool get hasSong => _songId != null;
  bool get likedMe => _likedMe;
  bool get likedParticipant => _likedParticipant;
  bool get likedAny => _likedMe || _likedParticipant;
  MusicLoopMode get loopMode => _loopMode;
  List<MusicTrack>? get contextList => _contextList;

  /// 「谁在放」标签：me=AI 助手放的 / participant=用户切的。
  String get sourceLabel => _source == 'participant' ? '用户切的' : 'AI 助手放的';

  /// 「谁点了红心」小字：都喜欢 / 用户喜欢 / AI 助手喜欢。
  String get likedLabel {
    if (_likedMe && _likedParticipant) return '都喜欢';
    if (_likedParticipant) return '用户喜欢';
    if (_likedMe) return 'AI 助手喜欢';
    return '';
  }

  /// 歌词当前高亮行（按播放进度，最后一行 time <= position）。
  int get lyricIndex {
    var idx = 0;
    for (var i = 0; i < _lyricLines.length; i++) {
      if (_lyricLines[i].time <= _position) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  // ── 循环模式 ──
  Future<void> _loadLoopMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_loopPrefsKey);
      if (saved == null) return;
      final mode = MusicLoopMode.fromKey(saved);
      if (mode == _loopMode) return;
      _loopMode = mode;
      await _applyLoopMode();
      notifyListeners();
    } catch (e) {
      debugPrint('[music] load loop mode error: $e');
    }
  }

  Future<void> _applyLoopMode() async {
    try {
      await _player.setLoopMode(
        _loopMode == MusicLoopMode.one ? LoopMode.one : LoopMode.off,
      );
    } catch (e) {
      debugPrint('[music] set loop mode error: $e');
    }
  }

  /// 列表循环 → 单曲循环 → 随机 → 列表循环。
  Future<void> cycleLoopMode() async {
    _loopMode = switch (_loopMode) {
      MusicLoopMode.list => MusicLoopMode.one,
      MusicLoopMode.one => MusicLoopMode.shuffle,
      MusicLoopMode.shuffle => MusicLoopMode.list,
    };
    notifyListeners();
    await _applyLoopMode();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_loopPrefsKey, _loopMode.key);
    } catch (e) {
      debugPrint('[music] save loop mode error: $e');
    }
  }

  // ── 启动：服务端状态恢复 + URL 过期续播 ──
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_restoreFromServer());
    Timer.periodic(const Duration(seconds: 8), (_) {
      _checkUrlExpiry();
    });
  }

  // ── type=music 消息 → 统一播放入口 ──
  Future<void> handlePendingMessage(Map<String, dynamic> m) async {
    final content = (m['content'] as String? ?? '').trim();
    if (content.isEmpty) return;
    Map<String, dynamic> payload;
    try {
      final j = jsonDecode(content);
      if (j is! Map) return;
      payload = j.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return;
    }
    switch (payload['action']?.toString()) {
      case 'play':
        await _handlePlayMessage(payload);
        break;
      case 'pause':
        _applyPause();
        break;
      case 'resume':
        _applyResume();
        break;
    }
  }

  Future<void> _handlePlayMessage(Map<String, dynamic> p) async {
    final id = (p['id'] as num?)?.toInt() ?? 0;
    final url = (p['url'] as String? ?? '').trim();
    // 去重：自己点的歌（/music/play 的回声）同 id 同 url → 跳过，不播两遍。
    // 同 id 且已载入：空 url（降级回声）或同 url（回声/刷新回声）都跳过；
    // 同 id 但 url 不同（服务端重新推同一首）→ 重新载入从头播。
    if (id != 0 && id == _songId && _loadedUrl.isNotEmpty) {
      if (url.isEmpty || url == _loadedUrl) {
        debugPrint('[music] play 消息同 id，跳过（回声）');
        return;
      }
    }
    final liked = p['liked'];
    await _playFromPayload(
      id: id,
      name: (p['name'] as String? ?? '').trim(),
      artist: (p['artist'] as String? ?? '').trim(),
      cover: (p['cover'] as String? ?? '').trim(),
      url: url,
      source: (p['source'] as String? ?? 'me').trim(),
      likedMe: liked is Map && liked['me'] == true,
      likedParticipant: liked is Map && liked['participant'] == true,
    );
  }

  /// 统一播放入口：载入并播放；返回是否真正播起来了（没 URL/载入失败 = false，
  /// 调用方据此决定要不要上报 source=participant）。
  Future<bool> _playFromPayload({
    required int id,
    required String name,
    required String artist,
    required String cover,
    required String url,
    required String source,
    bool likedMe = false,
    bool likedParticipant = false,
  }) async {
    _songId = id;
    _name = name;
    _artist = artist;
    _cover = cover;
    _source = source;
    _likedMe = likedMe;
    _likedParticipant = likedParticipant;
    _error = null;
    _lyricsText = '';
    _lyricLines = const [];
    _lyricsLoaded = false;
    _position = Duration.zero;
    _duration = null; // 新歌时长未知，等 just_audio 上报
    _playing = false;
    notifyListeners();
    unawaited(_loadLyrics(id));
    if (url.isEmpty) {
      _loadedUrl = '';
      _expireAt = 0;
      _playing = false;
      _error = '这首拿不到播放权，换一首试试';
      unawaited(MusicApi.pause()); // 服务端同步：没真正播起来
      notifyListeners();
      return false;
    }
    await _applyUrl(url, autoplay: true);
    return _playing;
  }

  /// 载入 URL 并播放（autoplay=false 只载入不播，seekTo 续播用）。
  Future<void> _applyUrl(
    String url, {
    required bool autoplay,
    Duration? seekTo,
  }) async {
    _loading = true;
    _expireAt = DateTime.now().millisecondsSinceEpoch / 1000 + _urlTtlSec;
    notifyListeners();
    try {
      await _player.setUrl(url);
      _loadedUrl = url;
      if (seekTo != null && seekTo > Duration.zero) {
        await _player.seek(seekTo);
      }
      if (autoplay) {
        _player.play();
        _playing = true;
      } else {
        _playing = false;
      }
      _error = null;
    } catch (e) {
      debugPrint('[music] setUrl error: $e');
      _loadedUrl = '';
      _expireAt = 0;
      _playing = false;
      _error = '播放失败，检查网络后重试';
      unawaited(MusicApi.pause());
    }
    _loading = false;
    notifyListeners();
  }

  void _applyPause() {
    if (!_playing) return;
    _player.pause();
    _playing = false;
    notifyListeners();
  }

  void _applyResume() {
    if (_playing) return;
    if (_loadedUrl.isEmpty) {
      // 有歌没 URL（比如 App 刚启动恢复）：取 URL 后播
      unawaited(_resumeWithFetch());
      return;
    }
    _player.play();
    _playing = true;
    notifyListeners();
  }

  Future<void> _resumeWithFetch() async {
    final id = _songId;
    if (id == null) return;
    final wasParticipant = _source == 'participant';
    final r = await MusicApi.play(id);
    if (!r.ok || r.url.isEmpty) {
      _error = r.error ?? '这首拿不到播放权，换一首试试';
      notifyListeners();
      return;
    }
    await _applyUrl(r.url, autoplay: true);
    if (wasParticipant) await _reportNextFromCurrent();
  }

  // ── 用户操作（MusicPage 共用）──
  Future<void> togglePlayPause() async {
    if (_songId == null) return;
    if (_playing) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> pause() async {
    if (!_playing) return;
    _player.pause();
    _playing = false;
    unawaited(MusicApi.pause());
    notifyListeners();
  }

  Future<void> resume() async {
    if (_playing) return;
    if (_loadedUrl.isEmpty) {
      await _resumeWithFetch();
      return;
    }
    _player.play();
    _playing = true;
    unawaited(MusicApi.resume());
    notifyListeners();
  }

  /// 点播一首歌（选歌区点歌/上一首/下一首共用）。
  /// [fromList] 提供切歌上下文；播放成功（或服务端已播放）后上报 /music/next
  /// source=participant，让「谁在放」= 用户切的（App 里所有用户发起的播放都是用户切的）。
  Future<void> playSong(
    MusicTrack track, {
    List<MusicTrack>? fromList,
    bool auto = false,
  }) async {
    if (fromList != null) {
      _contextList = fromList;
      _contextIndex = fromList.indexWhere((t) => t.id == track.id);
    }
    _error = null;
    notifyListeners();
    final r = await MusicApi.play(track.id);
    if (r.ok) {
      final started = await _playFromPayload(
        id: r.songId ?? track.id,
        name: r.name.isEmpty ? track.name : r.name,
        artist: r.artist.isEmpty ? track.artist : r.artist,
        cover: r.cover.isEmpty ? track.cover : r.cover,
        url: r.url,
        source: r.source,
        likedMe: r.likedMe,
        likedParticipant: r.likedParticipant,
      );
      // 真正播起来了才上报「用户切的」（失败时服务端保持源状态）；
      // auto=true 是自动放完切下一首，跟手动切歌分开上报（v0.2.181）
      if (started) await _reportNextFromCurrent(auto: auto);
    } else {
      _error = r.error ?? '播放失败';
      notifyListeners();
    }
  }

  /// 下一首：列表循环按切歌上下文/历史顺序走（到底循环）；随机从列表/历史随机选。
  Future<void> next() async {
    if (_loopMode == MusicLoopMode.shuffle) {
      await _playRandomNext();
      return;
    }
    await _playSequentialNext(wrap: true);
  }

  /// 上一首：优先最后一次选歌列表里的上一首（搜索/歌单/每日推荐）；
  /// 列表里没有/已在列表头时，从 /music/history 取当前歌的上一首兜底
  /// （历史最新在前，当前歌在历史里 → 取它后一条 = 最近播过的上一首）。
  Future<void> prev() async {
    final list = _contextList;
    if (list != null && list.isNotEmpty && _contextIndex > 0) {
      await _step(-1);
      return;
    }
    final history = await MusicApi.history();
    if (history.isEmpty) return;
    final tracks = [for (final e in history) e.toTrack()];
    final idx = tracks.indexWhere((t) => t.id == _songId);
    MusicTrack? target;
    if (idx >= 0 && idx + 1 < tracks.length) {
      target = tracks[idx + 1];
    } else if (idx < 0) {
      target = tracks.first; // 当前歌不在历史（异常态）：回最近播过的
    }
    if (target == null) return;
    await playSong(target, fromList: tracks);
  }

  Future<void> _step(int delta, {bool auto = false}) async {
    final list = _contextList;
    if (list == null || list.isEmpty || _contextIndex < 0) return;
    final idx = _contextIndex + delta;
    if (idx < 0 || idx >= list.length) return;
    await playSong(list[idx], fromList: list, auto: auto);
  }

  /// 顺序下一首：优先最后一次选歌列表；没有则用播放历史兜底。
  Future<void> _playSequentialNext({
    bool wrap = false,
    bool auto = false,
  }) async {
    final list = _contextList;
    if (list != null && list.isNotEmpty) {
      var idx = _contextIndex + 1;
      if (idx >= list.length) {
        if (!wrap) return;
        idx = 0;
      }
      await playSong(list[idx], fromList: list, auto: auto);
      return;
    }
    final tracks = await _historyTracksOrEmpty();
    if (tracks.isEmpty) return;
    final current = tracks.indexWhere((t) => t.id == _songId);
    MusicTrack? target;
    if (current >= 0) {
      if (current - 1 >= 0) {
        target = tracks[current - 1]; // 历史最新在前，下一首=更新的
      } else if (wrap) {
        target = tracks.last; // 已在最新，循环回最旧
      }
    } else {
      target = tracks.first;
    }
    if (target != null) await playSong(target, fromList: tracks, auto: auto);
  }

  /// 随机下一首：优先最后一次选歌列表；没有则用播放历史兜底。
  Future<void> _playRandomNext({bool auto = false}) async {
    final list = _contextList;
    if (list != null && list.isNotEmpty) {
      if (list.length == 1) {
        await playSong(list.first, fromList: list, auto: auto);
        return;
      }
      var idx = _contextIndex;
      while (idx < 0 || idx == _contextIndex) {
        idx = Random().nextInt(list.length);
      }
      await playSong(list[idx], fromList: list, auto: auto);
      return;
    }
    final tracks = await _historyTracksOrEmpty();
    if (tracks.isEmpty) return;
    if (tracks.length == 1) {
      await playSong(tracks.first, fromList: tracks, auto: auto);
      return;
    }
    final current = tracks.indexWhere((t) => t.id == _songId);
    var idx = Random().nextInt(tracks.length);
    while (current >= 0 && idx == current) {
      idx = Random().nextInt(tracks.length);
    }
    await playSong(tracks[idx], fromList: tracks, auto: auto);
  }

  Future<List<MusicTrack>> _historyTracksOrEmpty() async {
    final history = await MusicApi.history();
    return [for (final e in history) e.toTrack()];
  }

  /// 拖动进度条 seek（本地，不影响服务端进度口径）。
  Future<void> seek(Duration target) async {
    await _player.seek(target);
    _position = target;
    notifyListeners();
  }

  /// 上报 source=participant（用户切的）：8816 存状态，不推回。
  Future<void> _reportNextFromCurrent({bool auto = false}) async {
    final id = _songId;
    if (id == null) return;
    final r = await MusicApi.next(
      id: id,
      name: _name,
      artist: _artist,
      cover: _cover,
      duration: _duration?.inSeconds,
      trigger: auto ? 'auto' : 'manual',
    );
    if (r.ok) {
      _likedMe = r.likedMe;
      _likedParticipant = r.likedParticipant;
    }
    _source = 'participant';
    notifyListeners();
  }

  /// 红心（Continuum Chat自己的，不碰网易云）：点/取消同步 8816，返回最新状态。
  /// App 侧默认 who=participant（用户点的）；AI 助手的红心状态由后端记，App 展示。
  Future<void> toggleLike({String who = 'participant'}) async {
    final id = _songId;
    if (id == null) return;
    final like = who == 'participant' ? !_likedParticipant : !_likedMe;
    final r = await MusicApi.like(id: id, who: who, like: like);
    if (!r.ok) return;
    _likedMe = r.likedMe;
    _likedParticipant = r.likedParticipant;
    notifyListeners();
  }

  // ── URL 过期续播：提前 30 秒重新拿 URL，从当前进度续 ──
  void _checkUrlExpiry() {
    if (_expiryRefreshing ||
        _songId == null ||
        !_playing ||
        _loadedUrl.isEmpty) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (now < _expireAt - _urlRefreshAheadSec) return;
    _expiryRefreshing = true;
    final id = _songId!;
    final pos = _player.position;
    final wasParticipant = _source == 'participant';
    unawaited(() async {
      try {
        final r = await MusicApi.play(id);
        if (r.ok && r.url.isNotEmpty) {
          await _applyUrl(r.url, autoplay: true, seekTo: pos);
          if (wasParticipant) await _reportNextFromCurrent();
        } else {
          debugPrint('[music] 刷新 URL 失败: ${r.error}');
        }
      } finally {
        _expiryRefreshing = false;
      }
    }());
  }

  // ── 歌词 ──
  Future<void> _loadLyrics(int id) async {
    final lrc = await MusicApi.lyrics(id);
    _lyricsText = lrc;
    _lyricLines = parseLrc(lrc);
    _lyricsLoaded = true;
    notifyListeners();
  }

  // ── 启动恢复：服务端当前播放状态 → 续播 ──
  Future<void> _restoreFromServer() async {
    if (_restoring) return;
    _restoring = true;
    try {
      final cur = await MusicApi.current();
      if (cur == null) return;
      if (cur.songId == _songId) return; // 已经同步过
      _songId = cur.songId;
      _name = cur.name;
      _artist = cur.artist;
      _cover = cur.coverUrl;
      _source = cur.source;
      _likedMe = cur.likedMe;
      _likedParticipant = cur.likedParticipant;
      _playing = false;
      _loadedUrl = '';
      _expireAt = 0;
      _error = null;
      _lyricsText = '';
      _lyricLines = const [];
      _lyricsLoaded = false;
      _position = Duration.zero;
      notifyListeners();
      unawaited(_loadLyrics(cur.songId));
      if (cur.playing) {
        // 服务端还在播（App 重启续播）：POST /music/play 拿 URL 从服务端进度续
        final wasParticipant = cur.source == 'participant';
        final r = await MusicApi.play(cur.songId);
        if (r.ok && r.url.isNotEmpty) {
          final progress = Duration(seconds: cur.progressSec);
          await _applyUrl(r.url, autoplay: true, seekTo: progress);
          if (wasParticipant) await _reportNextFromCurrent();
        }
      }
    } catch (e) {
      debugPrint('[music] restore error: $e');
    } finally {
      _restoring = false;
    }
  }

  // ── 音频事件 ──
  void _listenAudio() {
    _player.positionStream.listen((p) {
      if (p != _position) {
        _position = p;
        notifyListeners();
      }
    });
    _player.durationStream.listen((d) {
      if (d != _duration) {
        _duration = d;
        notifyListeners();
      }
    });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && _playing) {
        // 一首播完：单曲循环交给 just_audio 自动重复；列表/随机切下一首。
        if (_loopMode == MusicLoopMode.one) return;
        _playing = false;
        notifyListeners();
        unawaited(_handleSongCompleted());
      }
    });
  }

  Future<void> _handleSongCompleted() async {
    if (_songId == null) return;
    if (_loopMode == MusicLoopMode.shuffle) {
      await _playRandomNext(auto: true);
    } else {
      await _playSequentialNext(wrap: true, auto: true);
    }
    if (!_playing) {
      // 没有下一首/切歌失败：服务端同步暂停，避免状态漂移。
      unawaited(MusicApi.pause());
    }
  }
}

/// LRC 歌词行。
class LyricLine {
  final Duration time;
  final String text;

  const LyricLine(this.time, this.text);
}

/// 解析 lrc 文本 → 按时间排序的歌词行（无时间标记的行丢弃）。
List<LyricLine> parseLrc(String lrc) {
  final lines = <LyricLine>[];
  final re = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  for (final raw in lrc.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final matches = re.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final text = line.substring(matches.last.end).trim();
    for (final m in matches) {
      final min = int.tryParse(m.group(1) ?? '') ?? 0;
      final sec = int.tryParse(m.group(2) ?? '') ?? 0;
      var msStr = m.group(3) ?? '0';
      while (msStr.length < 3) {
        msStr = '${msStr}0';
      }
      final ms = int.tryParse(msStr) ?? 0;
      lines.add(
        LyricLine(Duration(minutes: min, seconds: sec, milliseconds: ms), text),
      );
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// mm:ss 时间文本（进度条两侧用）。
String fmtDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
