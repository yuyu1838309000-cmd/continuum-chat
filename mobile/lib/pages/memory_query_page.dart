import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:http/http.dart' as http;
import '../services/server_config.dart';
import '../services/chat_api.dart';
import '../utils/app_theme.dart';

/// 查记忆页（阶段四 · 面板工具）：
/// - 输入关键词 → 真调 8816 POST /tools/run {tool_id: memory, params: {query}}
/// - 服务器走 OB breath 检索，返回咱们聊过/存过的相关片段
/// - 卡片风格照工具箱：圆角 20 + 柔和阴影 + surface 底
class MemoryQueryPage extends StatefulWidget {
  const MemoryQueryPage({super.key});

  @override
  State<MemoryQueryPage> createState() => _MemoryQueryPageState();
}

class _MemoryQueryPageState extends State<MemoryQueryPage> {
  static String get _runUrl => ServerConfig.url(8816, '/tools/run');

  final TextEditingController _controller = TextEditingController();
  String? _result;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _query() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });
    try {
      final resp = await http
          .post(
            Uri.parse(_runUrl),
            headers: ChatApi.authHeaders({'Content-Type': 'application/json'}),
            body: jsonEncode({
              'tool_id': 'memory',
              'params': {'query': q},
            }),
          )
          .timeout(const Duration(seconds: 30));
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode == 200) {
        setState(() {
          _result = j['result']?.toString() ?? '（空）';
          _loading = false;
        });
      } else {
        setState(() {
          _error = j['error']?.toString() ?? '查询失败（${resp.statusCode}）';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '连不上服务器：$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('查记忆')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          // 输入区
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _query(),
                    decoration: InputDecoration(
                      hintText: '想翻什么，比如：项目、灵感、周末',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: context.fieldColor,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 44,
                  height: 44,
                  child: FilledButton(
                    onPressed: _loading ? null : _query,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.search, size: 20),
                  ),
                ),
              ],
            ),
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 13, color: theme.colorScheme.error),
              ),
            ),

          if (_result != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [context.cardShadow],
              ),
              child: Material(
                color: context.cardColor,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            LucideIcons.brain,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '翻到的记忆',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        _result!,
                        style: const TextStyle(fontSize: 14, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_result == null && _error == null && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 40, 40, 0),
              child: Column(
                children: [
                  Icon(
                    LucideIcons.brain,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '输入关键词，翻咱们聊过的事',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
