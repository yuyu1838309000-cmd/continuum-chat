import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_api.dart';
import 'server_config.dart';

enum MediaFeature { ocr, stt, image }

extension on MediaFeature {
  String get apiName => name;
}

class MediaFeatureConfig {
  const MediaFeatureConfig({
    this.apiUrl = '',
    this.model = '',
    this.imageSize = '',
    this.keyConfigured = false,
    this.configured = false,
  });

  factory MediaFeatureConfig.fromJson(Map<String, dynamic> json) {
    return MediaFeatureConfig(
      apiUrl: json['api_url']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      imageSize: json['image_size']?.toString() ?? '',
      keyConfigured: json['key_configured'] == true,
      configured: json['configured'] == true,
    );
  }

  final String apiUrl;
  final String model;
  final String imageSize;
  final bool keyConfigured;
  final bool configured;

  Map<String, dynamic> toJson() => {
    'api_url': apiUrl,
    'model': model,
    if (imageSize.isNotEmpty) 'image_size': imageSize,
    'key_configured': keyConfigured,
    'configured': configured,
  };
}

class MediaConfigSnapshot {
  const MediaConfigSnapshot({
    this.ocr = const MediaFeatureConfig(),
    this.stt = const MediaFeatureConfig(),
    this.image = const MediaFeatureConfig(imageSize: '1024x1024'),
  });

  factory MediaConfigSnapshot.fromJson(Map<String, dynamic> json) {
    final rawFeatures = json['features'];
    final features = rawFeatures is Map ? rawFeatures : const {};
    MediaFeatureConfig read(String name, {String fallbackSize = ''}) {
      final raw = features[name];
      if (raw is Map) {
        return MediaFeatureConfig.fromJson(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      return MediaFeatureConfig(imageSize: fallbackSize);
    }

    return MediaConfigSnapshot(
      ocr: read('ocr'),
      stt: read('stt'),
      image: read('image', fallbackSize: '1024x1024'),
    );
  }

  final MediaFeatureConfig ocr;
  final MediaFeatureConfig stt;
  final MediaFeatureConfig image;

  MediaFeatureConfig feature(MediaFeature feature) => switch (feature) {
    MediaFeature.ocr => ocr,
    MediaFeature.stt => stt,
    MediaFeature.image => image,
  };

  Map<String, dynamic> toJson() => {
    'features': {
      'ocr': ocr.toJson(),
      'stt': stt.toJson(),
      'image': image.toJson(),
    },
  };
}

/// Server-owned OCR/STT/image configuration with a public local cache.
///
/// The cache never contains an API key. [load] surfaces it first, then refreshes
/// from 8816. Saves are field-level: an omitted key keeps the server secret,
/// while [updateApiKey] with an empty value explicitly clears it.
class MediaConfigApi {
  static const String _cacheKey = 'media_config_cache_v1';

  Future<MediaConfigSnapshot> load({
    void Function(MediaConfigSnapshot cached)? onCache,
  }) async {
    final cached = await loadCached();
    if (cached != null) onCache?.call(cached);
    return await fetch() ?? cached ?? const MediaConfigSnapshot();
  }

  Future<MediaConfigSnapshot?> loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return MediaConfigSnapshot.fromJson(decoded);
      }
    } on FormatException {
      // Ignore a corrupt cache and refresh from the server.
    }
    return null;
  }

  Future<MediaConfigSnapshot?> fetch() async {
    try {
      final response = await http
          .get(
            Uri.parse(ServerConfig.url(8816, '/media-config')),
            headers: ChatApi.authHeaders(),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['features'] is! Map) {
        return null;
      }
      final snapshot = MediaConfigSnapshot.fromJson(decoded);
      await _cache(snapshot);
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<MediaConfigSnapshot> save(
    MediaFeature feature, {
    String? apiUrl,
    String? model,
    String? imageSize,
    String? apiKey,
    bool updateApiKey = false,
  }) async {
    final body = <String, dynamic>{
      'feature': feature.apiName,
      if (apiUrl != null) 'api_url': apiUrl.trim(),
      if (model != null) 'model': model.trim(),
      if (imageSize != null) 'image_size': imageSize.trim(),
      if (updateApiKey) 'api_key': (apiKey ?? '').trim(),
    };
    http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/media-config')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw Exception('连不上服务器，配置没保存');
    }
    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>?;
    } catch (_) {
      decoded = null;
    }
    final config = decoded?['config'];
    if (response.statusCode != 200 || config is! Map) {
      throw Exception(
        decoded?['error']?.toString() ?? '保存失败（${response.statusCode}）',
      );
    }
    final snapshot = MediaConfigSnapshot.fromJson(
      config.map((key, value) => MapEntry(key.toString(), value)),
    );
    await _cache(snapshot);
    return snapshot;
  }

  Future<void> _cache(MediaConfigSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(snapshot.toJson()));
  }
}
