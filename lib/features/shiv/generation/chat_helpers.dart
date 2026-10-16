import 'package:uniun/core/enum/message_role.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/entities/shiv/shiv_message_entity.dart';

/// Pure, reusable chat-text helpers shared by the Shiv chat bloc and any other
/// chat surface (e.g. the composer-chat in WS4). Kept out of the bloc so both
/// can reuse them without cross-bloc coupling.

/// What a reply is stored as when the user pressed Stop before any text came,
/// or the chat was closed mid-reply. Shown localized by `replyDisplayText`.
const String kStoppedReply = '(stopped)';
const String kInterruptedReply = '(interrupted)';

/// Removes `<think>...</think>` blocks emitted by reasoning models (DeepSeek R1,
/// Qwen3) before content is persisted — keeps model reasoning out of stored
/// messages, branch summaries, and any future RAG lookups.
String stripThinking(String content) => content
    .replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '')
    .trim();

/// Walk the `parentId` chain from [leafId] up to the root; returns the branch's
/// messages in chronological order (root first).
List<ShivMessageEntity> buildBranch(
  String leafId,
  List<ShivMessageEntity> all,
) {
  final byId = {for (final m in all) m.messageId: m};
  final branch = <ShivMessageEntity>[];
  String? current = leafId;
  while (current != null) {
    final msg = byId[current];
    if (msg == null) break;
    branch.insert(0, msg);
    current = msg.parentId;
  }
  return branch;
}

/// Flatten the current surface's recent notes (a thread / group / DM /
/// private group) into short `"@author: text"` context lines for the
/// composer-chat (WS4). Keeps the most recent [max], oldest first, each trimmed
/// to [maxChars]. Surface-agnostic — every surface holds [NoteEntity]s.
List<String> entityContextLines(
  List<NoteEntity> notes, {
  int max = 12,
  int maxChars = 240,
}) {
  final recent = notes.length > max ? notes.sublist(notes.length - max) : notes;
  return [
    for (final n in recent)
      '${_shortPubkey(n.authorPubkey)}: '
          '${n.content.length > maxChars ? '${n.content.substring(0, maxChars)}…' : n.content}',
  ];
}

String _shortPubkey(String pubkey) =>
    pubkey.length <= 8 ? '@$pubkey' : '@${pubkey.substring(0, 8)}';

/// Walk [messages] in order and emit clean `(user, assistant)` text pairs,
/// skipping empty placeholders and orphan user turns at the tail. Caps to the
/// most recent [maxPairs] pairs so the prompt stays small but keeps continuity.
List<(String, String)> pairCleanHistory(
  List<ShivMessageEntity> messages, {
  required int maxPairs,
}) {
  final pairs = <(String, String)>[];
  String? pendingUser;
  for (final m in messages) {
    final content = m.content.trim();
    if (content.isEmpty) continue;
    if (m.role == MessageRole.user) {
      pendingUser = content;
    } else if (pendingUser != null) {
      pairs.add((pendingUser, content));
      pendingUser = null;
    }
  }
  if (pairs.length <= maxPairs) return pairs;
  return pairs.sublist(pairs.length - maxPairs);
}
