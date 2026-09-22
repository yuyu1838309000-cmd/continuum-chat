import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_theme.dart';
import '../widgets/setting_card.dart';

/// 搜索配置页（配置中心 · 搜索卡片）
/// - 每次搜索几条结果：slider 1-10，默认 5，改动即存 shared_preferences
/// - ChatApi.searchWeb 调工具时带上 max_results 覆盖默认值（key 两边一致）
class SearchConfigPage extends StatefulWidget {
  const SearchConfigPage({super.key});

  @override
  State<SearchConfigPage> createState() => _SearchConfigPageState();
}

class _SearchConfigPageState extends State<SearchConfigPage> {
  static const String keyMaxResults = 'search_max_results';
  int _maxResults = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _maxResults = (prefs.getInt(keyMaxResults) ?? 5).clamp(1, 10);
    });
  }

  Future<void> _save(int v) async {
    setState(() => _maxResults = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyMaxResults, v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        children: [
          // 结果条数：圆角卡片 + slider + 数字显示（照 OCR 配置页卡片风）
          SettingCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '每次搜几条',
                      style: TextStyle(
                        fontSize: AppType.body,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_maxResults 条',
                      style: TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _maxResults.toDouble(),
                  min: 1,
                  max: 10,
                  divisions: 9,
                  label: '$_maxResults',
                  onChanged: (v) => _save(v.round()),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
      ),
    );
  }
}
