import 'package:flutter/material.dart';
import 'package:uniun/core/enum/message_role.dart';
import 'package:uniun/common/widgets/drop_icon.dart';
import 'package:uniun/domain/entities/shiv/shiv_message_entity.dart';
import 'package:uniun/features/shiv/chat/widgets/shiv_sources_sheet.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// A single chat bubble — user on the right, Shiv on the left.
/// Matches the "Ethereal Interface" design: gradient user bubble,
/// surface-container-lowest Shiv card with ambient tinted shadow.
class ShivMessageBubble extends StatelessWidget {
  const ShivMessageBubble({
    super.key,
    required this.message,
    this.streamingContent,
    this.isLastAssistant = false,
    this.sourceNoteIds = const [],
    this.sourceChunkIds = const [],
  });

  final ShivMessageEntity message;

  /// Non-null only while this is the live-streaming assistant bubble.
  final String? streamingContent;

  /// True only for the latest assistant reply — gates the "Sources" chip.
  final bool isLastAssistant;

  /// Source-note ids that seeded the RAG context for this reply (last reply
  /// only; empty otherwise). Drives the "Sources" chip + sheet.
  final List<String> sourceNoteIds;

  /// `"<sha256>:<ordinal>"` ids of the PDF passages behind this reply, counted
  /// by the same chip and listed in the same sheet.
  final List<String> sourceChunkIds;

  bool get _isUser => message.role == MessageRole.user;

  String get _displayText => streamingContent ?? message.content;

  /// Splits text into the `<think>…</think>` reasoning block and the actual
  /// response. Returns `(thinking, response, isInThinkBlock)`.
  static ({String thinking, String response, bool isInThinkBlock}) _parseThinking(
      String text) {
    const open = '<think>';
    const close = '</think>';
    final start = text.indexOf(open);
    if (start == -1) return (thinking: '', response: text, isInThinkBlock: false);

    final end = text.indexOf(close);
    if (end == -1) {
      final thinkContent = text.substring(start + open.length);
      // If the model has generated a very long think block without closing,
      // it has likely hit the token limit mid-reasoning. Cap the display and
      // treat it as complete so the UI doesn't stay stuck open indefinitely.
      const maxThinkChars = 2000;
      if (thinkContent.length > maxThinkChars) {
        return (
          thinking: '${thinkContent.substring(0, maxThinkChars)}…',
          response: '',
          isInThinkBlock: false,
        );
      }
      return (
        thinking: thinkContent,
        response: '',
        isInThinkBlock: true,
      );
    }

    return (
      thinking: text.substring(start + open.length, end).trim(),
      response: text.substring(end + close.length).trimLeft(),
      isInThinkBlock: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isUser) {
      return Padding(
        padding: const EdgeInsets.only(left: 56, right: 16, bottom: 24),
        child: _UserBubble(text: _displayText),
      );
    }

    final parsed = _parseThinking(_displayText);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 56, bottom: 24),
      child: _ShivBubble(
        thinkingText: parsed.thinking,
        responseText: parsed.response,
        isStreaming: streamingContent != null,
        isInThinkBlock: parsed.isInThinkBlock,
        isLastAssistant: isLastAssistant,
        sourceNoteIds: sourceNoteIds,
        sourceChunkIds: sourceChunkIds,
      ),
    );
  }
}

// ── User bubble ─────────────────────────────────────────────────────────────

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              bottomLeft: Radius.circular(24),
              bottomRight: Radius.circular(24),
              topRight: Radius.circular(4),
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Theme.of(context).colorScheme.onPrimary,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _formatTime(DateTime.now()),
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.2,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }
}

// ── Shiv bubble ─────────────────────────────────────────────────────────────

class _ShivBubble extends StatelessWidget {
  const _ShivBubble({
    required this.thinkingText,
    required this.responseText,
    required this.isStreaming,
    required this.isInThinkBlock,
    required this.isLastAssistant,
    required this.sourceNoteIds,
    required this.sourceChunkIds,
  });

