import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/assistant_channel_api.dart';
import '../utils/app_theme.dart';
import '../widgets/swipe_back.dart';

enum _AssistantChannelSection { sessions, audit }

class AssistantChannelPage extends StatefulWidget {
  const AssistantChannelPage({super.key, this.reader});

  final AssistantChannelReader? reader;

  @override
  State<AssistantChannelPage> createState() => _AssistantChannelPageState();
}

class _AssistantChannelPageState extends State<AssistantChannelPage> {
  late final AssistantChannelReader _reader;
  _AssistantChannelSection _section = _AssistantChannelSection.sessions;
  List<AssistantChannelSession>? _sessions;
  AssistantChannelAuditSnapshot? _audit;
  Object? _sessionsError;
  Object? _auditError;
  bool _loadingSessions = false;
  bool _loadingAudit = false;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader ?? AssistantChannelApi.instance;
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    if (_loadingSessions) return;
    setState(() {
      _loadingSessions = true;
      _sessionsError = null;
    });
    try {
      final sessions = await _reader.fetchSessions();
      if (!mounted) return;
      setState(() => _sessions = sessions);
    } catch (error) {
      if (!mounted) return;
      setState(() => _sessionsError = error);
    } finally {
      if (mounted) setState(() => _loadingSessions = false);
    }
  }

  Future<void> _loadAudit() async {
    if (_loadingAudit) return;
    setState(() {
      _loadingAudit = true;
      _auditError = null;
    });
    try {
      final audit = await _reader.fetchAudit();
      if (!mounted) return;
      setState(() => _audit = audit);
    } catch (error) {
      if (!mounted) return;
      setState(() => _auditError = error);
    } finally {
      if (mounted) setState(() => _loadingAudit = false);
    }
  }

  void _select(_AssistantChannelSection section) {
    if (_section == section) return;
    setState(() => _section = section);
    if (section == _AssistantChannelSection.audit && _audit == null) {
      _loadAudit();
    }
  }

  Future<void> _refresh() => switch (_section) {
    _AssistantChannelSection.sessions => _loadSessions(),
    _AssistantChannelSection.audit => _loadAudit(),
  };

  void _openSession(AssistantChannelSession session) {
    Navigator.of(context).push(
      SwipeBackRoute(
        builder: (_) =>
            AssistantChannelSessionPage(session: session, reader: _reader),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('AI 协作记录'),
        actions: [
          IconButton(
            tooltip: '重新读取',
            onPressed: _refresh,
            icon: const Icon(LucideIcons.refresh_cw),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              0,
            ),
            child: Column(
              children: [
                const _ReadOnlyNotice(),
                const SizedBox(height: AppSpacing.sm),
                _SectionSwitch(selected: _section, onSelected: _select),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Expanded(
            child: switch (_section) {
              _AssistantChannelSection.sessions => _buildSessions(),
              _AssistantChannelSection.audit => _buildAudit(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSessions() {
    if (_sessions == null && _loadingSessions) {
      return const _LoadingState(label: '正在读取 AI 协作记录');
    }
    if (_sessionsError != null && _sessions == null) {
      return _ErrorState(onRetry: _loadSessions);
    }
    final sessions = _sessions ?? const <AssistantChannelSession>[];
    if (sessions.isEmpty) {
      return _RefreshableEmptyState(
        icon: LucideIcons.messages_square,
        label: '还没有保存的 AI 协作记录',
        onRefresh: _loadSessions,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadSessions,
      child: ListView.separated(
        key: const ValueKey('assistant_channel_sessions'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        itemCount: sessions.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          final session = sessions[index];
          return _SessionCard(
            session: session,
            onTap: () => _openSession(session),
          );
        },
      ),
    );
  }

  Widget _buildAudit() {
    if (_audit == null && _loadingAudit) {
      return const _LoadingState(label: '正在读取留档审计');
    }
    if (_auditError != null && _audit == null) {
      return _ErrorState(onRetry: _loadAudit);
    }
    final audit = _audit;
    if (audit == null) return const SizedBox.shrink();
    return RefreshIndicator(
      onRefresh: _loadAudit,
      child: ListView(
        key: const ValueKey('assistant_channel_audit'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        children: [
          _StatusCard(status: audit.status),
          const SizedBox(height: AppSpacing.lg),
          const _SectionTitle(title: 'Bridge 当前版'),
          if (audit.bridges.isEmpty)
            const _InlineEmpty(label: '还没有 bridge 留档')
          else
            for (final bridge in audit.bridges) ...[
              _BridgeCard(bridge: bridge),
              const SizedBox(height: AppSpacing.sm),
            ],
          const SizedBox(height: AppSpacing.md),
          const _SectionTitle(title: 'AI 助手 notes'),
          if (audit.notes.isEmpty)
            const _InlineEmpty(label: '还没有AI 助手 notes')
          else
            for (final note in audit.notes) ...[
              _RawAuditCard(record: note, fallbackTitle: 'AI 助手 note'),
              const SizedBox(height: AppSpacing.sm),
            ],
          const SizedBox(height: AppSpacing.md),
          const _SectionTitle(title: 'Tool events'),
          if (audit.toolEvents.isEmpty)
            const _InlineEmpty(label: '还没有 tool events')
          else
            for (final event in audit.toolEvents) ...[
              _RawAuditCard(
                record: event,
                fallbackTitle: '翻档工具记录',
                recallKind: _toolEventRecallKind(event),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          const SizedBox(height: AppSpacing.md),
          const _SectionTitle(title: 'Injection traces'),
          if (audit.traces.isEmpty)
            const _InlineEmpty(label: '还没有 injection traces')
          else
            for (final trace in audit.traces) ...[
              _TraceCard(trace: trace),
              const SizedBox(height: AppSpacing.sm),
            ],
        ],
      ),
    );
  }
}

class AssistantChannelSessionPage extends StatefulWidget {
  const AssistantChannelSessionPage({
    super.key,
    required this.session,
    required this.reader,
  });

  final AssistantChannelSession session;
  final AssistantChannelReader reader;

  @override
  State<AssistantChannelSessionPage> createState() =>
      _AssistantChannelSessionPageState();
}

class _AssistantChannelSessionPageState
    extends State<AssistantChannelSessionPage> {
  List<AssistantChannelMessage>? _messages;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final messages = await widget.reader.fetchHistory(
        widget.session.sessionId,
      );
      if (!mounted) return;
      setState(() => _messages = messages);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        title: const Text('AI 协作记录'),
        actions: [
          IconButton(
            tooltip: '重新读取',
            onPressed: _load,
            icon: const Icon(LucideIcons.refresh_cw),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_messages == null && _loading) {
      return const _LoadingState(label: '正在读取完整原文');
    }
    if (_error != null && _messages == null) {
      return _ErrorState(onRetry: _load);
    }
    final messages = _messages ?? const <AssistantChannelMessage>[];
    if (messages.isEmpty) {
      return _RefreshableEmptyState(
        icon: LucideIcons.messages_square,
        label: '这段 AI 协作记录没有消息',
        onRefresh: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        key: const ValueKey('assistant_channel_messages'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        itemCount: messages.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _SessionHeader(session: widget.session);
          }
          return _MessageCard(message: messages[index - 1]);
        },
      ),
    );
  }
}

class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('assistant_channel_read_only'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: context.layerColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.lock, size: 17, color: context.subTextColor),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              '只读存档，不会向这条通道发送消息',
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.subTextColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionSwitch extends StatelessWidget {
  const _SectionSwitch({required this.selected, required this.onSelected});

  final _AssistantChannelSection selected;
  final ValueChanged<_AssistantChannelSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.layerColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          _Segment(
            key: const ValueKey('assistant_channel_sessions_tab'),
            label: 'AI 协作记录',
            selected: selected == _AssistantChannelSection.sessions,
            onTap: () => onSelected(_AssistantChannelSection.sessions),
          ),
          _Segment(
            key: const ValueKey('assistant_channel_audit_tab'),
            label: '留档审计',
            selected: selected == _AssistantChannelSection.audit,
            onTap: () => onSelected(_AssistantChannelSection.audit),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: selected ? context.cardColor : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? context.textColor : context.subTextColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.onTap});

  final AssistantChannelSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = session.lastMessageAt.isEmpty
        ? session.createdAt
        : session.lastMessageAt;
    return Material(
      color: context.cardColor,
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: context.layerColor,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  LucideIcons.messages_square,
                  size: 21,
                  color: context.accentColor,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatTimestamp(time),
                      style: const TextStyle(
                        fontSize: AppType.body,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${session.messageCount} 条消息 · ${session.sessionId}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.caption,
                        color: context.subTextColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                LucideIcons.chevron_right,
                size: 20,
                color: context.semanticColors.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.session});

  final AssistantChannelSession session;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.sessionId,
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${session.messageCount} 条消息 · ${_formatTimestamp(session.firstMessageAt)}',
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final AssistantChannelMessage message;

  @override
  Widget build(BuildContext context) {
    final isChatGpt = message.isChatGpt;
    final label = isChatGpt ? 'ChatGPT' : 'AI 助手';
    return Align(
      alignment: isChatGpt ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        key: ValueKey('assistant_channel_message_${message.id}'),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - AppSpacing.xl,
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: isChatGpt ? context.layerColor : context.cardColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          boxShadow: isChatGpt ? null : [context.cardShadow],
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
                      fontSize: AppType.caption,
                      fontWeight: FontWeight.w700,
                      color: isChatGpt
                          ? context.accentColor
                          : context.textColor,
                    ),
                  ),
                ),
                Text(
                  _formatTimestamp(message.createdAt),
                  style: TextStyle(fontSize: 11, color: context.subTextColor),
                ),
              ],
            ),
            if (message.content.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SelectableText(
                message.content,
                style: const TextStyle(fontSize: AppType.body, height: 1.6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final AssistantChannelStatus status;

  @override
  Widget build(BuildContext context) {
    final healthy = status.quickCheck.toLowerCase() == 'ok';
    const visibleCounts = <String, String>{
      'sessions': '会话',
      'messages': '消息',
      'bridges': 'Bridge',
      'bridge_revisions': '修订',
      'assistant_notes': 'Notes',
      'tool_events': '工具记录',
      'injection_traces': '提醒记录',
    };
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: [context.cardShadow],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                healthy ? LucideIcons.shield_check : LucideIcons.circle_alert,
                size: 20,
                color: healthy
                    ? context.successColor
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  healthy ? '存档状态正常' : '存档状态异常',
                  style: const TextStyle(
                    fontSize: AppType.body,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final entry in visibleCounts.entries)
                if (status.counts.containsKey(entry.key))
                  _MetaPill(
                    label: '${entry.value} ${status.counts[entry.key]}',
                  ),
            ],
          ),
          if (status.lastBackupAt.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              '最近备份 ${_formatTimestamp(status.lastBackupAt)}',
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.subTextColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BridgeCard extends StatelessWidget {
  const _BridgeCard({required this.bridge});

  final AssistantChannelBridge bridge;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('assistant_channel_bridge_${bridge.memoryId}'),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            bridge.topic.isEmpty ? '未命名 bridge' : bridge.topic,
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              _MetaPill(label: '当前版本 #${bridge.versionId}'),
              if (bridge.previousVersionId != null)
                _MetaPill(label: '上一版 #${bridge.previousVersionId}'),
              if (bridge.revisionAction.isNotEmpty)
                _MetaPill(label: bridge.revisionAction),
              if (bridge.status.isNotEmpty) _MetaPill(label: bridge.status),
            ],
          ),
          if (bridge.summary.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              bridge.summary,
              style: const TextStyle(fontSize: AppType.body, height: 1.55),
            ),
          ],
          if (bridge.detail.isNotEmpty && bridge.detail != bridge.summary) ...[
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              bridge.detail,
              style: TextStyle(
                fontSize: AppType.caption,
                height: 1.55,
                color: context.subTextColor,
              ),
            ),
          ],
          if (bridge.sourceRefs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Source refs',
              style: TextStyle(
                fontSize: AppType.caption,
                fontWeight: FontWeight.w700,
                color: context.subTextColor,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final ref in bridge.sourceRefs) _SourceRefLine(sourceRef: ref),
          ],
        ],
      ),
    );
  }
}

class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.trace});

  final AssistantChannelTrace trace;

  @override
  Widget build(BuildContext context) {
    final automatic = trace.recallKind == AssistantChannelRecallKind.automatic;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RecallPill(kind: trace.recallKind),
              const Spacer(),
              Text(
                _formatTimestamp(trace.createdAt),
                style: TextStyle(fontSize: 11, color: context.subTextColor),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            automatic ? '系统自动提醒' : 'AI 助手主动翻档',
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              trace.traceType,
              if (trace.surface.isNotEmpty) 'surface: ${trace.surface}',
              if (trace.versionId != null) 'version: ${trace.versionId}',
            ].where((value) => value.isNotEmpty).join(' · '),
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
          if (trace.matchReason.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            SelectableText(
              trace.matchReason,
              style: const TextStyle(fontSize: AppType.caption, height: 1.5),
            ),
          ],
          if (trace.sourceRefs.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            for (final ref in trace.sourceRefs) _SourceRefLine(sourceRef: ref),
          ],
        ],
      ),
    );
  }
}

