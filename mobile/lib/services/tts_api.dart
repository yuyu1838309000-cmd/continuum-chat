import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_api.dart';
import 'server_config.dart';

/// TTS 配置：adapter / 服务地址 / 模型 / key / voice / 语速 / 朗读开关。
/// - 存 shared_preferences，全局 ChangeNotifier 即时刷新
/// - key 可空：空 = 用服务端默认（~/.tts_config.json，不落 App）
/// - voice_id 可空：空 = 服务端默认 assistant_clone_v5
class TtsConfig extends ChangeNotifier {
  TtsConfig._();
  static final TtsConfig instance = TtsConfig._();

  static const String kKey = 'tts_api_key';
  static const String kVoice = 'tts_voice_id';
  static const String kSpeed = 'tts_speed';
  static const String kReadAloud = 'tts_read_aloud';
  static const String kApiUrl = 'tts_api_url';
  static const String kModel = 'tts_model';
  static const String kAdapter = 'tts_adapter';

  /// 默认值（与服务端 ~/.tts_config.json 对齐）
  static const String defaultAdapter = 'minimax_t2a_v2';
  static const String defaultApiUrl = 'https://api.minimax.chat/v1/t2a_v2';
  static const String defaultModel = 'speech-2.6-hd';

  String adapter = defaultAdapter;
  String apiKey = '';
  String voiceId = '';
  String apiUrl = '';
  String model = defaultModel;
  double speed = 0.95;
  bool readAloud = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    adapter = prefs.getString(kAdapter) ?? defaultAdapter;
    apiKey = prefs.getString(kKey) ?? '';
    voiceId = prefs.getString(kVoice) ?? '';
    apiUrl = prefs.getString(kApiUrl) ?? '';
    model = prefs.getString(kModel) ?? defaultModel;
    speed = prefs.getDouble(kSpeed) ?? 0.95;
    readAloud = prefs.getBool(kReadAloud) ?? true;
    notifyListeners();
  }

  Future<void> setAdapter(String v) async {
    adapter = v.trim().isEmpty ? defaultAdapter : v.trim();
    final prefs = await SharedPreferences.getInstance();
    if (adapter == defaultAdapter) {
      await prefs.remove(kAdapter);
    } else {
      await prefs.setString(kAdapter, adapter);
    }
    notifyListeners();
  }

  Future<void> setApiKey(String v) async {
    apiKey = v.trim();
    final prefs = await SharedPreferences.getInstance();
    if (apiKey.isEmpty) {
      await prefs.remove(kKey);
    } else {
      await prefs.setString(kKey, apiKey);
    }
    notifyListeners();
  }

  Future<void> setVoiceId(String v) async {
    voiceId = v.trim();
    final prefs = await SharedPreferences.getInstance();
    if (voiceId.isEmpty) {
      await prefs.remove(kVoice);
    } else {
      await prefs.setString(kVoice, voiceId);
    }
    notifyListeners();
  }

  Future<void> setApiUrl(String v) async {
    apiUrl = v.trim();
    final prefs = await SharedPreferences.getInstance();
    if (apiUrl.isEmpty) {
      await prefs.remove(kApiUrl);
    } else {
      await prefs.setString(kApiUrl, apiUrl);
    }
    notifyListeners();
  }

  Future<void> setModel(String v) async {
    model = v.trim().isEmpty ? defaultModel : v.trim();
    final prefs = await SharedPreferences.getInstance();
    if (model == defaultModel) {
      await prefs.remove(kModel);
    } else {
      await prefs.setString(kModel, model);
    }
    notifyListeners();
  }

  Future<void> setSpeed(double v) async {
    speed = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(kSpeed, v);
    notifyListeners();
  }

  Future<void> setReadAloud(bool v) async {
    readAloud = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kReadAloud, v);
    notifyListeners();
  }

  /// 合成请求参数（App 侧配置覆盖服务端默认，空的不带）
  Map<String, dynamic> toParams(String text) => {
    'text': text,
    'adapter': adapter,
    if (apiKey.isNotEmpty) 'api_key': apiKey,
    if (voiceId.isNotEmpty) 'voice_id': voiceId,
    if (apiUrl.isNotEmpty) 'api_url': apiUrl,
    'model': model,
    'speed': speed,
  };
}

