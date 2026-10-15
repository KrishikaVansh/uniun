# PDF support in Shiv's RAG pipeline

## Problem

Shiv's RAG pipeline embeds and retrieves whole Notes — one Gecko vector per
note, cosine top-K over that. A PDF can already be *attached* to a note
today (Blossom upload, `imeta` tag, file-type-styled tile, opens via
`open_filex`), but its content is invisible to Shiv: the text inside it is
never extracted, never embedded, never retrievable, never cited. A note that
says "see the attached document" carries no more RAG signal than a note
with no attachment at all.

This spec adds PDF text extraction, chunking, and embedding, and wires the
result into retrieval and the existing Sources UI, so a PDF's *content*
becomes something Shiv can actually answer from and point back to.

## Scope

**v1 is PDF only.** DOCX has no strong pure-Dart reader — supporting it
would mean hand-parsing a zip of XML, real extra surface area for a format
that is out of scope for now. Revisit only if a real need for DOCX shows up.

**No OCR in v1.** A PDF with no text layer (a scan or a photograph) is not
sent through OCR. It stays attached and openable exactly as it is today,
but is recorded as not searchable and never embedded. Silently guessing at a
scanned document's content is worse than admitting it isn't searchable —
the same principle a comparable document-RAG system elsewhere applies: OCR
is a different problem, and pretending otherwise would put an empty
document in the index and call it read. On-device OCR (e.g.
`google_mlkit_text_recognition`) is a real option for later, deliberately
deferred, not ruled out.

**No in-app page-jump PDF viewer in v1.** A chunk citation names the page
it came from, but tapping it opens the PDF the same way any attachment
opens today — the OS's own viewer via `open_filex`, which has no way to be
told to jump to a page. The citation still shows the page number so a
reader knows where to look and can verify the claim; it just doesn't
auto-scroll there. See "Future work" below.

**Documents are retrieved in the unscoped ("All notes") chat only.** A
Manas-scoped chat builds its context from the picked Manas's note
membership and never runs vector search, and a PDF has no Manas membership
of its own. Attributing a document to a Manas would need a reverse lookup
from a blob's sha256 to the notes that attach it (an unindexed scan over
`NoteModel.attachments`). Deferred; see "Future work".

## Dependency and license

Text extraction uses **`pdfrx`** (MIT; bundles PDFium on Android/iOS/Linux/
macOS/Windows; `PdfPage.loadText()` is available headlessly, without
rendering a widget). `syncfusion_flutter_pdf` was considered and rejected:
it is proprietary — free only under a Community License limited to
organizations with under US$1M revenue and fewer than five developers, and
otherwise a paid commercial license. That is an unacceptable dependency for
software intended to be deployed inside other organizations.

`pdfrx` also ships `PdfViewer`, which is what the deferred in-app page-jump
viewer would use — one dependency covers both.

Extraction sits behind a thin seam (`PdfTextSource`: file path in, list of
per-page strings out) so the package is replaceable and every other unit is
testable without native PDFium.

## Architecture