class _RawAuditCard extends StatelessWidget {
  const _RawAuditCard({
    required this.record,
    required this.fallbackTitle,
    this.recallKind,
  });

  final Map<String, dynamic> record;
  final String fallbackTitle;
  final AssistantChannelRecallKind? recallKind;

  @override
  Widget build(BuildContext context) {
    final title = _firstText(record, const [
      'title',
      'topic',
      'tool_name',
      'tool',
      'event_type',
      'type',
      'kind',
    ]);
    final time = _firstText(record, const [
      'created_at',
      'occurred_at',
      'updated_at',
      'timestamp',
    ]);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.cardColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recallKind != null) ...[
            _RecallPill(kind: recallKind!),
            const SizedBox(height: AppSpacing.sm),
          ],
          Text(
            title.isEmpty ? fallbackTitle : title,
            style: const TextStyle(
              fontSize: AppType.body,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (time.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _formatTimestamp(time),
              style: TextStyle(
                fontSize: AppType.caption,
                color: context.subTextColor,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
            const JsonEncoder.withIndent('  ').convert(record),
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: context.subTextColor,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRefLine extends StatelessWidget {
  const _SourceRefLine({required this.sourceRef});

  final AssistantChannelSourceRef sourceRef;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        '${sourceRef.sessionId} · #${sourceRef.messageId} · ${sourceRef.role} · ${_formatTimestamp(sourceRef.createdAt)}',
        softWrap: true,
        style: TextStyle(
          fontSize: 11,
          height: 1.4,
          color: context.subTextColor,
        ),
      ),
    );
  }
}

class _RecallPill extends StatelessWidget {
  const _RecallPill({required this.kind});

  final AssistantChannelRecallKind kind;

  @override
  Widget build(BuildContext context) {
    final automatic = kind == AssistantChannelRecallKind.automatic;
    return _MetaPill(label: automatic ? '系统自动提醒' : 'AI 助手主动翻档');
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.layerColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: context.subTextColor),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: AppType.body,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            label,
            style: TextStyle(
              fontSize: AppType.caption,
              color: context.subTextColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.circle_alert,
              size: 28,
              color: context.subTextColor,
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              '暂时无法读取 AI 协作记录',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppType.body,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.layerColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppType.caption,
          color: context.subTextColor,
        ),
      ),
    );
  }
}

class _RefreshableEmptyState extends StatelessWidget {
  const _RefreshableEmptyState({
    required this.icon,
    required this.label,
    required this.onRefresh,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
          Icon(icon, size: 30, color: context.subTextColor),
          const SizedBox(height: AppSpacing.sm),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppType.body,
              color: context.subTextColor,
            ),
          ),
        ],
      ),
    );
  }
}

AssistantChannelRecallKind _toolEventRecallKind(Map<String, dynamic> event) {
  final marker = [
    event['actor'],
    event['source'],
    event['trigger'],
    event['origin'],
    event['event_type'],
    event['type'],
  ].whereType<Object>().join(' ').toLowerCase();
  return marker.contains('auto') ||
          marker.contains('system') ||
          marker.contains('runtime')
      ? AssistantChannelRecallKind.automatic
      : AssistantChannelRecallKind.assistant;
}

String _firstText(Map<String, dynamic> record, List<String> keys) {
  for (final key in keys) {
    final value = record[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _formatTimestamp(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '时间未知';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = parsed.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
