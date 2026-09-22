import 'package:flutter/foundation.dart';

import '../models/pixel_home.dart';
import '../models/reading_book.dart';
import 'api_cache.dart';
import 'chat_api.dart';
import 'music_player.dart';
import 'reading_data_parser.dart';
import 'server_config.dart';
import 'travel_api.dart';

typedef TogetherHomeSummaryLoader =
    Future<TogetherHomeSummary?> Function({
      void Function(TogetherHomeSummary summary)? onCached,
    });
typedef TogetherReadingSummaryLoader =
    Future<TogetherReadingSummary?> Function({
      void Function(TogetherReadingSummary summary)? onCached,
    });
typedef TogetherTravelSummaryLoader =
    Future<TogetherTravelSummary?> Function({
      void Function(TogetherTravelSummary summary)? onCached,
    });
typedef TogetherMusicSummaryReader = TogetherMusicSummary Function();

class TogetherHomePersonSummary {
  const TogetherHomePersonSummary({
    required this.name,
    required this.room,
    required this.action,
  });

  final String name;
  final String room;
  final String action;
}

class TogetherHomeSummary {
  const TogetherHomeSummary(this.people);

  final List<TogetherHomePersonSummary> people;
}

class TogetherMusicSummary {
  const TogetherMusicSummary({
    required this.title,
    required this.artist,
    required this.playing,
  });

  const TogetherMusicSummary.empty() : title = '', artist = '', playing = false;

  final String title;
  final String artist;
  final bool playing;

  bool get hasSong => title.isNotEmpty;
}

class TogetherReadingSummary {
  const TogetherReadingSummary({required this.book, required this.activeCount});

  final ReadingBook? book;
  final int activeCount;
}

class TogetherTravelSummary {
  const TogetherTravelSummary({
    required this.title,
    required this.detail,
    required this.fromPostcard,
  });

  const TogetherTravelSummary.empty()
    : title = '',
      detail = '',
      fromPostcard = false;

  final String title;
  final String detail;
  final bool fromPostcard;

  bool get hasContent => title.isNotEmpty || detail.isNotEmpty;
}

/// Together 首页所需的最小只读摘要。三路远端数据各自缓存、各自失败。
class TogetherSummaryService {
  TogetherSummaryService._();

  static Future<TogetherHomeSummary?> home({
    void Function(TogetherHomeSummary summary)? onCached,
  }) {
    final url = ServerConfig.url(8089, '/state_new.json');
    return _cachedFirst(
      url: url,
      parse: parseHome,
      onCached: onCached,
      utf8Body: true,
    );
  }

  static TogetherMusicSummary music() {
    final player = MusicPlayer.instance;
    if (!player.hasSong) return const TogetherMusicSummary.empty();
    return TogetherMusicSummary(
      title: player.name.trim(),
      artist: player.artist.trim(),
      playing: player.playing,
    );
  }

  static Future<TogetherReadingSummary?> reading({
    void Function(TogetherReadingSummary summary)? onCached,
  }) {
    final url = ServerConfig.url(8070, '/read_data.json');
    return _cachedFirst(
      url: url,
      parse: parseReading,
      onCached: onCached,
      utf8Body: true,
    );
  }

  static Future<TogetherTravelSummary?> travel({
    void Function(TogetherTravelSummary summary)? onCached,
  }) {
    final url = ServerConfig.url(8816, '/nowhere/data');
    return _cachedFirst(
      url: url,
      parse: parseTravel,
      onCached: onCached,
      headers: ChatApi.authHeaders(),
      utf8Body: true,
    );
  }

  static Future<T?> _cachedFirst<T>({
    required String url,
    required T? Function(Object? raw) parse,
    required void Function(T value)? onCached,
    Map<String, String>? headers,
    bool utf8Body = false,
  }) async {
    final cached = parse(await ApiCache.read(url));
    if (cached != null) {
      onCached?.call(cached);
      if (!await ApiCache.isExpired(url)) return cached;
    }

    final raw = await ApiCache.fetchJson(
      url,
      headers: headers,
      utf8Body: utf8Body,
      timeout: const Duration(seconds: 10),
    );
    return parse(raw) ?? cached;
  }

  @visibleForTesting
  static TogetherHomeSummary? parseHome(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final home = PixelHome.fromJson(raw);
    final people = [
      _person('AI 助手', home.me),
      _person('用户', home.appUser),
      _person('猫咪', home.cat),
    ];
    return TogetherHomeSummary([
      for (final person in people)
        if (person.room.isNotEmpty || person.action.isNotEmpty) person,
    ]);
  }

  static TogetherHomePersonSummary _person(String name, CharacterState state) =>
      TogetherHomePersonSummary(
        name: name,
        room: _roomLabel(state.room),
        action: state.action,
      );

  static String _roomLabel(String room) => switch (room) {
    '' => '',
    'out' => '出门了',
    'gameroom' => '游戏房',
    'bedroom' => '卧室',
    'balcony' => '阳台',
    'living' => '客厅',
    'kitchen' => '厨房',
    'dining' => '餐厅',
    'storage' => '储物间',
    _ => room,
  };

  @visibleForTesting
  static TogetherReadingSummary? parseReading(Object? raw) {
    final books = parseReadingBooks(raw);
    if (books == null) return null;
    final active = [
      for (final book in books)
        if (book.status == '正在看') book,
    ];
    return TogetherReadingSummary(
      book: active.isEmpty ? null : active.first,
      activeCount: active.length,
    );
  }

  @visibleForTesting
  static TogetherTravelSummary? parseTravel(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final journey = raw['journey'];
    if (journey is Map<String, dynamic>) {
      final place = (journey['place_name'] as String? ?? '').trim();
      final detail = (journey['last_text'] as String? ?? '').trim();
      if (place.isNotEmpty || detail.isNotEmpty) {
        return TogetherTravelSummary(
          title: place.isEmpty ? '在路上' : place,
          detail: detail,
          fromPostcard: false,
        );
      }
    }

    final postcards = raw['postcards'];
    final items = postcards is Map<String, dynamic> ? postcards['items'] : null;
    if (items is List) {
      final parsed = sortTravelPostcardsNewestFirst([
        for (final item in items)
          if (item is Map<String, dynamic>) Postcard.fromJson(item),
      ]);
      if (parsed.isNotEmpty) {
        final postcard = parsed.first;
        return TogetherTravelSummary(
          title: postcard.stamp?.place.trim().isNotEmpty == true
              ? postcard.stamp!.place.trim()
              : '最近的明信片',
          detail: postcard.text,
          fromPostcard: true,
        );
      }
    }
    return const TogetherTravelSummary.empty();
  }
}