```
Attach (existing, unchanged)
  PDF -> Blossom upload / download / draft staging
      -> MediaCacheModel row (sha256 -> local path, mime)
         (all three paths funnel through MediaRepositoryImpl._upsertCache)

New: PdfIndexer (main isolate, started at app launch)
  watches MediaCacheModel; reconciles two sets by sha256:
    PDF cache rows            vs   DocumentIndexModel rows
    - cache row, no index row  -> INDEX it
    - index row, no cache row  -> PURGE it (chunks + vectors + index row)
  Reconciling state, rather than reacting to a "blob arrived" event, means:
    * the user's own uploads and staged drafts are covered, not only
      downloads (they reach MediaCacheModel by different code paths);
    * a crash mid-index is retried on the next launch (the index row is
      written last);
    * removing a blob from the gallery cleans up without touching
      MediaRepositoryImpl.

  INDEX:
    PdfTextSource (pdfrx loadText, page by page)
         |
         v
    quality gate: >= 200 characters and >= 15% letters (Unicode-aware, so
    Devanagari counts) -- fails -> DocumentIndexModel(status: notSearchable)
         |
         v
    chunk: split each page on paragraph breaks, sentence-split anything
    still over 700 characters, hard-cut as a last resort. Every chunk keeps
    its page number as `label`.
         |
         v
    DocumentChunkModel rows (Isar: sha256, ordinal, label, text)
    + one vector per chunk in a SEPARATE ToStore instance
      (`<documents>/tostore_docs_1024d`, table `document_chunk_embeddings`,
      id = "<sha256>:<ordinal>")
         |
         v
    DocumentIndexModel(status: indexed)   <- written last

Query time (unscoped chat)
  embed query
    -> VectorSearchService.search        (notes, unchanged, full topK)
    -> VectorSearchService.searchChunks  (chunks, topK ~/ 2, min 1)
    -> notes drive the existing memory + 1-hop graph expansion, unchanged
    -> EnrichedContext carries seedNotes AND seedChunks
    -> PromptBuilder renders a "Relevant Documents" section
    -> RagMessage carries sourceNoteIds AND sourceChunkIds

  ShivSourcesSheet: one sheet, mixed list
    note citation  -> existing EmbeddedNoteCard, unchanged
    chunk citation -> new tile: title . "Page N" . snippet . tap -> open_filex
```

### Why chunk vectors get their own ToStore instance

Vectors live in ToStore, not Isar (`TostoreVectorRepositoryImpl`). Two
separate reasons to keep chunk vectors out of the existing store:

- **Recall.** If chunk vectors shared the `note_embeddings` table, every
  existing note search would have its top-K slots consumed by chunk hits,
  which the note content lookup then drops — silently lowering note recall
  for every current caller.
- **Migration risk.** Adding a table to the existing store is a schema
  migration on the user's whole note index, and nothing in the repo tests
  ToStore at all. A migration bug there would force re-embedding every note.
  A second store in its own directory cannot touch the first.

The cost is a second `ToStore` singleton (registered by name) and one extra
ANN query per chat turn. Results are merged in the service layer, not the
store; the note path is byte-for-byte unchanged.

### Why chunks are capped at 700 characters

`PromptBudget` gives the smallest local model 1024 tokens in total, and
`buildUserMessage` drops a whole section that would overshoot `maxTokens`.
A page-sized chunk (~1000 tokens) would therefore make the document vanish
from the prompt with no error. The per-section cap for that model is
`1024 * 0.35 / 2 = 179` tokens ≈ 716 characters at the app's
`estimateTokens` ratio of 4 characters per token, hence 700. This also keeps
a chunk well inside a single embedder input. The 15%-letters threshold is
borrowed from a comparable system that measured it on legal judgments; it
has not been measured on this app's documents and should be revisited with
real data.

## Components

- **`PdfTextSource`** (new, `lib/features/shiv/rag/extraction/`) — abstract
  seam: `Future<List<String>?> pagesText(String path)`, `null` when the
  file cannot be opened. `PdfrxTextSource` is the only implementation.
- **`TextQualityGate`** (new, same folder) — pure function over the joined
  page text.
- **`chunkPages`** (new, same folder) — pure function: `List<String>` pages
  in, `List<Chunk>` out. `Chunk` is `{text, ordinal, label}`; the page
  number must survive as a first-class field because a citation to
  "page 2" cannot be verified if it was discarded during chunking.
- **`PdfExtractionService`** (new, same folder) — composes the three above;
  returns `Extracted(chunks)` or `NotSearchable(reason)`. Never throws.
- **`DocumentIndexModel`** (new Isar `@Collection`) — `sha256` (unique),
  `status` (`indexed` | `notSearchable`), `pageCount`, `chunkCount`,
  `indexedAt`. Without it, "no chunks" cannot distinguish a scan from a
  document not yet processed, and every scan would be re-extracted on every
  launch.
