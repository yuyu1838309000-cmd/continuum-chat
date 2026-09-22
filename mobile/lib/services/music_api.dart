import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

/// 一起听歌接口（8816 /music/*，v0.2.133）。
/// 全部请求带 X-Token（ChatApi.authHeaders，v0.2.132 教训：8816 认证本机放行、
/// 外部必须带 token）。播放 URL 20 分钟过期，URL/歌词/封面拿不到时后端降级为空，
/// 这里解析同样降级不抛。
class MusicApi {
  MusicApi._();

  static Uri _url(String path) => Uri.parse(ServerConfig.url(8816, path));

  /// 搜索结果的歌（含歌单/每日推荐列表项）。
  static MusicTrack trackOf(Map<String, dynamic> j) => MusicTrack(
    id: (j['id'] as num? ?? 0).toInt(),
    name: (j['name'] as String? ?? '').trim(),
    artist: (j['artist'] as String? ?? '').trim(),
    cover: (j['cover'] as String? ?? '').trim(),
    duration: (j['duration'] as num? ?? 0).toInt(),
  );

  /// GET /music/current：当前播放状态；无播放返回 null（失败也 null，不抛）。
  static Future<MusicCurrent?> current() async {
    try {
      final resp = await http
          .get(_url('/music/current'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['song_id'] == null) return null;
      final liked = j['liked'];
      return MusicCurrent(
        songId: (j['song_id'] as num).toInt(),
        name: (j['name'] as String? ?? '').trim(),
        artist: (j['artist'] as String? ?? '').trim(),
        coverUrl: (j['cover_url'] as String? ?? '').trim(),
        playing: j['playing'] == true,
        progressSec: (j['progress_sec'] as num? ?? 0).toInt(),
        durationSec: (j['duration_sec'] as num?)?.toInt(),
        source: (j['source'] as String? ?? 'me').trim(),
        likedMe: liked is Map && liked['me'] == true,
        likedParticipant: liked is Map && liked['participant'] == true,
      );
    } catch (e) {
      debugPrint('[music] current error: $e');
      return null;
    }
  }

  /// POST /music/play {id}：点播/取播放 URL（后端会推一条 type=music play 消息，
  /// App 靠 id 去重不播两遍）。url 空 = 这首拿不到播放权。
  static Future<MusicPlayResult> play(int id) async {
    try {
      final resp = await http
          .post(
            _url('/music/play'),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'id': id}),
          )
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map) return const MusicPlayResult(ok: false, error: '服务器返回异常');
      if (j['ok'] == false) {
        return MusicPlayResult(
          ok: false,
          error: (j['error'] as String? ?? '播放失败').trim(),
        );
      }
      final liked = j['liked'];
      return MusicPlayResult(
        ok: true,
        songId: (j['song_id'] as num? ?? id).toInt(),
        name: (j['name'] as String? ?? '').trim(),
        artist: (j['artist'] as String? ?? '').trim(),
        cover: (j['cover'] as String? ?? '').trim(),
        url: (j['url'] as String? ?? '').trim(),
        source: (j['source'] as String? ?? 'me').trim(),
        durationSec: (j['duration_sec'] as num?)?.toInt(),
        likedMe: liked is Map && liked['me'] == true,
        likedParticipant: liked is Map && liked['participant'] == true,
      );
    } catch (e) {
      debugPrint('[music] play error: $e');
      return const MusicPlayResult(ok: false, error: '网络异常，播放失败');
    }
  }

  /// POST /music/pause / /music/resume：改服务端播放状态，返回是否成功。
  static Future<bool> pause() async => _setPlaying('/music/pause');
  static Future<bool> resume() async => _setPlaying('/music/resume');

  static Future<bool> _setPlaying(String path) async {
    try {
      final resp = await http
          .post(
            _url(path),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(const {}),
          )
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /music/next：用户切歌上报（source=participant），8816 存状态不推回。
  /// trigger：manual=手动切歌 / auto=自动放完切下一首（v0.2.181 区分来源，
  /// 自动切歌不再触发"连切/循环"提醒）。
  static Future<MusicLikeResult> next({
    required int id,
    required String name,
    required String artist,
    required String cover,
    int? duration,
    String trigger = 'manual',
  }) async {
    try {
      final resp = await http
          .post(
            _url('/music/next'),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'id': id,
              'name': name,
              'artist': artist,
              'cover': cover,
              'duration': duration,
              'source': 'participant',
              'trigger': trigger,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const MusicLikeResult(ok: false);
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      final liked = j is Map ? j['liked'] : null;
      return MusicLikeResult(
        ok: true,
        likedMe: liked is Map && liked['me'] == true,
        likedParticipant: liked is Map && liked['participant'] == true,
      );
    } catch (_) {
      return const MusicLikeResult(ok: false);
    }
  }

  /// GET /music/history：播放历史（最新在前，含红心状态）；无记录/失败返回空列表。
  static Future<List<MusicHistoryEntry>> history() async {
    try {
      final resp = await http
          .get(_url('/music/history'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! List) return const [];
      return [
        for (final e in j)
          if (e is Map<String, dynamic>) historyEntryOf(e),
      ];
    } catch (e) {
      debugPrint('[music] history error: $e');
      return const [];
    }
  }

  /// POST /music/like {id, who, like}：Continuum Chat自己的红心（不碰网易云）。
  /// 返回最新红心状态。
  static Future<MusicLikeResult> like({
    required int id,
    required String who,
    required bool like,
  }) async {
    try {
      final resp = await http
          .post(
            _url('/music/like'),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({'id': id, 'who': who, 'like': like}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const MusicLikeResult(ok: false);
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true) {
        return const MusicLikeResult(ok: false);
      }
      final liked = j['liked'];
      return MusicLikeResult(
        ok: true,
        likedMe: liked is Map && liked['me'] == true,
        likedParticipant: liked is Map && liked['participant'] == true,
      );
    } catch (e) {
      debugPrint('[music] like error: $e');
      return const MusicLikeResult(ok: false);
    }
  }

  /// GET /music/search?q=：云搜歌，前 10 条；失败返回空列表。
  static Future<List<MusicTrack>> search(String q) async {
    try {
      final resp = await http
          .get(
            _url('/music/search?q=${Uri.encodeQueryComponent(q)}'),
            headers: ChatApi.authHeaders(),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true || j['results'] is! List) {
        return const [];
      }
      return [
        for (final e in j['results'])
          if (e is Map<String, dynamic>) trackOf(e),
      ];
    } catch (e) {
      debugPrint('[music] search error: $e');
      return const [];
    }
  }

  /// GET /music/playlists：我的歌单列表；失败返回空列表。
  static Future<List<MusicPlaylist>> playlists() async {
    try {
      final resp = await http
          .get(_url('/music/playlists'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true || j['playlists'] is! List) {
        return const [];
      }
      return [
        for (final e in j['playlists'])
          if (e is Map<String, dynamic>)
            MusicPlaylist(
              id: (e['id'] as num? ?? 0).toInt(),
              name: (e['name'] as String? ?? '').trim(),
              trackCount: (e['track_count'] as num? ?? 0).toInt(),
            ),
      ];
    } catch (e) {
      debugPrint('[music] playlists error: $e');
      return const [];
    }
  }

  /// GET /music/playlist?id=N：歌单内歌曲；失败返回空列表。
  static Future<List<MusicTrack>> playlistTracks(int id) async {
    try {
      final resp = await http
          .get(_url('/music/playlist?id=$id'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true || j['tracks'] is! List) {
        return const [];
      }
      return [
        for (final e in j['tracks'])
          if (e is Map<String, dynamic>) trackOf(e),
      ];
    } catch (e) {
      debugPrint('[music] playlist detail error: $e');
      return const [];
    }
  }

  /// GET /music/daily：每日推荐；失败返回空列表。
  static Future<List<MusicTrack>> daily() async {
    try {
      final resp = await http
          .get(_url('/music/daily'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return const [];
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true || j['tracks'] is! List) {
        return const [];
      }
      return [
        for (final e in j['tracks'])
          if (e is Map<String, dynamic>) trackOf(e),
      ];
    } catch (e) {
      debugPrint('[music] daily error: $e');
      return const [];
    }
  }

  /// GET /music/lyrics?id=N：lrc 歌词文本；无词/失败返回空串。
  static Future<String> lyrics(int id) async {
    try {
      final resp = await http
          .get(_url('/music/lyrics?id=$id'), headers: ChatApi.authHeaders())
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return '';
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is! Map || j['ok'] != true) return '';
      return (j['lyrics'] as String? ?? '').trim();
    } catch (e) {
      debugPrint('[music] lyrics error: $e');
      return '';
    }
  }
}

/// 歌曲条目（搜索结果/歌单/每日推荐列表项）。
class MusicTrack {
  final int id;
  final String name;
  final String artist;
  final String cover;
  final int duration; // 秒，0=未知

  const MusicTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.cover,
    this.duration = 0,
  });
}

/// 歌单（我的歌单列表项）。
class MusicPlaylist {
  final int id;
  final String name;
  final int trackCount;

  const MusicPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
  });
}

/// GET /music/current 当前播放状态。
class MusicCurrent {
  final int songId;
  final String name;
  final String artist;
  final String coverUrl;
  final bool playing;
  final int progressSec;
  final int? durationSec;
  final String source;
  final bool likedMe;
  final bool likedParticipant;

  const MusicCurrent({
    required this.songId,
    required this.name,
    required this.artist,
    required this.coverUrl,
    required this.playing,
    required this.progressSec,
    required this.durationSec,
    required this.source,
    this.likedMe = false,
    this.likedParticipant = false,
  });
}

/// POST /music/play 结果。
class MusicPlayResult {
  final bool ok;
  final String? error;
  final int? songId;
  final String name;
  final String artist;
  final String cover;
  final String url;
  final String source;
  final int? durationSec;
  final bool likedMe;
  final bool likedParticipant;

  const MusicPlayResult({
    required this.ok,
    this.error,
    this.songId,
    this.name = '',
    this.artist = '',
    this.cover = '',
    this.url = '',
    this.source = 'me',
    this.durationSec,
    this.likedMe = false,
    this.likedParticipant = false,
  });
}

/// 播放历史条目（GET /music/history 项）。
class MusicHistoryEntry {
  final int songId;
  final String name;
  final String artist;
  final String cover;
  final int playedAt; // epoch 秒
  final bool likedMe;
  final bool likedParticipant;

  const MusicHistoryEntry({
    required this.songId,
    required this.name,
    required this.artist,
    required this.cover,
    required this.playedAt,
    required this.likedMe,
    required this.likedParticipant,
  });

  bool get likedAny => likedMe || likedParticipant;

  /// 转成选歌条目（历史重播走现有播放入口）。
  MusicTrack toTrack() =>
      MusicTrack(id: songId, name: name, artist: artist, cover: cover);
}

MusicHistoryEntry historyEntryOf(Map<String, dynamic> j) {
  final liked = j['liked'];
  return MusicHistoryEntry(
    songId: (j['song_id'] as num? ?? 0).toInt(),
    name: (j['name'] as String? ?? '').trim(),
    artist: (j['artist'] as String? ?? '').trim(),
    cover: (j['cover'] as String? ?? '').trim(),
    playedAt: (j['played_at'] as num? ?? 0).toInt(),
    likedMe: liked is Map && liked['me'] == true,
    likedParticipant: liked is Map && liked['participant'] == true,
  );
}

/// 红心操作结果（like/next 共用：ok + 最新红心状态）。
class MusicLikeResult {
  final bool ok;
  final bool likedMe;
  final bool likedParticipant;

  const MusicLikeResult({
    required this.ok,
    this.likedMe = false,
    this.likedParticipant = false,
  });
}
