import 'package:uniun/features/shiv/generation/chat_helpers.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// The text to show for a stored reply. A reply that was cut short is saved
/// with a fixed marker (so history and branch summaries stay language-neutral);
/// the screen shows it in the user's language. Anything else is shown as is.
String replyDisplayText(String content, AppLocalizations l10n) {
  switch (content) {
    case kStoppedReply:
      return l10n.shivStopped;
    case kInterruptedReply:
      return l10n.shivInterrupted;
    default:
      return content;
  }
}
