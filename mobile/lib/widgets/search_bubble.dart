import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import 'search_waiting.dart';

/// 网页搜索气泡（v0.2.117 改造）：不再"闪一下就消失"，三态持久保留在对话流：
/// - 搜索中：小气泡显示"努力搜索中"动画（SearchWaiting）
/// - 搜索完成：文字变"搜索完成了！"，点开能看到搜了哪些网站（标题+URL 列表）
/// - 没搜到/失败：低调显示"搜索没完成"，正文补提示
/// 样式照旧：圆角 20 + 柔阴影 + 气泡底色，低调不抢眼；网站列表展开才显示，
/// 点条目用系统浏览器打开。
class SearchBubble extends StatefulWidget {
  final bool searching;
  final bool done;
  final List<SearchResult> results;
  final Color bgColor;
  final Color fgColor;
  final BoxShadow shadow;

  const SearchBubble({
    super.key,
    required this.searching,
    required this.done,
    required this.results,
    required this.bgColor,
    required this.fgColor,
    required this.shadow,
  });

  @override
  State<SearchBubble> createState() => _SearchBubbleState();
}

class _SearchBubbleState extends State<SearchBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 搜索中：小气泡 + "努力搜索中"动画
    if (widget.searching) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: widget.bgColor,
          boxShadow: [widget.shadow],
          borderRadius: BorderRadius.circular(20),
        ),
        child: SearchWaiting(color: widget.fgColor.withValues(alpha: 0.8)),
      );
    }
    // 完成/没完成：气泡保留在对话流，点开显示网站列表
    final hasResults = widget.results.isNotEmpty;
    final maxW = MediaQuery.of(context).size.width * 0.75;
    return Container(
      constraints: BoxConstraints(maxWidth: maxW),
      decoration: BoxDecoration(
        color: widget.bgColor,
        boxShadow: [widget.shadow],
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：状态文字（完成态可点展开/收起网站列表）
          InkWell(
            onTap: hasResults
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasResults ? LucideIcons.globe : LucideIcons.search_x,
                    size: 13,
                    color: widget.fgColor.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasResults ? '搜索完成了！' : '搜索没完成',
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.fgColor.withValues(alpha: 0.8),
                      height: 1.2,
                    ),
                  ),
                  if (hasResults) ...[
                    const SizedBox(width: 3),
                    Icon(
                      _expanded
                          ? LucideIcons.chevron_up
                          : LucideIcons.chevron_down,
                      size: 13,
                      color: widget.fgColor.withValues(alpha: 0.5),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 展开：搜到的网站列表（标题+URL），点条目系统浏览器打开
          if (_expanded && hasResults)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.results.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 0.5,
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.4,
                        ),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _openUrl(widget.results[i].url),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.results[i].title.isEmpty
                                  ? '（无标题）'
                                  : widget.results[i].title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            if (widget.results[i].url.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  widget.results[i].url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开静默，不打断聊天
    }
  }
}
