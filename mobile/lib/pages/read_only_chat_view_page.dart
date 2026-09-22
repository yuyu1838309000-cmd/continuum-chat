import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/message.dart';
import '../utils/app_theme.dart';
import '../utils/chat_part_timeline.dart';
import '../utils/chat_process_copy.dart';
import '../utils/export_chat.dart';
import '../utils/read_only_chat_entries.dart';
import '../utils/reasoning_pref.dart';
import '../utils/timestamp_pref.dart';
import '../utils/token_usage.dart';
import '../widgets/message_bubble.dart';
import '../widgets/thinking_card.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

const double _kThinkingInset = 40;

/// 只读聊天记录页：只展示消息，不能发消息、不能编辑。
/// 归档会话查看、日历"当日聊天记录"都用它，归档只读不会误改。
/// 右上角导出按钮：把这段对话导出成 txt 分享。
class ReadOnlyChatViewPage extends StatefulWidget {
  final String title;
  final List<ChatMessage> messages;
  final String? focusEventId;
  final int? focusRawEventId;
  final int? focusIndex;

  const ReadOnlyChatViewPage({
    super.key,
    required this.title,
    required this.messages,
    this.focusEventId,
    this.focusRawEventId,
    this.focusIndex,
  });

  @override
  State<ReadOnlyChatViewPage> createState() => _ReadOnlyChatViewPageState();
}

