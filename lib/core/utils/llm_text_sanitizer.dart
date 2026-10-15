import 'dart:convert';

import 'package:uniun/core/constants/app_constants.dart';

/// Cleans raw text emitted by on-device LLMs (flutter_edge_ai) before it
/// is persisted or shown to a user.
///
/// The model stream leaks three classes of garbage we always want to
/// remove regardless of which surface consumed it (Shiv chat, Gana
/// publish, Manas note extraction, etc.):
///
///   1. **Reasoning blocks (`<think>...</think>`).** Qwen3 and DeepSeek
///      R1 prefix their answer with chain-of-thought wrapped in
///      `<think>` tags. The closing tag may be missing if the model
///      hits maxTokens mid-thought — in which case the entire body is
///      reasoning, not the answer. We strip the block. If only an
///      opening tag is present (truncated), we return empty so the
///      caller treats it as `<NOOP>`.
///
///   2. **Tool-call envelopes.** Qwen3 can't actually emit a tool call,
///      so when prompted with "call publish_message(body=…)" it writes
///      the envelope as plain text. We strip the outer wrapper and keep
///      the inner string. Also handles loose JSON `{"body":"…"}`.
///
///   3. **GPT-2 / BPE byte-encoding leaks.** flutter_edge_ai's tokenizer
///      represents raw bytes 0x80–0xFF (and 0x00–0x20, 0x7F, 0xAD) as
///      specific Unicode codepoints in Latin Extended-A so the stream
///      is always valid UTF-16. The detokenizer normally reverses this;
///      when it leaks, we see things like `🌱` arriving as `ðŁĮ±` (its
///      4 UTF-8 bytes 0xF0 0x9F 0x8C 0xB1, each remapped). The fix is
///      the inverse of HuggingFace `bytes_to_unicode()`: map each char
///      back to its byte, decode the resulting array as UTF-8.
///
/// Emojis are first-class — we restore them, never drop them.
class LlmTextSanitizer {
  const LlmTextSanitizer._();

  static final RegExp _toolCall = RegExp(
    r'''^\s*publish_message\s*[\(\{]\s*(?:body|"body"|'body')\s*[:=]\s*(['"])([\s\S]*)\1\s*[\)\}]\s*$''',
  );
  static final RegExp _looseJson = RegExp(
    r'''^\s*\{\s*(?:"body"|'body')\s*:\s*(['"])([\s\S]*)\1\s*\}\s*$''',
  );
  // Matches a balanced <think>...</think> anywhere in the string.
  // Non-greedy so multiple blocks each get stripped.
  static final RegExp _thinkBalanced = RegExp(
    r'<think>[\s\S]*?</think>',
    caseSensitive: false,
  );
  // Matches an OPEN tag with no close (model was cut off mid-thought).
  /// A leading `Shiv:` the model copied from the prompt's answer cue.
  static final RegExp _echoedLabel = RegExp(
    '^\\s*' + AppConstants.kShivLabel + '\\s*:\\s*',
    caseSensitive: false,
  );

  static final RegExp _thinkOpenOnly = RegExp(
    r'<think>[\s\S]*$',
    caseSensitive: false,
  );

  /// Sanitize one chunk of model output. Pure function — safe to call
  /// from any isolate.
  static String clean(String raw) {
    var s = raw.trim();

    // 1. Strip <think>...</think> reasoning blocks (Qwen3, DeepSeek R1).
    //    Balanced first; if an unmatched open tag remains, the model was
    //    cut off mid-reasoning and there is no answer at all — return
    //    empty so the caller's NOOP branch fires.
    s = s.replaceAll(_thinkBalanced, '').trim();
    if (_thinkOpenOnly.hasMatch(s)) return '';

    // 2. Strip tool-call envelopes.
    final fnCall = _toolCall.firstMatch(s);
    if (fnCall != null) {
      s = fnCall.group(2)!;
    } else {
      final json = _looseJson.firstMatch(s);
      if (json != null) s = json.group(2)!;
    }

    // 3. Drop an echoed answer-cue label. Every chat prompt ends with
    //    `Shiv:` to stop a small model answering as the user; the model
    //    sometimes copies that label into its reply. Model-agnostic — it
    //    keys off our own cue, not any model's format.
    s = s.replaceFirst(_echoedLabel, '').trim();

    // 4. Reverse GPT-2 byte_to_unicode in runs.
    //    The model usually detokenizes correctly (so most text is plain
    //    UTF-16); only multi-byte sequences like emojis leak through as
    //    a run of byte-encoded chars (e.g. `ðŁĮ±` for 🌱). We scan for
    //    those runs and decode each independently — leaving the rest of
    //    the string untouched.
    s = _repairByteRuns(s);

    return s.trim();
  }