/// 合成一段文字 → 服务器 8816 /tts → mp3 URL。
/// 失败返回 null（错误信息打印，不阻塞 UI）。
Future<String?> ttsSynthesize(String text) async {
  if (text.trim().isEmpty) return null;
  Object? lastError;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final resp = await http
          .post(
            Uri.parse(ServerConfig.url(8816, '/tts')),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode(TtsConfig.instance.toParams(text)),
          )
          .timeout(const Duration(seconds: 120));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final url = j['url']?.toString();
        if (url != null && url.isNotEmpty) return url;
      }
      lastError = '${resp.statusCode} ${resp.body}';
      debugPrint('[tts] synthesize failed: $lastError');
    } catch (e) {
      lastError = e;
      debugPrint('[tts] synthesize error: $e');
    }
  }
  debugPrint('[tts] synthesize exhausted: $lastError');
  return null;
}

class TtsAudioCacheStats {
  final int fileCount;
  final int totalBytes;
  final int hitCount;
  final int missCount;
  final String lastOp;

  const TtsAudioCacheStats({
    required this.fileCount,
    required this.totalBytes,
    required this.hitCount,
    required this.missCount,
    required this.lastOp,
  });

  String get totalSizeLabel {
    if (totalBytes >= 1024 * 1024) {
      return '${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (totalBytes >= 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$totalBytes B';
  }
}

class TtsAudioCache {
  TtsAudioCache._();

  static Future<TtsAudioCacheStats> stats() => _TtsAudioCache.stats();
  static Future<void> clear() => _TtsAudioCache.clear();
}

class _TtsAudioCache {
  static const int _maxBytes = 100 * 1024 * 1024;
  static const int _maxFiles = 200;

  static int _hitCount = 0;
  static int _missCount = 0;
  static String _lastOp = '尚无操作';

  static Future<String?> audioPath(String text) async {
    final sw = Stopwatch()..start();
    final clean = text.trim();
    if (clean.isEmpty) return null;
    final file = await _cacheFile(clean);
    if (await file.exists() && await file.length() > 0) {
      _hitCount++;
      _lastOp = '命中 ${sw.elapsedMilliseconds}ms';
      debugPrint('[tts] cache hit: ${file.path}');
      return file.path;
    }
    _missCount++;
    _lastOp = 'miss，开始合成';
    final url = await ttsSynthesize(clean);
    if (url == null) {
      _lastOp = '合成失败 ${sw.elapsedMilliseconds}ms';
      return null;
    }
    try {
      final resp = await _download(url);
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        _lastOp = '下载失败 ${resp.statusCode} ${sw.elapsedMilliseconds}ms';
        debugPrint('[tts] cache download failed: ${resp.statusCode}');
        return url;
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(resp.bodyBytes, flush: true);
      await _enforceLimits();
      _lastOp = '写入 ${sw.elapsedMilliseconds}ms · ${resp.bodyBytes.length}B';
      debugPrint('[tts] cache saved: ${file.path}');
      return file.path;
    } catch (e) {
      _lastOp = '写失败 ${sw.elapsedMilliseconds}ms · $e';
      debugPrint('[tts] cache write failed: $e');
      return url;
    }
  }