class _ReadOnlyChatViewPageState extends State<ReadOnlyChatViewPage> {
  final ScrollController _scroll = ScrollController();
  late final List<ReadOnlyChatEntry> _entries;
  final Set<String> _expandedThinking = {};
  final Set<String> _expandedProcessSections = {};
  final Set<String> _expandedTools = {};
  int? _focusMessageIndex;
  int? _focusEntryIndex;
  bool _focusPending = false;
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _entries = buildReadOnlyChatEntries(widget.messages);
    _focusMessageIndex = resolveReadOnlyFocusMessageIndex(
      widget.messages,
      focusEventId: widget.focusEventId,
      focusRawEventId: widget.focusRawEventId,
      focusIndex: widget.focusIndex,
    );
    _focusEntryIndex = readOnlyEntryIndexForMessageIndex(
      _entries,
      _focusMessageIndex,
    );
    _focusPending = _focusEntryIndex != null;
    if (_focusPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients || _focusEntryIndex == null) {
          return;
        }
        final est = (_focusEntryIndex! * 96.0)
            .clamp(0.0, _scroll.position.maxScrollExtent)
            .toDouble();
        _scroll.jumpTo(est);
      });
    }
  }

  @override
  void dispose() {
    _focusTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _export(BuildContext context) async {
    if (widget.messages.isEmpty) return;
    try {
      await ChatExporter.exportAndShare(
        context,
        widget.messages,
        title: widget.title,
      );
    } catch (_) {
      // 分享面板打不开时静默，不打断阅读
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text.trim().isEmpty ? '没有内容' : '已复制')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (widget.messages.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.share),
              tooltip: '导出这段对话',
              onPressed: () => _export(context),
            ),
        ],
      ),
      body: widget.messages.isEmpty
          ? Center(
              child: Text(
                '没有消息',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final entry = _entries[i];
                return switch (entry.type) {
                  ReadOnlyChatEntryType.date => _DateSeparator(
                    label: entry.label ?? '',
                  ),
                  ReadOnlyChatEntryType.message => _messageEntry(
                    theme,
                    entry.messageIndex!,
                  ),
                };
              },
            ),
    );
  }

  Widget _messageEntry(ThemeData theme, int messageIndex) {
    final m = widget.messages[messageIndex];
    final previousMessage = messageIndex > 0
        ? widget.messages[messageIndex - 1]
        : null;
    final prev = previousMessage?.time;
    final focused = messageIndex == _focusMessageIndex;
    Widget row = _buildMessageContent(
      theme,
      m,
      prev,
      previousUserText: previousMessage?.role == 'user'
          ? previousMessage?.content
          : null,
    );
    Widget item = AnimatedContainer(
      key: ValueKey('read-only-message-$messageIndex'),
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: focused
            ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: 4,
          right: 4,
          top: _messageTopGap(m, previousMessage),
          bottom: _messageBottomGap(
            m,
            isLast: messageIndex == widget.messages.length - 1,
          ),
        ),
        child: row,
      ),
    );
    if (focused && _focusPending) {
      final focusedItem = item;
      item = Builder(
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_focusPending) return;
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              alignment: 0.35,
            );
            setState(() => _focusPending = false);
            _focusTimer?.cancel();
            _focusTimer = Timer(const Duration(seconds: 3), () {
              if (mounted) {
                setState(() => _focusMessageIndex = null);
              }
            });
          });
          return focusedItem;
        },
      );
    }
    return item;
  }

  Widget _buildMessageContent(
    ThemeData theme,
    ChatMessage m,
    DateTime? prev, {
    String? previousUserText,
  }) {
    if (m.role == 'assistant' && m.parts.isNotEmpty) {
      return _buildPartsMessage(
        theme,
        m,
        prev,
        previousUserText: previousUserText,
      );
    }

    final rounds = m.reasonings.isNotEmpty
        ? List<String>.of(m.reasonings)
        : (m.reasoning.isNotEmpty ? <String>[m.reasoning] : const <String>[]);
    final doneRounds = m.toolDoneRounds.toSet();
    final row = _buildMessageRow(theme, m, prev);
    if (rounds.isEmpty && doneRounds.isEmpty) return row;

    return ValueListenableBuilder<bool>(
      valueListenable: ReasoningPref.show,
      builder: (context, showReasoning, _) {
        final timeline = _buildLegacyReplyTimeline(
          m,
          rounds: rounds,
          doneRounds: doneRounds,
          showReasoning: showReasoning,
        );
        if (timeline == null) return row;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [timeline, const SizedBox(height: 6), row],
        );
      },
    );
  }

  Widget _buildMessageRow(ThemeData theme, ChatMessage m, DateTime? prev) {
    if (m.isToolDone) {
      return MessageBubble.toolDoneCard(theme, label: m.content);
    }
    if (m.isActivity) {
      return ValueListenableBuilder<bool>(
        valueListenable: TimestampPref.show,
        builder: (context, showTimestamp, _) => MessageBubble.activityCard(
          theme,
          m,
          prev,
          showTimestamp: showTimestamp,
        ),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: TimestampPref.show,
      builder: (context, showTimestamp, _) => ValueListenableBuilder<bool>(
        valueListenable: TokenUsagePref.show,
        builder: (context, showUsage, _) => MessageBubble(
          message: m,
          isMe: m.role == 'user',
          prevTime: prev,
          showTimestamp: showTimestamp,
          showTokenUsage: showUsage,
        ),
      ),
    );
  }

  Widget _buildPartsMessage(
    ThemeData theme,
    ChatMessage m,
    DateTime? prev, {
    String? previousUserText,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: TimestampPref.show,
      builder: (context, showTimestamp, _) => ValueListenableBuilder<bool>(
        valueListenable: TokenUsagePref.show,
        builder: (context, showUsage, _) => ValueListenableBuilder<bool>(
          valueListenable: ReasoningPref.show,
          builder: (context, showReasoning, _) => _buildPartsMessageBody(
            theme,
            m,
            prev,
            showTimestamp: showTimestamp,
            showTokenUsage: showUsage,
            showReasoning: showReasoning,
            previousUserText: previousUserText,
          ),
        ),
      ),
    );
  }

  Widget _buildPartsMessageBody(
    ThemeData theme,
    ChatMessage m,
    DateTime? prev, {
    required bool showTimestamp,
    required bool showTokenUsage,
    required bool showReasoning,
    String? previousUserText,
  }) {
    final visible = <Widget>[];
    var renderedBubbleCount = 0;
    final timeline = buildChatPartTimeline(
      suppressExactUserEchoInterimParts(
        m.parts,
        previousUserText: previousUserText,
      ),
      showReasoning: showReasoning,
    );

    for (final item in timeline) {
      Widget? child;
      switch (item.type) {
        case ChatPartTimelineItemType.process:
          final section = item.section;
          if (section == null) break;
          child = _buildProcessSectionBubble(
            m,
            section,
            showReasoning: showReasoning,
          );
        case ChatPartTimelineItemType.part:
          final ref = item.part;
          if (ref == null) break;
          final part = ref.part;
          switch (part.type) {
            case ChatMessagePartType.text:
              if (part.text.trim().isEmpty) break;
              final temp = ChatMessage(
                role: 'assistant',
                content: part.text,
                time: m.time,
                usage: ref.index == m.parts.length - 1 ? m.usage : null,
              );
              child = MessageBubble(
                message: temp,
                isMe: false,
                prevTime: renderedBubbleCount == 0 ? prev : null,
                onCopyAll: () => _copyText(part.text),
                showTokenUsage: showTokenUsage,
                showTimestamp: showTimestamp,
              );
              renderedBubbleCount += 1;
            case ChatMessagePartType.image:
              if (part.url.isEmpty) break;
              final temp = ChatMessage(
                role: 'assistant',
                content: '',
                imageUrl: part.url,
                time: m.time,
              );
              child = MessageBubble(
                message: temp,
                isMe: false,
                prevTime: renderedBubbleCount == 0 ? prev : null,
                onCopyAll: () => _copyText(part.url),
                showTimestamp: showTimestamp,
              );
              renderedBubbleCount += 1;
            case ChatMessagePartType.reasoning:
              if (!showReasoning) break;
              final text = part.text.isNotEmpty ? part.text : part.delta;
              if (text.trim().isEmpty) break;
              child = _buildThinkingCard(
                m,
                round: part.round <= 0 ? 1 : part.round,
                text: text,
              );
            case ChatMessagePartType.tool:
              break;
          }
      }
      if (child == null) continue;
      if (visible.isNotEmpty) visible.add(const SizedBox(height: 6));
      visible.add(child);
    }
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: visible,
    );
  }

  Widget? _buildLegacyReplyTimeline(
    ChatMessage m, {
    required List<String> rounds,
    required Set<int> doneRounds,
    required bool showReasoning,
  }) {
    final steps = <Widget>[];
    final maxRound = [
      rounds.length,
      if (doneRounds.isNotEmpty) doneRounds.reduce((a, b) => a > b ? a : b),
    ].fold<int>(0, (max, value) => value > max ? value : max);

    for (var round = 1; round <= maxRound; round++) {
      if (showReasoning && round <= rounds.length) {
        final text = rounds[round - 1];
        if (text.trim().isNotEmpty) {
          steps.add(_buildThinkingCard(m, round: round, text: text));
        }
      }
      if (doneRounds.contains(round)) {
        steps.add(_buildToolStatusCard(ChatMessage.toolDoneLabel));
      }
    }
    if (steps.isEmpty) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          steps[i],
        ],
      ],
    );
  }

  String _thinkingKey(ChatMessage message, int round) =>
      '${identityHashCode(message)}:$round';

  String _processSectionKey(ChatMessage message, ChatProcessSection section) =>
      '${identityHashCode(message)}:process:${section.startIndex}';

  String _toolKey(ChatMessage message, int index, ChatMessagePart part) =>
      '${identityHashCode(message)}:${part.round}:$index';

  Widget _buildThinkingCard(
    ChatMessage m, {
    required int round,
    required String text,
  }) {
    final key = _thinkingKey(m, round);
    return Padding(
      padding: const EdgeInsets.only(left: _kThinkingInset),
      child: ThinkingCard(
        active: false,
        text: text,
        expanded: _expandedThinking.contains(key),
        onToggle: () {
          setState(() {
            if (!_expandedThinking.remove(key)) {
              _expandedThinking.add(key);
            }
          });
        },
        onCopyAll: () => _copyText(text),
      ),
    );
  }

  Widget _buildToolStatusCard(String label) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: _kThinkingInset),
      child: MessageBubble.busyCard(
        theme,
        label: chatToolDoneDisplayLabel(label),
        alignment: Alignment.centerLeft,
      ),
    );
  }

  String _processSectionTitle(
    ChatProcessSection section, {
    required bool showReasoning,
  }) {
    final names = <String>[];
    for (final step in section.steps) {
      if (step.part.type != ChatMessagePartType.tool) continue;
      for (final name in _toolNames(step.part)) {
        if (!names.contains(name)) names.add(name);
      }
    }
    return chatProcessSectionLabel(
      failed: section.isFailed,
      active: section.isRunning,
      hasTool: section.hasTool,
      stepCount: section.visibleStepCount(showReasoning: showReasoning),
      toolNames: names,
    );
  }

  Widget _buildProcessSectionBubble(
    ChatMessage message,
    ChatProcessSection section, {
    required bool showReasoning,
  }) {
    final theme = Theme.of(context);
    if (!section.hasTool) {
      final reasoningSteps = section
          .visibleSteps(showReasoning: showReasoning)
          .where((step) => step.part.type == ChatMessagePartType.reasoning)
          .toList();
      final text = reasoningSteps
          .map(
            (step) => step.part.text.isNotEmpty
                ? step.part.text.trim()
                : step.part.delta.trim(),
          )
          .where((value) => value.isNotEmpty)
          .join('\n\n');
      final firstRound = reasoningSteps.isEmpty
          ? 1
          : (reasoningSteps.first.part.round <= 0
                ? 1
                : reasoningSteps.first.part.round);
      return _buildThinkingCard(message, round: firstRound, text: text);
    }
    final key = _processSectionKey(message, section);
    final expanded = _expandedProcessSections.contains(key);
    final label = _processSectionTitle(section, showReasoning: showReasoning);
    final icon = section.isFailed
        ? LucideIcons.circle_alert
        : section.hasTool
        ? LucideIcons.ellipsis
        : LucideIcons.brain;
    return Padding(
      padding: const EdgeInsets.only(left: _kThinkingInset),
      child: Container(
        constraints: BoxConstraints(
          minHeight: 44,
          maxWidth: MediaQuery.of(context).size.width * 0.76,
        ),
        decoration: BoxDecoration(
          color: context.cardColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  splashColor: theme.colorScheme.primary.withValues(
                    alpha: 0.05,
                  ),
                  highlightColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.04,
                  ),
                  onTap: () {
                    setState(() {
                      if (!_expandedProcessSections.remove(key)) {
                        _expandedProcessSections.add(key);
                      }
                    });
                  },
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(
                          icon,
                          size: 14,
                          color: section.isFailed
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          expanded
                              ? LucideIcons.chevron_up
                              : LucideIcons.chevron_down,
                          size: 14,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? _buildProcessSectionBody(
                          theme,
                          message,
                          section,
                          showReasoning: showReasoning,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProcessSectionBody(
    ThemeData theme,
    ChatMessage message,
    ChatProcessSection section, {
    required bool showReasoning,
  }) {
    final steps = section.visibleSteps(showReasoning: showReasoning);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _buildProcessStep(theme, message, steps[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildProcessStep(
    ThemeData theme,
    ChatMessage message,
    ChatPartRef ref,
  ) {
    final part = ref.part;
    return switch (part.type) {
      ChatMessagePartType.reasoning => _buildReasoningProcessStep(theme, part),
      ChatMessagePartType.tool => _buildToolProcessStep(theme, message, ref),
      ChatMessagePartType.text ||
      ChatMessagePartType.image => const SizedBox.shrink(),
    };
  }

  Widget _buildReasoningProcessStep(ThemeData theme, ChatMessagePart part) {
    final text = part.text.trim();
    final active = part.status == 'streaming' || part.status == 'running';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              LucideIcons.brain,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 7),
            Text(
              active ? '还在想' : '想过',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.55,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.9),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildToolProcessStep(
    ThemeData theme,
    ChatMessage message,
    ChatPartRef ref,
  ) {
    final part = ref.part;
    final key = _toolKey(message, ref.index, part);
    final expanded = _expandedTools.contains(key);
    final running = part.status == 'running' || part.status == 'streaming';
    final title = _toolPartTitle(part, running: running);
    final statusIcon = part.status == 'failed'
        ? LucideIcons.circle_alert
        : running
        ? LucideIcons.wrench
        : LucideIcons.check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          onTap: () {
            setState(() {
              if (!_expandedTools.remove(key)) {
                _expandedTools.add(key);
              }
            });
          },
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                Icon(
                  statusIcon,
                  size: 13,
                  color: part.status == 'failed'
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
                  size: 13,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 170),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _buildToolPartBody(theme, part),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildToolPartBody(ThemeData theme, ChatMessagePart part) {
    final tools = part.tools;
    if (tools.isEmpty) {
      final fallbackLabel = switch (part.status) {
        'done' => '处理好了',
        'failed' => '这一步没做完',
        _ => '正在处理…',
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Text(
          fallbackLabel,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < tools.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _ToolCallView(
              tool: tools[i],
              displayName: _toolDisplayName(tools[i].name),
            ),
          ],
        ],
      ),
    );
  }

  String _toolDisplayName(String raw) => chatToolDisplayName(raw);

  List<String> _toolNames(ChatMessagePart part) {
    final names = <String>[];
    for (final tool in part.tools) {
      final name = _toolDisplayName(tool.name);
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }

  String _toolPartTitle(ChatMessagePart part, {required bool running}) =>
      chatToolStepLabel(
        status: part.status,
        running: running,
        deviceRunning: running && _toolNames(part).contains('手机操作'),
        toolNames: _toolNames(part),
      );

  double _messageTopGap(ChatMessage message, ChatMessage? previous) {
    if (previous == null) return 6;
    if (_isStatusLikeMessage(message) || _isStatusLikeMessage(previous)) {
      return 12;
    }
    if (message.role == previous.role) return 4;
    return 12;
  }

  double _messageBottomGap(ChatMessage message, {required bool isLast}) {
    if (isLast) return 12;
    return _isStatusLikeMessage(message) ? 2 : 1;
  }

  bool _isStatusLikeMessage(ChatMessage message) =>
      message.isActivity || message.isToolDone;
}

class _DateSeparator extends StatelessWidget {
  final String label;

  const _DateSeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Align(
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
            height: 1.25,
          ),
        ),
      ),
    );
  }
}

class _ToolCallView extends StatelessWidget {
  final ChatToolCallPart tool;
  final String displayName;

  const _ToolCallView({required this.tool, required this.displayName});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final args = _formatArgs(tool.arguments);
    final result = _formatResult(tool.result);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                displayName.isEmpty ? '处理' : displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              _statusLabel(tool.status),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: tool.status == 'failed'
                    ? theme.colorScheme.error.withValues(alpha: 0.86)
                    : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _ToolPayloadBlock(label: '输入', text: args, monospace: true),
        if (result.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ToolPayloadBlock(label: '结果', text: result),
        ],
      ],
    );
  }

  static String _statusLabel(String status) {
    return switch (status) {
      'running' || 'streaming' => '处理中',
      'failed' => '没完成',
      _ => '完成',
    };
  }

  static String _formatArgs(Map<String, dynamic> args) {
    try {
      return const JsonEncoder.withIndent('  ').convert(args);
    } catch (_) {
      return args.toString();
    }
  }

  static String _formatResult(String raw) {
    var text = raw.trim();
    for (final prefix in const ['[工具结果]：', '[工具结果]:']) {
      if (text.startsWith(prefix)) {
        text = text.substring(prefix.length).trimLeft();
        break;
      }
    }
    if (text.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }
}

class _ToolPayloadBlock extends StatelessWidget {
  final String label;
  final String text;
  final bool monospace;

  const _ToolPayloadBlock({
    required this.label,
    required this.text,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.46,
    );
    final contentColor = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.9,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 9),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: '复制$label',
                child: IconButton(
                  tooltip: '复制$label',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  color: theme.colorScheme.outline,
                  icon: const Icon(LucideIcons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    messenger?.hideCurrentSnackBar();
                    messenger?.showSnackBar(
                      SnackBar(
                        content: Text('已复制$label'),
                        duration: const Duration(milliseconds: 900),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            text,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: contentColor,
              fontFamily: monospace ? 'monospace' : null,
            ),
          ),
        ],
      ),
    );
  }
}
