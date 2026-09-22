import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/utils/chat_part_timeline.dart';

ChatMessagePart reasoning(int round, [String text = '想']) => ChatMessagePart(
  type: ChatMessagePartType.reasoning,
  round: round,
  text: text,
  status: 'done',
);

ChatMessagePart tool(int round, [String name = 'shell']) => ChatMessagePart(
  type: ChatMessagePartType.tool,
  round: round,
  status: 'done',
  tools: [ChatToolCallPart(id: 't$round', name: name)],
);

ChatMessagePart text(String value) =>
    ChatMessagePart(type: ChatMessagePartType.text, text: value);

ChatMessagePart image(String url) =>
    ChatMessagePart(type: ChatMessagePartType.image, url: url);

void main() {
  test('多轮 reasoning 和 tool 在正文前合成一个过程区段', () {
    final timeline = buildChatPartTimeline([
      reasoning(1),
      tool(1),
      reasoning(2),
      tool(2),
      tool(3),
      text('正文'),
    ], showReasoning: true);

    expect(timeline.map((item) => item.type), [
      ChatPartTimelineItemType.process,
      ChatPartTimelineItemType.part,
    ]);
    expect(
      timeline.where((item) => item.type == ChatPartTimelineItemType.process),
      hasLength(1),
    );
    expect(timeline.first.section!.visibleStepCount(showReasoning: true), 5);
    expect(timeline.first.section!.steps.map((step) => step.part.type), [
      ChatMessagePartType.reasoning,
      ChatMessagePartType.tool,
      ChatMessagePartType.reasoning,
      ChatMessagePartType.tool,
      ChatMessagePartType.tool,
    ]);
  });

  test('连续多轮纯 reasoning 合成一个思考区段', () {
    final timeline = buildChatPartTimeline([
      reasoning(1, '第一轮：正常理解用户在分享正在改 UI'),
      reasoning(2, '第二轮：被误触发后再次分析同一句话'),
    ], showReasoning: true);

    expect(timeline, hasLength(1));
    expect(timeline.single.type, ChatPartTimelineItemType.process);
    expect(timeline.single.section!.steps, hasLength(2));
    expect(timeline.single.section!.steps.map((step) => step.part.type), [
      ChatMessagePartType.reasoning,
      ChatMessagePartType.reasoning,
    ]);
  });

  test('工具前 exact user echo interim 被展示层过滤', () {
    final parts = [
      ChatMessagePart(
        type: ChatMessagePartType.text,
        round: 1,
        text: '我刚醒睡啥睡啊',
      ),
      tool(1, 'get_time'),
      reasoning(2, '确认时间'),
      text('哦，那是我搞错了。'),
    ];

    final filtered = suppressExactUserEchoInterimParts(
      parts,
      previousUserText: '  我刚醒睡啥睡啊  ',
    );

    expect(filtered, hasLength(3));
    expect(filtered.first.type, ChatMessagePartType.tool);
    expect(
      filtered
          .where((part) => part.type == ChatMessagePartType.text)
          .map((p) => p.text),
      ['哦，那是我搞错了。'],
    );
  });

  test('正常工具前临时正文不被误删', () {
    final parts = [
      ChatMessagePart(type: ChatMessagePartType.text, round: 1, text: '我查一下'),
      tool(1, 'get_time'),
      text('查到了。'),
    ];

    final filtered = suppressExactUserEchoInterimParts(
      parts,
      previousUserText: '现在几点',
    );

    expect(filtered, same(parts));
    expect(filtered.first.text, '我查一下');
  });

  test('正文和图片会切断过程区段', () {
    final timeline = buildChatPartTimeline([
      reasoning(1),
      tool(1),
      text('正文A'),
      reasoning(2),
      tool(2),
      image('https://example.com/a.png'),
      reasoning(3),
      text('正文B'),
    ], showReasoning: true);

    expect(timeline.map((item) => item.type), [
      ChatPartTimelineItemType.process,
      ChatPartTimelineItemType.part,
      ChatPartTimelineItemType.process,
      ChatPartTimelineItemType.part,
      ChatPartTimelineItemType.part,
      ChatPartTimelineItemType.part,
    ]);
    expect(timeline.where((item) => item.section != null), hasLength(2));
    expect(timeline[4].part!.part.type, ChatMessagePartType.reasoning);
  });

  test('思考关闭时混合区段只统计 tool', () {
    final timeline = buildChatPartTimeline([
      reasoning(1),
      tool(1),
      reasoning(2),
      tool(2),
      text('正文'),
    ], showReasoning: false);

    final section = timeline.first.section!;
    expect(
      section.visibleSteps(showReasoning: false).map((step) => step.part.type),
      [ChatMessagePartType.tool, ChatMessagePartType.tool],
    );
    expect(section.visibleStepCount(showReasoning: false), 2);
  });

  test('纯 reasoning 且思考关闭时完全不渲染过程占位', () {
    final timeline = buildChatPartTimeline([
      reasoning(1),
      reasoning(2),
    ], showReasoning: false);

    expect(timeline, isEmpty);
  });

  test('正文后的空 done tool 兼容标记不会生成第二个过程区段', () {
    final timeline = buildChatPartTimeline([
      reasoning(1),
      tool(1, '时间'),
      text('五点半了'),
      ChatMessagePart(type: ChatMessagePartType.tool, round: 1, status: 'done'),
    ], showReasoning: true);

    expect(timeline.map((item) => item.type), [
      ChatPartTimelineItemType.process,
      ChatPartTimelineItemType.part,
    ]);
    expect(timeline.where((item) => item.section != null), hasLength(1));
    expect(timeline.last.part!.part.type, ChatMessagePartType.text);
  });

  test('连续 12 个 tool 流式累计为一个当前过程区段', () {
    final timeline = buildChatPartTimeline([
      for (var i = 1; i <= 12; i++) tool(i),
    ], showReasoning: false);

    expect(timeline, hasLength(1));
    expect(timeline.single.type, ChatPartTimelineItemType.process);
    expect(timeline.single.section!.visibleStepCount(showReasoning: false), 12);
  });
}
