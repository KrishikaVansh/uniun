import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uniun/common/snackbar.dart';
import 'package:uniun/features/shiv/chat/utils/reply_marker_label.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_state.dart';
import 'package:uniun/l10n/app_localizations.dart';
import 'package:uniun/core/theme/app_custom_colors.dart';

/// The inline Shiv chat surface shown INSIDE the composer (above the text
/// field) while it is in Manas-chat mode. A Shiv-branded header (scope +
/// exit), the Q&A turns, the in-flight streamed answer, and — under each
/// completed answer — Copy / Use-as-reply actions.
///
/// [onUseAsReply] drops a finished answer back into the composer as an editable
/// reply draft (the host fills the text field and leaves chat mode). Copy is
/// self-contained (clipboard + snackbar).
class ComposerChatPanel extends StatelessWidget {
  const ComposerChatPanel({
    super.key,
    required this.state,
    required this.onExit,
    required this.onStop,
    required this.onUseAsReply,
  });

  final ComposerChatState state;
  final VoidCallback onExit;
  final VoidCallback onStop;
  final void Function(String text) onUseAsReply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scope = state.manasName ?? l10n.composerChatAllNotes;
    final hasConversation = state.turns.isNotEmpty || state.streaming != null;
    final isStreaming = state.status == ComposerChatStatus.streaming;

    // No card: the panel flows as the top section of the composer surface.
    // A single hairline at the bottom fences the chat region off from the
    // text field, so it reads as part of the sheet — not a floating element.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(scope: scope, onExit: onExit),
        const SizedBox(height: 10),
        if (!hasConversation)
          _GroundedHint(scope: scope)
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in state.turns) ...[
                    _Bubble(text: t.question, isUser: true),
                    if (t.answer.isNotEmpty) ...[
                      _Bubble(
                        text: replyDisplayText(t.answer, l10n),
                        isUser: false,
                      ),
                      _AnswerActions(
                          text: t.answer, onUseAsReply: onUseAsReply),
                    ],
                  ],
                  if (state.streaming != null)
                    _Bubble(
                      text: state.streaming!.isEmpty
                          ? l10n.composerChatThinking
                          : state.streaming!,
                      isUser: false,
                      dim: state.streaming!.isEmpty,
                    ),
                ],
              ),
            ),
          ),
        if (state.status == ComposerChatStatus.noModel) ...[
          const SizedBox(height: 8),
          _StatusText(text: l10n.composerChatNoModel),
        ],
        if (state.status == ComposerChatStatus.error) ...[
          const SizedBox(height: 8),
          _StatusText(
            text: state.errorMessage ?? l10n.composerChatError,
            isError: true,
          ),
        ],
        if (isStreaming)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: Text(l10n.composerChatStop),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        const SizedBox(height: 10),
        Divider(height: 1, thickness: 1, color: context.custom.borderSubtle),
      ],
    );
  }
}

/// Shiv-branded banner: a primary glyph chip, the "Shiv" title, an uppercase
/// "{scope} · on-device" eyebrow, and the exit button.
class _Header extends StatelessWidget {
  const _Header({required this.scope, required this.onExit});

  final String scope;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // A flush row on the composer surface — no background, no border.
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.auto_awesome_rounded,
              size: 16, color: Theme.of(context).colorScheme.onPrimary),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.composerChatBrand,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.composerChatScopeEyebrow(scope).toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onExit,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Icon(Icons.close_rounded,
              size: 19, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// Empty-state pill shown before the first question — reinforces what the chat
/// is grounded in.
class _GroundedHint extends StatelessWidget {
  const _GroundedHint({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: context.custom.borderSubtle),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tips_and_updates_outlined,
                size: 14, color: context.custom.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l10n.composerChatGroundedHint(scope),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.custom.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copy / Use-as-reply actions shown beneath a completed AI answer.
class _AnswerActions extends StatelessWidget {
  const _AnswerActions({required this.text, required this.onUseAsReply});

  final String text;
  final void Function(String text) onUseAsReply;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8, left: 2),
      child: Row(
        children: [
          _ActionChip(
            icon: Icons.content_copy_rounded,
            label: l10n.actionCopy,
            onTap: () {
              Clipboard.setData(ClipboardData(text: text));
              AppSnackbar.success(context, l10n.actionCopied);
            },
          ),
          const SizedBox(width: 4),
          _ActionChip(
            icon: Icons.reply_rounded,
            label: l10n.composerChatUseAsReply,
            onTap: () => onUseAsReply(text),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: isError ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A chat bubble — your question (primary, right) or a Shiv answer (white card,
/// left). Mirrors the design-system `MessageBubble` corner/treatment.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.isUser, this.dim = false});

  final String text;
  final bool isUser;

  /// Muted + italic styling for the transient "Thinking…" placeholder.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        decoration: BoxDecoration(
          color: isUser ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surface,
          border: isUser ? null : Border.all(color: context.custom.borderSubtle),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isUser ? 16 : 4),
            topRight: Radius.circular(isUser ? 4 : 16),
            bottomLeft: const Radius.circular(16),
            bottomRight: const Radius.circular(16),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            fontStyle: dim ? FontStyle.italic : FontStyle.normal,
            color: isUser
                ? Theme.of(context).colorScheme.onPrimary
                : (dim ? context.custom.textMuted : context.custom.textBody),
          ),
        ),
      ),
    );
  }
}
