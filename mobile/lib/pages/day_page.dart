import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/message.dart';
import '../services/runtime_history_repository.dart';
import '../utils/app_theme.dart';
import '../utils/archive_display.dart';
import '../widgets/swipe_back.dart';
import 'read_only_chat_view_page.dart';

enum _DayLoadStatus { loading, ready, error }

/// 按消息真实发生时间读取某个本地日的 canonical 历史。
class DayPage extends StatefulWidget {
  const DayPage({
    super.key,
    required this.date,
    this.repository,
    this.timezoneOffsetMinutes,
  });

  final DateTime date;
  final RuntimeHistoryRepository? repository;

  /// 仅用于固定时区测试；生产默认读取目标本地日的设备 UTC offset。
  final int? timezoneOffsetMinutes;

  @override
  State<DayPage> createState() => _DayPageState();
}

class _DayPageState extends State<DayPage> {
  static const List<String> _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  late final RuntimeHistoryRepository _repository;
  late final bool _ownsRepository;
  var _status = _DayLoadStatus.loading;
  var _messages = const <ChatMessage>[];
  var _fromCache = false;
  Object? _error;
  var _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? RuntimeHistoryRepository();
    _ownsRepository = widget.repository == null;
    _loadDay();
  }

  @override
  void dispose() {
    if (_ownsRepository) _repository.close();
    super.dispose();
  }

  Future<void> _loadDay() async {
    final request = ++_requestSerial;
    final localStart = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day,
    );
    final localEnd = DateTime(
      widget.date.year,
      widget.date.month,
      widget.date.day + 1,
    );
    final start = widget.timezoneOffsetMinutes == null
        ? localStart
        : _dayUtcBoundary(
            widget.date.year,
            widget.date.month,
            widget.date.day,
            widget.timezoneOffsetMinutes!,
          );
    final end = widget.timezoneOffsetMinutes == null
        ? localEnd
        : _dayUtcBoundary(
            widget.date.year,
            widget.date.month,
            widget.date.day + 1,
            widget.timezoneOffsetMinutes!,
          );
    setState(() {
      _status = _DayLoadStatus.loading;
      _messages = const [];
      _fromCache = false;
      _error = null;
    });
    try {
      final snapshot = await _repository.completeDayMessages(
        start: start,
        end: end,
      );
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _messages = snapshot.messages;
        _fromCache = snapshot.fromCache;
        _status = _DayLoadStatus.ready;
      });
    } catch (error) {
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _error = error;
        _status = _DayLoadStatus.error;
      });
    }
  }

  void _openMessages() {
    Navigator.push(
      context,
      SwipeBackRoute(
        builder: (_) => ReadOnlyChatViewPage(
          title: '${widget.date.month}月${widget.date.day}日',
          messages: _messages,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title =
        '${widget.date.month}月${widget.date.day}日 '
        '星期${_weekdays[widget.date.weekday - 1]}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      body: switch (_status) {
        _DayLoadStatus.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _DayLoadStatus.error => _DayLoadError(
          message: _dayErrorMessage(_error),
          onRetry: _loadDay,
        ),
        _DayLoadStatus.ready => _buildReady(context),
      },
    );
  }

  Widget _buildReady(BuildContext context) {
    final theme = Theme.of(context);
    if (_messages.isEmpty) {
      return Column(
        children: [
          if (_fromCache)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('离线缓存'),
            ),
          Expanded(
            child: Center(
              child: Text(
                '这一天没有消息',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (_fromCache)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Center(
              child: Text(
                '离线缓存',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        _DayMessagesCard(messages: _messages, onTap: _openMessages),
      ],
    );
  }
}

class _DayMessagesCard extends StatelessWidget {
  const _DayMessagesCard({required this.messages, required this.onTap});

  final List<ChatMessage> messages;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = _dayMessagePreview(messages);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Material(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '这一天聊了什么',
                        key: const ValueKey('day-messages-label'),
                        style: TextStyle(
                          fontSize: AppType.timestamp,
                          color: context.semanticColors.mutedText,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        preview ?? '没有可预览的文字内容',
                        key: const ValueKey('day-messages-preview'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.body,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                          color: preview == null
                              ? context.semanticColors.mutedText
                              : context.semanticColors.text,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${messages.length} 条消息',
                        key: const ValueKey('day-messages-count'),
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: context.semanticColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  LucideIcons.chevron_right,
                  color: context.semanticColors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _dayMessagePreview(List<ChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message.isActivity) continue;
    final content = normalizeArchivePreviewText(message.content);
    if (content.isNotEmpty) return truncateArchivePreviewText(content);
    for (final part in message.parts.reversed) {
      if (part.type != ChatMessagePartType.text) continue;
      final text = normalizeArchivePreviewText(part.text);
      if (text.isNotEmpty) return truncateArchivePreviewText(text);
    }
    final fileName = normalizeArchivePreviewText(message.fileName ?? '');
    if (fileName.isNotEmpty) return fileName;
    if ((message.imageUrl ?? '').isNotEmpty || message.imageUrls.isNotEmpty) {
      return '图片消息';
    }
  }
  return null;
}

class _DayLoadError extends StatelessWidget {
  const _DayLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

String _dayErrorMessage(Object? error) {
  final detail = error?.toString().trim() ?? '';
  return detail.isEmpty ? '当天消息加载失败' : '当天消息加载失败：$detail';
}

DateTime _dayUtcBoundary(int year, int month, int day, int offsetMinutes) =>
    DateTime.utc(year, month, day).subtract(Duration(minutes: offsetMinutes));
