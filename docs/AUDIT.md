# Engineering Audit Log

This is the **technical** companion to `CHANGELOG.md`. `CHANGELOG.md` stays terse and user-facing, following Keep a Changelog conventions — this file is where the actual engineering detail behind each release lives: what was found, what was verified against the real code (not guessed), what broke and why, and what's still open. Each entry maps to one or more `CHANGELOG.md` versions but goes deep where the changelog stays shallow.

Format: one dated section per audit pass, newest first. Each item states what was done, how it was verified, and — where relevant — what's still outstanding.

---

## Open items carried into v3.1.0

The detailed entries up to v3.1.0 were cleared when it shipped; they remain in git history
(`git log -p -- docs/AUDIT.md`). These are the things from them, and from the v3.0.0 list
before them, that were not resolved:

**Still open from v3.0.0**
- **Android GPU crash on one device class.** On a vivo 1933 / Android 11 / Adreno phone, creating the GPU engine intermittently kills the process inside the vendor GPU driver (`SIGSEGV` in `libgsl.so`). Shipped deliberately with GPU preferred; no fix upstream yet.
- **The graph's drag and simulation feel is untested on a device** after the Obsidian rewrite. Its performance test is `integration_test/graph_simulation_perf_test.dart`. (Tapping a node and adding it to a Manas was exercised on a vivo 1933 in 3.1, #261.)
- **Hindi/Hinglish retrieval on real scans is still weak** (the English-centred embedder and noisy Devanagari OCR); the keyword-side fix is in, the rest needs a better embedder or OCR.
- **`InferenceScheduler`'s T2 soft budget can stall an extract-only queue** (latent, predates 3.0). `maxOutputTokens` is unused, so a runaway one-shot generation runs until the KV cache fills.
- The OCR and chart-reading thresholds in `page_ocr_plan.dart` (50 %, 25 %, 20 characters, the Word picture sizes) are unmeasured on real documents.

**New in 3.1**
- **iOS is unverified for everything in this release** (it cannot be built from the Linux dev machine): Gujarati and Japanese layouts, the chat open-at-first-unread list, the unread trail, Gana dashboard and Brahma/No-knowledge scopes, image input in chat, logout reset, and the background Gana tick. The CI iOS build only proves it compiles.
- **Gujarati is machine-assisted**; a native review of phrasing is still wanted (#271). Japanese was not natively reviewed either.
- **Embedding is slow on weak phones** (about 11.5 s a note on a vivo 1933, on the CPU, whatever the length). A shorter-input Gecko is faster but needs note chunking and a long-note retrieval comparison first (#266).
- **Notes saved before the embedding queue (3.1) were never backfilled**: they have no vector until they are saved again. Re-embedding every saved note would cost about 11.5 s each.
- **Image input in chat**: the photo is not shown in the sent bubble or kept in the conversation, one image per message, Gemma 4 E4B and prefill time/memory with a large photo were not measured, and the engine rebuild on the first image turn is untimed.
- **Unread rules differ by surface.** Groups, private groups and DMs mark a note read when it is on screen; the Vishnu feed and the surrounding feed still mark on scroll-out (the older rule).
- **Gana**: dark theme and non-English dashboard layouts are not checked on a device; the form keeps only the first Manas when an old multi-Manas Gana is edited and saved; `gana_local_engine_e2e_test.dart` (part of `all_tests.dart`) publishes one permanent note to the relay on every run; a counter write racing an edit in another isolate can lose a count (same race the cursor has).
- **Device tests**: `scheduler_model_switch_test` failed once straight after another test and passed on re-run (cause not found); its second case needs two models; the cloud device tests still need an API key; the whole `all_tests.dart` has not been run in one go.
- **Release builds for Android, iOS and Windows now run in CI** (#268), but their first runs were on #277/#278 and nothing is uploaded, so store signing and a real install are still manual.

---

## How to keep this file useful

- Add an entry here for anything with real technical weight behind it: a root-caused bug, a dependency decision with a rejected alternative, a verification gap that's real and worth knowing about, a discovery that contradicts existing docs.
- Don't duplicate `CHANGELOG.md` — if there's nothing more to say than what the changelog already says, it doesn't need an entry here.
- Be honest about what wasn't verified, not just what was — a gap flagged here is more useful than a claim that turns out to be wrong later.