  static Future<http.Response> _download(String url) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 120));
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('download failed');
  }

  static Future<Directory> _cacheDir() async {
    final dir = await getApplicationDocumentsDirectory();
    return Directory('${dir.path}/tts_cache');
  }

  static Future<File> _cacheFile(String text) async {
    final cacheDir = await _cacheDir();
    final cfg = TtsConfig.instance;
    final key = jsonEncode({
      'text': text,
      'adapter': cfg.adapter,
      'voice_id': cfg.voiceId.isEmpty ? 'server-default' : cfg.voiceId,
      'speed': cfg.speed,
      'model': cfg.model,
      'api_url': cfg.apiUrl.isEmpty ? 'server-default' : cfg.apiUrl,
    });
    return File('${cacheDir.path}/${_stableHash64(key)}.mp3');
  }

  static Future<TtsAudioCacheStats> stats() async {
    final scan = await _scan();
    return TtsAudioCacheStats(
      fileCount: scan.fileCount,
      totalBytes: scan.totalBytes,
      hitCount: _hitCount,
      missCount: _missCount,
      lastOp: _lastOp,
    );
  }

  static Future<void> clear() async {
    final dir = await _cacheDir();
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          await entity.delete().catchError((_) => entity);
        }
      }
    }
    _lastOp = '已清空';
  }

  static Future<void> _enforceLimits() async {
    final scan = await _scan();
    if (scan.fileCount <= _maxFiles && scan.totalBytes <= _maxBytes) return;
    final files = [...scan.files]
      ..sort((a, b) => a.modified.compareTo(b.modified));
    var count = scan.fileCount;
    var bytes = scan.totalBytes;
    for (final item in files) {
      if (count <= _maxFiles && bytes <= _maxBytes) break;
      try {
        await item.file.delete();
        count--;
        bytes -= item.bytes;
      } catch (_) {
        // ignore stale files
      }
    }
  }

  static Future<_CacheScan> _scan() async {
    final dir = await _cacheDir();
    if (!await dir.exists()) {
      return const _CacheScan(fileCount: 0, totalBytes: 0, files: []);
    }
    final files = <_CacheFileInfo>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.mp3')) continue;
      try {
        final stat = await entity.stat();
        files.add(_CacheFileInfo(entity, stat.size, stat.modified));
        total += stat.size;
      } catch (_) {
        // ignore disappearing files
      }
    }
    return _CacheScan(fileCount: files.length, totalBytes: total, files: files);
  }

  static String _stableHash64(String input) {
    const mask = 0xFFFFFFFFFFFFFFFF;
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(input)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class _CacheScan {
  final int fileCount;
  final int totalBytes;
  final List<_CacheFileInfo> files;

  const _CacheScan({
    required this.fileCount,
    required this.totalBytes,
    required this.files,
  });
}

class _CacheFileInfo {
  final File file;
  final int bytes;
  final DateTime modified;

  const _CacheFileInfo(this.file, this.bytes, this.modified);
}

/// TTS 播放器单例：同一时刻只播一段，播放中再点 = 停止。
/// 气泡播放按钮共用它，避免多个 AudioPlayer 打架。
class TtsPlayer extends ChangeNotifier {
  TtsPlayer._() {
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && _playing) {
        _playing = false;
        notifyListeners();
      }
    });
  }
  static final TtsPlayer instance = TtsPlayer._();

  final AudioPlayer _player = AudioPlayer();
  String? _currentUrl;
  String? _currentText;
  String? _lastError;
  bool _playing = false;
  bool _loading = false;

  bool get playing => _playing;
  bool get loading => _loading;
  String? get currentUrl => _currentUrl;
  String? get currentText => _currentText;
  String? get lastError => _lastError;

  /// 切换：没在播 → 合成并播放；同一段在播 → 停止；另一段在播 → 切过去。
  Future<void> toggle(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    _lastError = null;
    if (_playing && _currentText == clean) {
      await stop();
      return;
    }
    if (_playing) {
      await stop();
    }
    _currentText = clean;
    _loading = true;
    notifyListeners();
    final source = await _TtsAudioCache.audioPath(clean);
    if (source == null) {
      _loading = false;
      _lastError = '合成失败，检查 TTS 配置（key/服务地址/模型）';
      notifyListeners();
      return;
    }
    _loading = false;
    _currentUrl = source;
    try {
      if (source.startsWith('http://') || source.startsWith('https://')) {
        await _player.setUrl(source);
      } else {
        await _player.setFilePath(source);
      }
      _player.play();
      _playing = true;
    } catch (e) {
      debugPrint('[tts] play error: $e');
      _playing = false;
      _lastError = '播放失败：$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _player.stop();
    _playing = false;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
