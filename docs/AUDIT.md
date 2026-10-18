# Engineering Audit Log

This is the **technical** companion to `CHANGELOG.md`. `CHANGELOG.md` stays terse and user-facing, following Keep a Changelog conventions — this file is where the actual engineering detail behind each release lives: what was found, what was verified against the real code (not guessed), what broke and why, and what's still open. Each entry maps to one or more `CHANGELOG.md` versions but goes deep where the changelog stays shallow.

Format: one dated section per audit pass, newest first. Each item states what was done, how it was verified, and — where relevant — what's still outstanding.

---

## 2026-10-18 — after v3.1.0: flutter_edge_ai 2.3, note deletion, Shiv regressions, faster embedding

Covers #283, #290, #291, #292, #295, #297 and #298. All device results are from the vivo 1933 (Snapdragon 710, Android 11); no second phone was available.

**Test coverage (#283).** Line coverage 74.99 % → 80.03 % with gateway, transport and widget tests and two new `test/integration/` flows. Writing them found two real bugs: the relay disconnect hang (#281, fixed in #298 below) and a flaky vector test (#282).

**flutter_edge_ai 2.3 (#290).** `flutter_gemma` became `flutter_edge_ai` 2.3.2 (`_litertlm` 1.13.2, native LiteRT-LM 0.18.0-e, `_embeddings` 2.3.0, `_mediapipe` 1.2.2, dev `_diagnostics`). API changes handled: `enableThinking`, `embed(EmbeddingInput.text(..), taskType:)`, `embeddingTokenizers` at init, and over-long embedding input now throws `EmbeddingInputTooLongException` (the service shrinks and retries). **Qwen3 0.6B's plain `.litertlm` no longer loads** ("Failed to create engine" on GPU and CPU, every `maxTokens`): LiteRT-LM ≥0.17 links SentencePiece 0.2.2, which rejects a NUL-byte piece in that file (upstream flutter_edge_ai#659, LiteRT-LM#3865, confirmed by the maintainer). The catalog now uses `Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm` (329 MB, Hugging Face tokenizer); users of the old file re-download. Verified on the phone with both models: notes Q&A, stop mid-reply, repeated chats (memory within limits), model switch, long-note embedding. Same PR: an extract-only queue no longer stalls on the T2 soft budget (#287; the cap now applies only while T3/T4 work waits). One Gemma 4 E2B stall right after a Qwen → Gemma engine switch happened once and did not reproduce in two re-runs (noted on #659).

**Deleting a note removes everything derived from it (#291, #288).** Root cause found on the phone: tostore keeps deleted vectors in its search index (236 ghost hits for one stored vector), and no deletion path removed vectors, memory summaries or graph edges, so old notes kept taking top-K slots and old summaries leaked into answers. Now every deletion goes through `purgeNotesInTxn` (one transaction: note, unread and relation rows, memory, graph edges with shared concepts kept, pending rows, and a `PendingVectorDelete` row); `NoteVectorCleanupWorker` drains that queue, sweeps vectors with no note on launch, and the store rebuilds its index 30 s after a burst of deletes. A still-saved note keeps its vector. Purging 3,000 notes with knowledge takes about 2 s (index lookups, not scans). Verified on the phone: 7 leftover ghost hits gone after the launch pass; a note embedded for real, then deleted, is gone from the store and from search without a restart.

**Shiv regressions (#292).**
- **#199 "the same reply to every question" was reproduced and fixed.** With one unrelated note on the phone, Qwen3 0.6B answered "Marmalade" to every capital question, in a new chat too. Cause: any note scores ~0.6-0.7 against any question with Gecko, so the 0.3 cut-off fed the closest note into every prompt, and the 0.6B model copies it. Qwen3 0.6B now needs 0.72 (other models and cloud keep 0.3), for notes, document chunks and the composer-chat "All notes" search. Calibrated on the phone: answering notes 0.74-0.85 against unrelated ≤0.70 (one vague question 0.64); chunks 0.78-0.85 against ≤0.71. Device calibration tests fail if the gap closes.
- **#123:** a reply that ended with no visible text was saved as a blank bubble; it now shows a localized "No response from the model." `(stopped)` / `(interrupted)` are shown localized too.
- **#139:** no crash seen; a device guard fills Nataraj three times with flat memory (Android only).
- The UNIUN Cloud free model returned empty or HTTP 500 during this work, so no cloud test was written (#293).

**Faster embedding (#295, #266).** The 256-token Gecko file is now bundled next to the 1024 one (both byte-identical to `litert-community/Gecko-110m-en`). For the same text the two files return the same vector (cosine 1.0000), so the index needs no re-embedding. Measured: one embed 2.2 s (256) against 11.7 s (1024); a switch between files ~1.1 s; a too-long input rejected in ~15 ms. A question, a short note and a PDF chunk now take 2.2 s instead of 11.7 s; a long note 13.1 s (switch plus one 1024 embed). The earlier noisy numbers in #266 came from the old measuring test, which skipped the install when any embedder was active. Chunking long notes to fit the short file was measured and not done: 700-character chunks found parts of long notes slightly better (27/28 vs 25/28 first) but pushed a short note out of the top 3 (15/16) and let one note fill the top results for 32/44 questions. Dropping the 1024 file with chunking is tracked in #296.

**A failed embedder switch (#297).** Found reviewing #295 after merge: if loading the other Gecko file failed, the service kept the already-closed model and reported ready, so the note worker counted every queued note as failed and dropped it after three tries. A failed load now leaves the service not ready (the worker keeps the queue).

**Relay disconnect hang (#298, #281).** `RelayConnection.disconnect()` waited for a socket that never connected to confirm its close, which never happens. Reconnecting was never affected (backoff 1 s … 60 s, forever). In the app it hit removing an unreachable relay in Settings: that sync call stayed stuck and relays removed in the same change could stay open. Logout and the Gateway stop were not affected (the isolate is killed directly), contrary to the issue text. A never-connected socket is now closed without waiting, a live one is given 2 s at most, and the streams always close. Covered against a real loopback relay; 4 tests fail with the old code.

---

## Open items carried into v3.1.0

The detailed entries up to v3.1.0 were cleared when it shipped; they remain in git history
(`git log -p -- docs/AUDIT.md`). These are the things from them, and from the v3.0.0 list
before them, that were not resolved:

**Still open from v3.0.0**
- **Android GPU crash on one device class.** On a vivo 1933 / Android 11 / Adreno phone, creating the GPU engine intermittently kills the process inside the vendor GPU driver (`SIGSEGV` in `libgsl.so`). Shipped deliberately with GPU preferred; no fix upstream yet.
- **The graph's drag and simulation feel is untested on a device** after the Obsidian rewrite. Its performance test is `integration_test/graph_simulation_perf_test.dart`. (Tapping a node and adding it to a Manas was exercised on a vivo 1933 in 3.1, #261.)
- **Hindi/Hinglish retrieval on real scans is still weak** (the English-centred embedder and noisy Devanagari OCR); the keyword-side fix is in, the rest needs a better embedder or OCR.
- `maxOutputTokens` is unused in `InferenceScheduler`, so a runaway one-shot generation runs until the KV cache fills. (The T2 soft-budget stall listed here was fixed in #287/#290.)
- The OCR and chart-reading thresholds in `page_ocr_plan.dart` (50 %, 25 %, 20 characters, the Word picture sizes) are unmeasured on real documents.

**New in 3.1**
- **iOS is unverified for everything in this release** (it cannot be built from the Linux dev machine): Gujarati and Japanese layouts, the chat open-at-first-unread list, the unread trail, Gana dashboard and Brahma/No-knowledge scopes, image input in chat, logout reset, and the background Gana tick. The CI iOS build only proves it compiles.
- **Gujarati is machine-assisted**; a native review of phrasing is still wanted (#271). Japanese was not natively reviewed either.
- **Embedding speed** was fixed in #295 (2.2 s for most text, see the entry above). Left: the app is 114 MB larger for the second Gecko file; notes over ~4,500 characters are still cut to fit; dropping the 1024 file needs note chunking and a re-measure (#296); only the Snapdragon 710 was measured.
- **Notes saved before the embedding queue (3.1) were never backfilled**: they have no vector until they are saved again (#232). Re-embedding now costs about 2.2 s a note (11.7 s if long).
- **Image input in chat**: the photo is not shown in the sent bubble or kept in the conversation, one image per message, Gemma 4 E4B and prefill time/memory with a large photo were not measured, and the engine rebuild on the first image turn is untimed.
- **Unread rules differ by surface.** Groups, private groups and DMs mark a note read when it is on screen; the Vishnu feed and the surrounding feed still mark on scroll-out (the older rule).
- **Gana**: dark theme and non-English dashboard layouts are not checked on a device; the form keeps only the first Manas when an old multi-Manas Gana is edited and saved; `gana_local_engine_e2e_test.dart` (part of `all_tests.dart`) publishes one permanent note to the relay on every run; a counter write racing an edit in another isolate can lose a count (same race the cursor has).
- **Device tests**: `scheduler_model_switch_test` failed once straight after another test and passed on re-run (cause not found); its second case needs two models; the cloud device tests still need an API key; the whole `all_tests.dart` has not been run in one go.
- **Note deletion (#291)**: un-saving a note whose original is already gone, and mesh sync removing saved rows, do not go through `purgeNotesInTxn`; their vectors are only removed by the next launch sweep.
- **Cloud**: no device test covers the UNIUN Cloud calls (#293); the free model was failing when this was written.
- **Release builds for Android, iOS and Windows now run in CI** (#268), but their first runs were on #277/#278 and nothing is uploaded, so store signing and a real install are still manual.

---

## How to keep this file useful

- Add an entry here for anything with real technical weight behind it: a root-caused bug, a dependency decision with a rejected alternative, a verification gap that's real and worth knowing about, a discovery that contradicts existing docs.
- Don't duplicate `CHANGELOG.md` — if there's nothing more to say than what the changelog already says, it doesn't need an entry here.
- Be honest about what wasn't verified, not just what was — a gap flagged here is more useful than a claim that turns out to be wrong later.