- **`DocumentChunkModel`** (new Isar `@Collection`, RAG infrastructure
  parallel to `MemoryNodeModel` — not a Note, so the one-Note-collection
  rule is untouched) — `sha256`, `ordinal`, `label`, `text`; unique on
  `(sha256, ordinal)`. **No embedding field**: vectors are in ToStore.
- **`DocumentVectorRepository`** (new domain interface + ToStore
  implementation over the separate store) — upsert/delete/search over
  `document_chunk_embeddings`, and resolution of chunk ids to text from
  `DocumentChunkModel`.
- **`PdfIndexer`** (new `@lazySingleton`, main isolate — `EmbeddingService`
  and flutter_edge_ai are main-isolate only) — the reconciler above.
  Sequential; embedding failures (`embed` returns `[]` when the model is not
  ready) leave the document unindexed so the next reconcile retries it.
- **`VectorSearchService.searchChunks`**, **`EnrichedContext.seedChunks`**,
  **`PromptBuilder` "Relevant Documents" section**, **`RagMessage.
  sourceChunkIds`**, **`ShivAIState.lastTurnSourceChunkIds`** — additive
  plumbing; existing note fields and signatures are unchanged.
- **`ShivSourcesSheet`** — resolves chunk ids on open (mirroring how note
  ids are resolved on open today) and renders a `DocumentSourceTile` for
  each. The tile's title is the attaching note's `MediaAttachment.filename`,
  looked up by sha256, falling back to a generic "PDF" label when the note
  has since aged out of retention.

## Error handling

- No text layer, gate rejection, or a file PDFium cannot open: recorded as
  `notSearchable`; the document stays attached and opens exactly as today.
  Never surfaces as an error to the user — an expected outcome, not a
  failure.
- The embedder not being ready is *not* `notSearchable` — it leaves the
  document unindexed for a later retry.
- Indexing runs off the chat path, so a slow or failing extraction never
  blocks or delays a Shiv answer. Chunk retrieval failing degrades to the
  existing notes-only behaviour.
- The `notSearchable` status is stored but has no UI in v1.

## Testing

- `chunkPages`: page labels preserved across pages, cap respected on
  paragraphs/sentences/unbroken runs, Devanagari sentence terminator
  handled, whitespace-only pages skipped without shifting later page
  numbers.
- `TextQualityGate`: thresholds at, below and above; mojibake; Hindi text
  passes.
- `PdfExtractionService` against a fake `PdfTextSource`.
- `PdfrxTextSource` against a minimal generated PDF (real PDFium).
- Isar models: unique `(sha256, ordinal)` replace semantics.
- `DocumentVectorRepository` over a real ToStore in a temp directory.
- `PdfIndexer`: indexes a new PDF cache row; skips non-PDF rows; records
  `notSearchable` once and does not re-extract; retries after an embedder
  failure; purges chunks/vectors/index row when the cache row disappears;
  is idempotent under a re-run.
- `RagPipeline`/`PromptBuilder`: a chunk-only match produces context; the
  section is dropped rather than truncated mid-chunk when over budget;
  notes behaviour unchanged when no chunks match.
- `ShivSourcesSheet`: mixed list renders both tile kinds; chunk tile opens
  the cached file.

## Future work (explicitly out of scope for this spec)

- **In-app PDF viewer that jumps to the cited page** — `PdfViewer` from
  `pdfrx` (already a dependency). The page label is already user-visible in
  v1, so the value is already there; this removes the one remaining manual
  step.
- **Documents in Manas-scoped chat** — needs a sha256 → attaching-notes
  index (or a denormalised `noteId` on `DocumentIndexModel`).
- **On-device OCR for scanned PDFs** (e.g. `google_mlkit_text_recognition`)
  — would need its own quality gate, since OCR misreads look different from
  the mojibake the letters-ratio gate is calibrated against.
- **UI for `notSearchable`** — a badge on the attachment tile.
- **DOCX support** — deferred until there's a real need for it.