  /// True when [clean]'s repair failed and [s] is still broken bytes.
  ///
  /// [clean] is best-effort; this reports whether it succeeded.
  static bool looksCorrupted(String s) {
    if (s.isEmpty) return false;
    // U+FFFD — decode already failed upstream.
    if (s.contains('\uFFFD')) return true;
    // Remapped GPT-2 byte chars surviving [clean] = repair produced no valid
    // UTF-8.
    for (final c in s.codeUnits) {
      if (c >= 0x0100 && c <= 0x0143) return true;
    }
    return false;
  }

  /// True when [s] has collapsed into a repetition loop.
  ///
  /// Scored by vocabulary richness rather than n-gram matching, so it catches
  /// both `a b a b` and longer stuck phrases. Texts under [minWords] are exempt:
  /// a short translation repeating a word is not a failure.
  static bool looksDegenerate(String s, {int minWords = 12}) {
    final words = s
        .toLowerCase()
        .split(RegExp(r'[\s\u0964\u3001,.!?;:]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length < minWords) return false;
    final distinct = words.toSet().length;
    return distinct / words.length < 0.35;
  }

  /// Walk `s`, find contiguous runs of chars that map to single bytes
  /// under HuggingFace's `bytes_to_unicode`, and if any char in the run
  /// is a *remapped* one (U+0100..U+0143 — never appears in normal
  /// English/UI text), try to UTF-8-decode the byte array. On success
  /// substitute the run; on failure leave it.
  static String _repairByteRuns(String s) {
    // Fast path: byte-repair only ever changes the string when it contains a
    // *remapped* char (U+0100..U+0143), which appears only on the rare emoji/
    // multibyte mojibake leak. The common case is plain text — scan once and
    // bail out before allocating a StringBuffer or rewriting every char. This
    // keeps the per-token streaming sanitize allocation-free for normal text.
    final units = s.codeUnits;
    bool hasRemapped = false;
    for (final c in units) {
      if (c >= 0x0100 && c <= 0x0143) {
        hasRemapped = true;
        break;
      }
    }
    if (!hasRemapped) return s;

    final out = StringBuffer();
    int i = 0;
    while (i < units.length) {
      // Start of a potential byte run.
      final runStart = i;
      final bytes = <int>[];
      bool hasRemappedChar = false;
      while (i < units.length) {
        final c = units[i];
        final b = _charToByte(c);
        if (b == null) break;
        bytes.add(b);
        if (c >= 0x0100 && c <= 0x0143) hasRemappedChar = true;
        i++;
      }
      if (bytes.isEmpty) {
        // No mappable char here; emit one codepoint and advance.
        out.writeCharCode(units[i]);
        i++;
        continue;
      }
      // Only attempt UTF-8 decode if the run contains at least one
      // remapped char — otherwise we'd mangle genuine Latin-1 text
      // (¡cómo estás? has 'ó' = 0xF3 etc., a valid passthrough char).
      if (hasRemappedChar) {
        try {
          final decoded =
              const Utf8Decoder(allowMalformed: false).convert(bytes);
          out.write(decoded);
          continue;
        } catch (_) {
          // Not valid UTF-8 — fall through and emit verbatim.
        }
      }
      // Emit the original chars verbatim.
      for (var k = runStart; k < i; k++) {
        out.writeCharCode(units[k]);
      }
    }
    return out.toString();
  }

  static int? _charToByte(int c) {
    // Passthrough ranges.
    if (c >= 0x21 && c <= 0x7E) return c;
    if (c >= 0xA1 && c <= 0xAC) return c;
    if (c >= 0xAE && c <= 0xFF) return c;
    // Remapped: U+0100..U+0143 → 68 specific bytes in this order:
    //   bytes 0x00..0x20  (33 bytes)  → U+0100..U+0120
    //   byte  0x7F        (1 byte)    → U+0121
    //   bytes 0x80..0xA0  (33 bytes)  → U+0122..U+0142
    //   byte  0xAD        (1 byte)    → U+0143
    if (c < 0x0100 || c > 0x0143) return null;
    final n = c - 0x0100;
    if (n <= 0x20) return n;            //  0..32   → 0x00..0x20
    if (n == 0x21) return 0x7F;         //  33      → 0x7F
    if (n >= 0x22 && n <= 0x42) {
      return 0x80 + (n - 0x22);          //  34..66  → 0x80..0xA0
    }
    if (n == 0x43) return 0xAD;         //  67      → 0xAD
    return null;
  }
}
