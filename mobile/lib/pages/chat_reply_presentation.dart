import '../models/message.dart';

/// Page-local text projection for the assistant reply currently being paced.
///
/// Runtime owns and mutates [reply]. This projection only records how much of
/// that canonical text has been presented, so persistence and lifecycle never
/// wait for the UI queue.
class ChatReplyPresentation {
  ChatMessage? _reply;
  final Map<String, String> _seenPartText = <String, String>{};
  final Map<String, String> _visiblePartText = <String, String>{};
  final Map<ChatMessagePart, String> _partSlotByIdentity = Map.identity();
  String _seenContent = '';
  String _visibleContent = '';
  int _unrevealedCharacters = 0;
  bool _terminal = false;
  bool _frozen = false;

  ChatMessage? get reply => _reply;
  String get visibleContent => _visibleContent;
  bool get terminal => _terminal;
  bool get hasUnrevealedText => _unrevealedCharacters > 0;
  bool get canRemove => _terminal && !hasUnrevealedText;

  /// Adopts already-persisted text as immediately visible. Only later suffixes
  /// returned by [captureNewText] are paced.
  void bind(ChatMessage reply) {
    _reply = reply;
    _seenContent = reply.content;
    _visibleContent = reply.content;
    _seenPartText.clear();
    _visiblePartText.clear();
    _partSlotByIdentity.clear();
    for (final entry in _textPartSlots(reply.parts)) {
      _partSlotByIdentity[entry.part] = entry.slot;
      _seenPartText[entry.slot] = entry.part.text;
      _visiblePartText[entry.slot] = entry.part.text;
    }
    _unrevealedCharacters = 0;
    _terminal = false;
    _frozen = false;
  }

  List<ChatReplyTextDelta> captureNewText(ChatMessage reply) {
    if (_frozen) return const [];
    if (!identical(_reply, reply)) {
      bind(reply);
      return const [];
    }

    final deltas = <ChatReplyTextDelta>[];
    final textParts = _textPartSlots(reply.parts).toList();
    if (textParts.isEmpty) {
      final suffix = _unseenSuffix(_seenContent, reply.content);
      _seenContent = reply.content;
      if (suffix.isNotEmpty) {
        deltas.add(ChatReplyTextDelta(suffix, round: 0));
      }
    } else {
      _partSlotByIdentity.clear();
      for (final entry in textParts) {
        final part = entry.part;
        final slot = entry.slot;
        _partSlotByIdentity[part] = slot;
        final seen = _seenPartText[slot];
        if (seen == null) {
          _seenPartText[slot] = part.text;
          _visiblePartText[slot] = '';
          if (part.text.isNotEmpty) {
            deltas.add(
              ChatReplyTextDelta(
                part.text,
                round: part.round,
                target: part,
                slot: slot,
              ),
            );
          }
          continue;
        }
        if (!part.text.startsWith(seen)) {
          // A canonical reconciliation replaced this text slot rather than
          // appending to it. Rebase immediately instead of duplicating text.
          _seenPartText[slot] = part.text;
          _visiblePartText[slot] = part.text;
          continue;
        }
        final suffix = _unseenSuffix(seen, part.text);
        _seenPartText[slot] = part.text;
        if (suffix.isNotEmpty) {
          deltas.add(
            ChatReplyTextDelta(
              suffix,
              round: part.round,
              target: part,
              slot: slot,
            ),
          );
        }
      }
      _seenContent = reply.content;
    }
    _unrevealedCharacters += deltas.fold(
      0,
      (sum, item) => sum + item.text.length,
    );
    return deltas;
  }

  void reveal(
    String canonicalText,
    String visibleText, {
    ChatMessagePart? target,
    String? slot,
  }) {
    if (canonicalText.isEmpty) return;
    _unrevealedCharacters = (_unrevealedCharacters - canonicalText.length)
        .clamp(0, 1 << 30)
        .toInt();
    _visibleContent += visibleText;
    final resolvedSlot =
        slot ?? (target == null ? null : _partSlotByIdentity[target]);
    if (resolvedSlot != null) {
      _visiblePartText[resolvedSlot] =
          (_visiblePartText[resolvedSlot] ?? '') + visibleText;
    }
  }

  void markTerminal() => _terminal = true;

  /// Freezes the exact assistant prefix that reached the screen at stop time.
  /// Later runtime deltas must not expand this projection or its durable copy.
  ({String content, List<ChatMessagePart> parts}) freeze() {
    final current = _reply;
    final parts = current == null
        ? <ChatMessagePart>[]
        : projectedParts(current);
    // The controller replaces reply.parts with these projected clones. Re-key
    // the identity maps now so projectedParts() keeps the frozen text after
    // that replacement instead of looking every clone up as unseen.
    _seenPartText.clear();
    _visiblePartText.clear();
    _partSlotByIdentity.clear();
    for (final entry in _textPartSlots(parts)) {
      _partSlotByIdentity[entry.part] = entry.slot;
      _seenPartText[entry.slot] = entry.part.text;
      _visiblePartText[entry.slot] = entry.part.text;
    }
    _seenContent = _visibleContent;
    _frozen = true;
    _terminal = true;
    _unrevealedCharacters = 0;
    return (content: _visibleContent, parts: parts);
  }

  List<ChatMessagePart> projectedParts(ChatMessage message) {
    if (!identical(_reply, message)) return message.parts;
    final textSlots = <ChatMessagePart, String>{};
    for (final entry in _textPartSlots(message.parts)) {
      textSlots[entry.part] = entry.slot;
    }
    return [
      for (final part in message.parts)
        ChatMessagePart(
          type: part.type,
          text: part.type == ChatMessagePartType.text
              ? (_visiblePartText[textSlots[part]] ?? '')
              : part.text,
          delta: part.delta,
          round: part.round,
          status: part.status,
          url: part.url,
          tools: part.tools,
        ),
    ];
  }

  void clear() {
    _reply = null;
    _seenPartText.clear();
    _visiblePartText.clear();
    _partSlotByIdentity.clear();
    _seenContent = '';
    _visibleContent = '';
    _unrevealedCharacters = 0;
    _terminal = false;
    _frozen = false;
  }

  static Iterable<({ChatMessagePart part, String slot})> _textPartSlots(
    List<ChatMessagePart> parts,
  ) sync* {
    final roundOrdinals = <int, int>{};
    for (final part in parts) {
      if (part.type != ChatMessagePartType.text) continue;
      final ordinal = roundOrdinals[part.round] ?? 0;
      roundOrdinals[part.round] = ordinal + 1;
      yield (part: part, slot: '${part.round}:$ordinal');
    }
  }

  static String _unseenSuffix(String seen, String canonical) {
    if (canonical == seen) return '';
    if (canonical.startsWith(seen)) return canonical.substring(seen.length);
    // Canonical replacement/reconciliation is authoritative. Treat the new
    // value as a fresh suffix without trying to infer overlap from replay.
    return canonical;
  }
}

class ChatReplyTextDelta {
  const ChatReplyTextDelta(
    this.text, {
    required this.round,
    this.target,
    this.slot,
  });

  final String text;
  final int round;
  final ChatMessagePart? target;
  final String? slot;
}
