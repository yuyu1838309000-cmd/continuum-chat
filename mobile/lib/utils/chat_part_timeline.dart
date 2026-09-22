import '../models/message.dart';

enum ChatPartTimelineItemType { process, part }

class ChatPartRef {
  const ChatPartRef({required this.index, required this.part});

  final int index;
  final ChatMessagePart part;
}

class ChatProcessSection {
  const ChatProcessSection({
    required this.startIndex,
    required this.endIndex,
    required this.steps,
  });

  final int startIndex;
  final int endIndex;
  final List<ChatPartRef> steps;

  List<ChatPartRef> visibleSteps({required bool showReasoning}) => [
    for (final step in steps)
      if (_isVisibleProcessStep(step.part, showReasoning: showReasoning)) step,
  ];

  int visibleStepCount({required bool showReasoning}) =>
      visibleSteps(showReasoning: showReasoning).length;

  bool get hasTool =>
      steps.any((step) => step.part.type == ChatMessagePartType.tool);

  bool get isRunning => steps.any(
    (step) => step.part.status == 'running' || step.part.status == 'streaming',
  );

  bool get isFailed => steps.any((step) => step.part.status == 'failed');
}

class ChatPartTimelineItem {
  const ChatPartTimelineItem._({required this.type, this.section, this.part});

  final ChatPartTimelineItemType type;
  final ChatProcessSection? section;
  final ChatPartRef? part;

  factory ChatPartTimelineItem.process(ChatProcessSection section) =>
      ChatPartTimelineItem._(
        type: ChatPartTimelineItemType.process,
        section: section,
      );

  factory ChatPartTimelineItem.part(ChatPartRef part) =>
      ChatPartTimelineItem._(type: ChatPartTimelineItemType.part, part: part);
}

List<ChatPartTimelineItem> buildChatPartTimeline(
  List<ChatMessagePart> parts, {
  required bool showReasoning,
}) {
  final items = <ChatPartTimelineItem>[];
  final pending = <ChatPartRef>[];
  var processStart = -1;

  void flushProcess() {
    if (pending.isEmpty) return;
    final section = ChatProcessSection(
      startIndex: processStart,
      endIndex: pending.last.index,
      steps: List<ChatPartRef>.unmodifiable(pending),
    );
    final visibleSteps = section.visibleSteps(showReasoning: showReasoning);
    if (section.hasTool || visibleSteps.length > 1) {
      items.add(ChatPartTimelineItem.process(section));
    } else if (showReasoning) {
      items.addAll(visibleSteps.map(ChatPartTimelineItem.part));
    }
    pending.clear();
    processStart = -1;
  }

  for (var i = 0; i < parts.length; i++) {
    // 旧版正文后可能残留一个空的完成标记；它没有独立展示价值，
    // 直接忽略，避免被切成正文后的第二个“过程”区块。
    if (_isRedundantToolDone(parts[i])) continue;
    final ref = ChatPartRef(index: i, part: parts[i]);
    if (_isProcessPart(parts[i])) {
      if (pending.isEmpty) processStart = i;
      pending.add(ref);
      continue;
    }
    flushProcess();
    items.add(ChatPartTimelineItem.part(ref));
  }
  flushProcess();
  return items;
}

List<ChatMessagePart> suppressExactUserEchoInterimParts(
  List<ChatMessagePart> parts, {
  String? previousUserText,
}) {
  final user = _normalizedText(previousUserText ?? '');
  if (user.isEmpty || parts.isEmpty) return parts;
  final filtered = <ChatMessagePart>[];
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final isEchoedInterim =
        part.type == ChatMessagePartType.text &&
        part.round > 0 &&
        _normalizedText(part.text.isNotEmpty ? part.text : part.delta) ==
            user &&
        parts
            .skip(i + 1)
            .any(
              (later) =>
                  later.type == ChatMessagePartType.tool &&
                  later.round == part.round,
            );
    if (!isEchoedInterim) filtered.add(part);
  }
  return filtered.length == parts.length ? parts : filtered;
}

String _normalizedText(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

bool _isProcessPart(ChatMessagePart part) =>
    part.type == ChatMessagePartType.reasoning ||
    part.type == ChatMessagePartType.tool;

// v0.2.193：旧版本可能在正文之后遗留一个没有工具详情的 done 标记。
// 它只表示“上一轮工具已经完成”，没有独立信息，不再渲染成第二个过程区块。
bool _isRedundantToolDone(ChatMessagePart part) =>
    part.type == ChatMessagePartType.tool &&
    part.status == 'done' &&
    part.tools.isEmpty;

bool _isVisibleProcessStep(
  ChatMessagePart part, {
  required bool showReasoning,
}) {
  return switch (part.type) {
    ChatMessagePartType.tool => true,
    ChatMessagePartType.reasoning =>
      showReasoning &&
          (part.text.trim().isNotEmpty ||
              part.delta.trim().isNotEmpty ||
              part.status == 'running' ||
              part.status == 'streaming'),
    ChatMessagePartType.text || ChatMessagePartType.image => false,
  };
}
