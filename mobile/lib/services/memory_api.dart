import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/memory_card.dart';
import 'server_config.dart';

/// 新增记忆结果：saved=true 已入库（new/merge），false=被门卫丢弃或请求失败。
class WriteResult {
  final bool saved;
  final String message;

  const WriteResult({required this.saved, required this.message});
}

/// 编辑记忆结果：区分成功、版本冲突与普通失败。
class MemoryUpdateResult {
  final MemoryCard? card;
  final bool conflict;

  const MemoryUpdateResult.updated(MemoryCard this.card) : conflict = false;
  const MemoryUpdateResult.conflict() : card = null, conflict = true;
  const MemoryUpdateResult.failed() : card = null, conflict = false;
}

/// Continuum Chat记忆库接口（端口 8820）。
/// 服务器地址从配置中心动态拼（ServerConfig.url），换服务器不用重编译。
class MemoryApi {
  MemoryApi._();

  static String _url(String path) => ServerConfig.url(8820, path);

  /// GET /latest → 最新一条记忆（去向量，含 freshness），失败返回 null。
  static Future<MemoryCard?> latest() async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/latest')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return null;
      return MemoryCard.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// GET /stats → {total, fresh, sunk, rings}，失败返回 null。
  static Future<Map<String, dynamic>?> stats() async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/stats')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// GET /cards → 卡片列表（主题卡网格用），失败返回 null。
  /// [includeSunk] 为 true 时连沉底卡一起返回（/cards?include_sunk=true）。
  static Future<List<MemoryCard>?> cards({bool includeSunk = false}) async {
    try {
      final path = includeSunk
          ? '/cards?ui=true&include_sunk=true'
          : '/cards?ui=true';
      final resp = await http
          .get(Uri.parse(_url(path)))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as List<dynamic>?;
      if (raw == null) return null;
      return [
        for (final e in raw)
          if (e is Map<String, dynamic>) MemoryCard.fromJson(e),
      ];
    } catch (_) {
      return null;
    }
  }

  /// GET /archive → 归档卡列表（含年轮，MemoryDetail），失败返回 null。
  static Future<List<MemoryDetail>?> listArchive() async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/archive')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as List<dynamic>?;
      if (raw == null) return null;
      return [
        for (final e in raw)
          if (e is Map<String, dynamic>) _detailFromJson(e),
      ];
    } catch (_) {
      return null;
    }
  }

  /// GET /trash → 回收站卡列表（含年轮，MemoryDetail），失败返回 null。
  static Future<List<MemoryDetail>?> listTrash() async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/trash')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as List<dynamic>?;
      if (raw == null) return null;
      return [
        for (final e in raw)
          if (e is Map<String, dynamic>) _detailFromJson(e),
      ];
    } catch (_) {
      return null;
    }
  }

  /// POST /archive → 归档 / 取消归档，成功返回 true。
  static Future<bool> archiveCard(int id, {required bool unarchive}) async {
    try {
      final resp = await http
          .post(
            Uri.parse(_url('/archive')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'card_id': id,
              'action': unarchive ? 'unarchive' : 'archive',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return false;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      return j?['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// POST /trash → 软删 / 恢复 / 彻底删除，成功返回 true。
  static Future<bool> trashCard(int id, {required String action}) async {
    if (action != 'trash' && action != 'restore' && action != 'purge') {
      return false;
    }
    try {
      final resp = await http
          .post(
            Uri.parse(_url('/trash')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'card_id': id, 'action': action}),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return false;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      return j?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// POST /keywords → 增删关键词（add 去重追加 / remove 幂等移除）。
  /// 成功返回最新关键词列表，失败返回 null。
  static Future<List<String>?> updateKeywords(
    int id, {
    required String action,
    required String keyword,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(_url('/keywords')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'card_id': id,
              'action': action,
              'keyword': keyword,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j?['success'] != true) return null;
      final raw = j?['keywords'] as List<dynamic>? ?? const [];
      return raw.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }

  /// POST /write → 新增记忆（过门卫：new 新开卡 / merge 并入旧卡 / drop 不值得记）。
  /// 门卫调 DeepSeek 判断，超时放宽到 30s。
  static Future<WriteResult> write({
    String title = '',
    required String content,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(_url('/write')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': title,
              'content': content,
              'source': 'manual',
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        return const WriteResult(saved: false, message: '保存失败');
      }
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return const WriteResult(saved: false, message: '保存失败');
      return switch (j['action']) {
        'new' => const WriteResult(saved: true, message: '已记下'),
        'merge' => const WriteResult(saved: true, message: '并入已有记忆'),
        'drop' => const WriteResult(saved: false, message: '这条不值得记，没记'),
        _ => const WriteResult(saved: false, message: '保存失败'),
      };
    } catch (_) {
      return const WriteResult(saved: false, message: '保存失败');
    }
  }

  /// POST /update → 按预期 revision 编辑记忆（title/content/tags 可只传要改的）。
  /// 成功返回更新后的卡；409 返回 conflict；其他情况返回普通失败。
  static Future<MemoryUpdateResult> updateCard(
    int id, {
    required int expectedCurrentRevisionId,
    String? title,
    String? content,
    String? tags,
  }) async {
    try {
      final body = <String, dynamic>{
        'card_id': id,
        'expected_current_revision_id': expectedCurrentRevisionId,
      };
      if (title != null) body['title'] = title;
      if (content != null) body['content'] = content;
      if (tags != null) body['tags'] = tags;
      final resp = await http
          .post(
            Uri.parse(_url('/update')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 409) {
        return const MemoryUpdateResult.conflict();
      }
      if (resp.statusCode != 200) return const MemoryUpdateResult.failed();
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null || j['id'] == null) {
        return const MemoryUpdateResult.failed();
      }
      return MemoryUpdateResult.updated(MemoryCard.fromJson(j));
    } catch (_) {
      return const MemoryUpdateResult.failed();
    }
  }

  /// GET /days → {日期: [卡片…]} 按日期分组（时间线用），失败返回 null。
  static Future<Map<String, List<MemoryCard>>?> days() async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/days')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (raw == null) return null;
      return {
        for (final e in raw.entries)
          e.key: [
            for (final c in (e.value as List<dynamic>? ?? const []))
              if (c is Map<String, dynamic>) MemoryCard.fromJson(c),
          ],
      };
    } catch (_) {
      return null;
    }
  }

  /// GET /card/{id} → 卡片详情（完整正文 + 年轮），失败返回 null。
  static Future<MemoryDetail?> detail(int id) async {
    try {
      final resp = await http
          .get(Uri.parse(_url('/card/$id')))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (j == null) return null;
      return _detailFromJson(j);
    } catch (_) {
      return null;
    }
  }

  static MemoryDetail _detailFromJson(Map<String, dynamic> j) {
    final rings = (j['rings'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MemoryRing.fromJson)
        .toList();
    return MemoryDetail(
      card: MemoryCard.fromJson(j),
      rings: rings,
      reproducible: j['reproducible'] == true,
    );
  }
}
