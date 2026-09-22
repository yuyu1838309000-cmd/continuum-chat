import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'chat_api.dart';
import 'server_config.dart';

/// 旅行（nowhere 8077 只读展示）：8816 GET /nowhere/data 透传 ~/.nowhere/ 5 个 JSON。
/// 返回 {journey, visits, postcards:{items}, sightings:{items}, landings}，失败返回 null。
class TravelApi {
  TravelApi._();

  static Future<Map<String, dynamic>?> fetch() async {
    try {
      final resp = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/nowhere/data')),
            headers: ChatApi.authHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      return j is Map<String, dynamic> ? j : null;
    } catch (e) {
      debugPrint('[travel] fetch error: $e');
      return null;
    }
  }
}

/// 明信片盖戳信息。
class PostcardStamp {
  final String place;
  final double lat;
  final double lon;
  final int elevation;
  final String localTime;
  final String weather;
  final double? tempC;
  final String surface;
  final String phase;

  const PostcardStamp({
    required this.place,
    required this.lat,
    required this.lon,
    required this.elevation,
    required this.localTime,
    required this.weather,
    required this.tempC,
    required this.surface,
    required this.phase,
  });

  factory PostcardStamp.fromJson(Map<String, dynamic> j) => PostcardStamp(
    place: (j['place'] as String? ?? '').trim(),
    lat: (j['lat'] as num?)?.toDouble() ?? 0,
    lon: (j['lon'] as num?)?.toDouble() ?? 0,
    elevation: (j['elevation'] as num?)?.toInt() ?? 0,
    localTime: (j['local_time'] as String? ?? '').trim(),
    weather: (j['weather'] as String? ?? '').trim(),
    tempC: (j['temp_c'] as num?)?.toDouble(),
    surface: (j['surface'] as String? ?? '').trim(),
    phase: (j['phase'] as String? ?? '').trim(),
  );

  String get tempLabel => tempC != null
      ? '${tempC! >= 0 ? '+' : ''}${tempC!.toStringAsFixed(1)}°C'
      : '';
}

/// 明信片。
class Postcard {
  final int id;
  final String text;
  final PostcardStamp? stamp;
  final String frontImg;

  const Postcard({
    required this.id,
    required this.text,
    required this.stamp,
    required this.frontImg,
  });

  factory Postcard.fromJson(Map<String, dynamic> j) => Postcard(
    id: (j['id'] as num?)?.toInt() ?? 0,
    text: (j['text'] as String? ?? '').trim(),
    stamp: j['stamp'] is Map<String, dynamic>
        ? PostcardStamp.fromJson(j['stamp'] as Map<String, dynamic>)
        : null,
    frontImg: (j['front_img'] as String? ?? '').trim(),
  );
}

/// 明信片展示顺序：优先按盖戳当地时间倒序，时间缺失时按 id 倒序。
List<Postcard> sortTravelPostcardsNewestFirst(Iterable<Postcard> postcards) {
  return postcards.toList()..sort(_comparePostcardsNewestFirst);
}

int _comparePostcardsNewestFirst(Postcard a, Postcard b) {
  final aTime = _parsePostcardLocalTime(a.stamp?.localTime ?? '');
  final bTime = _parsePostcardLocalTime(b.stamp?.localTime ?? '');
  if (aTime != null && bTime != null) {
    final byTime = bTime.compareTo(aTime);
    if (byTime != 0) return byTime;
  }
  return b.id.compareTo(a.id);
}

DateTime? _parsePostcardLocalTime(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final parsed = DateTime(year, month, day, hour, minute);
  if (parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute) {
    return null;
  }
  return parsed;
}

/// 见闻。
class Sighting {
  final String name;
  final String commonName;
  final double lat;
  final double lon;
  final int distanceM;
  final String seenAt;

  const Sighting({
    required this.name,
    required this.commonName,
    required this.lat,
    required this.lon,
    required this.distanceM,
    required this.seenAt,
  });

  factory Sighting.fromJson(Map<String, dynamic> j) => Sighting(
    name: (j['name'] as String? ?? '').trim(),
    commonName: (j['common_name'] as String? ?? '').trim(),
    lat: (j['lat'] as num?)?.toDouble() ?? 0,
    lon: (j['lon'] as num?)?.toDouble() ?? 0,
    distanceM: (j['distance_m'] as num?)?.toInt() ?? 0,
    seenAt: (j['seen_at'] as String? ?? '').trim(),
  );

  String get displayName => commonName.isEmpty ? name : '$commonName（$name）';
}

/// 登陆点。
class Landing {
  final String place;
  final double lat;
  final double lon;
  final int count;
  final int elevation;
  final String surface;
  final String last;

  const Landing({
    required this.place,
    required this.lat,
    required this.lon,
    required this.count,
    required this.elevation,
    required this.surface,
    required this.last,
  });

  factory Landing.fromJson(String key, Map<String, dynamic> j) => Landing(
    place: (j['place'] as String? ?? '').trim().isEmpty
        ? key
        : (j['place'] as String? ?? '').trim(),
    lat: (j['lat'] as num?)?.toDouble() ?? 0,
    lon: (j['lon'] as num?)?.toDouble() ?? 0,
    count: (j['count'] as num?)?.toInt() ?? 0,
    elevation: (j['elevation'] as num?)?.toInt() ?? 0,
    surface: (j['surface'] as String? ?? '').trim(),
    last: (j['last'] as String? ?? '').trim(),
  );
}