  final String thinkingText;
  final String responseText;
  final bool isStreaming;
  final bool isInThinkBlock;
  final bool isLastAssistant;
  final List<String> sourceNoteIds;
  final List<String> sourceChunkIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showTyping =
        isStreaming && responseText.trim().isEmpty && !isInThinkBlock;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Avatar + label row
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: DropIcon(
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              l10n.shivName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Thinking indicator — visible only while the model is still reasoning.
        // Hidden completely once the response arrives.
        if (isInThinkBlock)
          _ThinkingBlock(
            text: thinkingText,
            streamingLabel: l10n.shivThinking,
          ),

        if (isInThinkBlock && responseText.isNotEmpty) const SizedBox(height: 6),

        // Response card — hidden while entirely inside think block
        if (!isInThinkBlock)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(24),
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: showTyping
                ? const _TypingIndicator(key: ValueKey('shiv-typing-indicator'))
                : (!isStreaming &&
                          responseText.trim().isEmpty &&
                          thinkingText.isEmpty)
                      // A reply that ended with nothing to show (an empty
                      // completion, or reasoning only) is stored blank.
                      ? Text(
                          l10n.shivNoResponse,
                          style: TextStyle(
                            fontSize: 15,
                            fontStyle: FontStyle.italic,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        )
                      : _MarkdownText(text: responseText),
          ),

        // "Sources" chip — only under the latest reply, once it's complete,
        // and only when real notes or PDF passages seeded the answer.
        if (!isInThinkBlock &&
            isLastAssistant &&
            !isStreaming &&
            responseText.isNotEmpty &&
            (sourceNoteIds.isNotEmpty || sourceChunkIds.isNotEmpty)) ...[
          const SizedBox(height: 8),
          _SourcesChip(
            count: sourceNoteIds.length + sourceChunkIds.length,
            onTap: () => ShivSourcesSheet.show(
              context,
              sourceNoteIds,
              chunkIds: sourceChunkIds,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Sources chip ──────────────────────────────────────────────────────────────
// Tappable pill under the last reply that opens the RAG source-notes sheet.

class _SourcesChip extends StatelessWidget {
  const _SourcesChip({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(99),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_rounded,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.shivSourcesChip(count),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Thinking indicator ───────────────────────────────────────────────────────
// Shown only while the model is inside a <think> block.
// Disappears completely once </think> is received and response begins.

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({
    required this.text,
    required this.streamingLabel,
  });

  final String text;
  final String streamingLabel;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _pulse;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tap row — always visible
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeTransition(
                    opacity: _pulseAnim,
                    child: Icon(
                      Icons.psychology_outlined,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.streamingLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),

          // Expanded: raw think content (for users who want to see it)
          if (_expanded && widget.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Text(
                widget.text,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Lightweight markdown renderer ────────────────────────────────────────────
// Handles: **bold**, *italic*, `code`, # headers, - bullet lists.
// Everything else is rendered as plain text.

class _MarkdownText extends StatelessWidget {
  const _MarkdownText({required this.text});
  final String text;

  static TextStyle _baseFor(BuildContext context) => TextStyle(
        fontSize: 15,
        height: 1.6,
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.w400,
      );

  // Compiled once and reused for every line of every build — re-creating these
  // inside the loop recompiled the pattern per line per token while streaming.
  static final RegExp _heading = RegExp(r'^(#{1,3})\s+(.+)');
  static final RegExp _bullet = RegExp(r'^[\-\*]\s+(.+)');

  @override
  Widget build(BuildContext context) {
    final base = _baseFor(context);
    final lines = text.split('\n');
    final widgets = <Widget>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Heading: # / ## / ###
      final headMatch = _heading.firstMatch(line);
      if (headMatch != null) {
        final level = headMatch.group(1)!.length;
        final content = headMatch.group(2)!;
        widgets.add(Padding(
          padding: EdgeInsets.only(top: i > 0 ? 8 : 0, bottom: 2),
          child: Text(
            content,
            style: base.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: level == 1 ? 18 : level == 2 ? 16 : 15,
            ),
          ),
        ));
        continue;
      }

      // Bullet: - item or * item
      final bulletMatch = _bullet.firstMatch(line);
      if (bulletMatch != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('• ', style: base.copyWith(fontWeight: FontWeight.w600)),
              Expanded(child: _InlineText(text: bulletMatch.group(1)!, base: base, codeBg: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08))),
            ],
          ),
        ));
        continue;
      }

      // Empty line → spacing
      if (line.trim().isEmpty) {
        if (i > 0 && i < lines.length - 1) widgets.add(const SizedBox(height: 6));
        continue;
      }

      // Regular paragraph with inline formatting
      widgets.add(_InlineText(text: line, base: base, codeBg: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

/// Renders inline markdown: **bold**, *italic*, `code`.
class _InlineText extends StatelessWidget {
  const _InlineText(
      {required this.text, required this.base, required this.codeBg});
  final String text;
  final TextStyle base;
  final Color codeBg;

  // **bold**, *italic*, `code` — compiled once, reused for every call.
  static final RegExp _pattern = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`');

  // Bounded parse cache keyed by input line. While streaming, [_MarkdownText]
  // rebuilds every line widget each token, but only the last line's text
  // actually changes — caching means the unchanged earlier lines hit instead
  // of re-parsing. `base` is invariant (always [_MarkdownText._base]), so the
  // input string alone is a sufficient key. Capped so a long stream's growing
  // last line can't grow the cache unbounded.
  static final Map<String, TextSpan> _cache = {};
  static const _cacheCap = 128;

  @override
  Widget build(BuildContext context) {
    return Text.rich(_parseInline(text, base, codeBg));
  }

  static TextSpan _parseInline(String input, TextStyle base, Color codeBg) {
    final cached = _cache[input];
    if (cached != null) return cached;

    // Pattern priority: **bold**, *italic*, `code`
    final spans = <InlineSpan>[];
    int cursor = 0;

    for (final m in _pattern.allMatches(input)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: input.substring(cursor, m.start), style: base));
      }
      if (m.group(1) != null) {
        // **bold**
        spans.add(TextSpan(text: m.group(1), style: base.copyWith(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        // *italic*
        spans.add(TextSpan(text: m.group(2), style: base.copyWith(fontStyle: FontStyle.italic)));
      } else if (m.group(3) != null) {
        // `code`
        spans.add(TextSpan(
          text: m.group(3),
          style: base.copyWith(
            fontFamily: 'monospace',
            backgroundColor: codeBg,
            fontSize: 13,
          ),
        ));
      }
      cursor = m.end;
    }
    if (cursor < input.length) {
      spans.add(TextSpan(text: input.substring(cursor), style: base));
    }

    final span = TextSpan(children: spans);
    if (_cache.length >= _cacheCap) _cache.remove(_cache.keys.first);
    _cache[input] = span;
    return span;
  }
}

// ── Typing indicator ─────────────────────────────────────────────────────────

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => _Dot(delay: Duration(milliseconds: i * 200)),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.delay});
  final Duration delay;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _anim = Tween(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    Future.delayed(widget.delay, () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: FadeTransition(
        opacity: _anim,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
