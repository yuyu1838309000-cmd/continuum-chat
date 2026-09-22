import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/message.dart';

/// 聊天记录导出：格式化文本（带时间戳和发言者）→ 写入 txt 文件 → 系统分享。
/// 文件存在应用文档目录「Continuum Chat导出/」下，分享后用户可存到任何地方。
class ChatExporter {
  static const String _dirName = 'Continuum Chat导出';

  /// 发言者名：user=用户，assistant=AI 助手
  static String speakerName(String role) => role == 'user' ? '用户' : 'AI 助手';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)} ${_pad(t.hour)}:${_pad(t.minute)}';

  /// 把消息列表格式化成带时间戳和发言者的纯文本。
  /// 有思考内容的回复，思考单独一行「思考：」放在正文前。
  static String format(List<ChatMessage> messages, {String? title}) {
    final buf = StringBuffer();
    buf.writeln(title ?? 'Continuum Chat 对话记录');
    buf.writeln('导出时间：${_fmt(DateTime.now())}');
    buf.writeln('共 ${messages.length} 条消息');
    buf.writeln('─' * 36);
    var count = 0;
    for (final m in messages) {
      final content = m.content.trim();
      if (content.isEmpty) continue;
      count++;
      buf.writeln();
      buf.writeln('[${_fmt(m.time)}] ${speakerName(m.role)}');
      final r = m.reasoning.trim();
      if (r.isNotEmpty) {
        // 思考逐行缩进，和正文区分开
        buf.writeln(r.split('\n').map((l) => '思考：$l').join('\n'));
      }
      buf.writeln(content);
    }
    buf.writeln();
    buf.writeln('─' * 36);
    buf.writeln('共 $count 条消息（已过滤空白）');
    return buf.toString();
  }

  /// 写入 txt 文件（应用文档目录/Continuum Chat导出/），返回完整路径。
  static Future<String> writeFile(String text, {String? title}) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final now = DateTime.now();
    final safe = (title ?? '对话')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final name =
        '${safe}_${now.year}${_pad(now.month)}${_pad(now.day)}_${_pad(now.hour)}${_pad(now.minute)}.txt';
    final file = File('${dir.path}/$name');
    await file.writeAsString(text);
    return file.path;
  }

  /// 导出并调起系统分享（txt 文件，可在任意 App 里保存/转发）。
  static Future<void> exportAndShare(
    BuildContext context,
    List<ChatMessage> messages, {
    String? title,
  }) async {
    // 分享面板锚点：同步先拿（避免跨 async 用 context），iPad 上定位弹窗用
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final text = format(messages, title: title);
    final path = await writeFile(text, title: title);
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/plain')],
      subject: title ?? 'Continuum Chat对话',
      sharePositionOrigin: origin,
    );
  }
}
