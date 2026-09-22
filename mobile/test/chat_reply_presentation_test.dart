import 'package:flutter_test/flutter_test.dart';
import 'package:continuum_chat/models/message.dart';
import 'package:continuum_chat/pages/chat_reply_presentation.dart';

void main() {
  test('canonical terminal can finish before presentation drains', () {
    final reply = ChatMessage(role: 'assistant', content: '');
    final presentation = ChatReplyPresentation()..bind(reply);
    final part = ChatMessagePart(type: ChatMessagePartType.text, text: '完整回复');
    reply
      ..content = '完整回复'
      ..parts = [part]
      ..runtimeStatus = 'completed';

    final deltas = presentation.captureNewText(reply);
    presentation.markTerminal();

    expect(reply.content, '完整回复');
    expect(reply.runtimeStatus, 'completed');
    expect(presentation.terminal, isTrue);
    expect(presentation.hasUnrevealedText, isTrue);
    expect(presentation.canRemove, isFalse);

    presentation.reveal(deltas.single.text, deltas.single.text, target: part);

    expect(presentation.canRemove, isTrue);
  });

  test('canonical content stays full while projected text is paced', () {
    final part = ChatMessagePart(type: ChatMessagePartType.text, text: '已经显示');
    final reply = ChatMessage(
      role: 'assistant',
      content: '已经显示',
      parts: [part],
    );
    final presentation = ChatReplyPresentation()..bind(reply);
    part.text = '已经显示，稍后显示';
    reply.content = '已经显示，稍后显示';

    final delta = presentation.captureNewText(reply).single;

    expect(reply.content, '已经显示，稍后显示');
    expect(presentation.visibleContent, '已经显示');
    expect(presentation.projectedParts(reply).single.text, '已经显示');

    presentation.reveal(delta.text, delta.text, target: delta.target);

    expect(presentation.visibleContent, reply.content);
    expect(presentation.projectedParts(reply).single.text, part.text);
  });

  test(
    'recreated text part keeps the visible prefix instead of disappearing',
    () {
      final reply = ChatMessage(role: 'assistant', content: '');
      final presentation = ChatReplyPresentation()..bind(reply);

      final firstPart = ChatMessagePart(
        type: ChatMessagePartType.text,
        text: '第一条已经显示',
        round: 1,
      );
      reply
        ..content = firstPart.text
        ..parts = [firstPart];
      final firstDelta = presentation.captureNewText(reply).single;
      expect(firstDelta.slot, '1:0');
      presentation.reveal(
        firstDelta.text,
        firstDelta.text,
        target: firstDelta.target,
        slot: firstDelta.slot,
      );

      final rebuiltPart = ChatMessagePart(
        type: ChatMessagePartType.text,
        text: '第一条已经显示，后面继续',
        round: 1,
      );
      reply
        ..content = rebuiltPart.text
        ..parts = [rebuiltPart];

      final nextDelta = presentation.captureNewText(reply).single;

      expect(nextDelta.text, '，后面继续');
      expect(nextDelta.slot, firstDelta.slot);
      expect(presentation.visibleContent, '第一条已经显示');
      expect(presentation.projectedParts(reply).single.text, '第一条已经显示');

      // Even if an old object identity is supplied after a canonical rebuild,
      // the stable slot keeps the reveal attached to the current text part.
      presentation.reveal(
        nextDelta.text,
        nextDelta.text,
        target: firstPart,
        slot: nextDelta.slot,
      );
      expect(presentation.projectedParts(reply).single.text, rebuiltPart.text);
    },
  );

  test('repeated controller notifications do not enqueue duplicate text', () {
    final part = ChatMessagePart(type: ChatMessagePartType.text);
    final reply = ChatMessage(role: 'assistant', content: '', parts: [part]);
    final presentation = ChatReplyPresentation()..bind(reply);
    part.text = '唯一正文';
    reply.content = '唯一正文';

    final first = presentation.captureNewText(reply);
    final repeated = presentation.captureNewText(reply);

    expect(first.map((delta) => delta.text), ['唯一正文']);
    expect(repeated, isEmpty);
  });

  test('pre-existing resumed text is visible and is not replay-animated', () {
    final part = ChatMessagePart(
      type: ChatMessagePartType.text,
      text: '恢复前已有',
      round: 1,
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '恢复前已有',
      parts: [part],
      runtimeStatus: 'running',
    );
    final presentation = ChatReplyPresentation()..bind(reply);

    expect(presentation.visibleContent, '恢复前已有');
    expect(presentation.projectedParts(reply).single.text, '恢复前已有');
    expect(presentation.captureNewText(reply), isEmpty);

    part.text += '，恢复后新增';
    reply.content += '，恢复后新增';

    expect(presentation.captureNewText(reply).map((delta) => delta.text), [
      '，恢复后新增',
    ]);
  });

  test('stop freezes the visible prefix and discards paced tail', () {
    final part = ChatMessagePart(
      type: ChatMessagePartType.text,
      text: '已经显示',
      round: 1,
    );
    final reply = ChatMessage(
      role: 'assistant',
      content: '已经显示',
      parts: [part],
    );
    final presentation = ChatReplyPresentation()..bind(reply);
    part.text += '，尚未显示的尾部';
    reply.content = part.text;
    final delta = presentation.captureNewText(reply).single;

    final frozen = presentation.freeze();
    reply
      ..content = frozen.content
      ..parts = frozen.parts;
    part.text += '，取消后的新尾部';

    expect(delta.text, '，尚未显示的尾部');
    expect(frozen.content, '已经显示');
    expect(frozen.parts.single.text, '已经显示');
    expect(presentation.projectedParts(reply).single.text, '已经显示');
    expect(presentation.captureNewText(reply), isEmpty);
    expect(presentation.hasUnrevealedText, isFalse);
    expect(presentation.canRemove, isTrue);
  });
}
