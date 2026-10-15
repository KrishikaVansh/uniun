import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:injectable/injectable.dart';
import 'package:uniun/core/utils/llm_backend.dart';
import 'package:uniun/data/datasources/llm/embedding_queue.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';

/// On-device text embedding using Gecko 110M (768-dim), run through
/// flutter_edge_ai's LiteRT embedder.
///
/// ## Why flutter_edge_ai instead of tflite_flutter
/// flutter_edge_ai (MediaPipe) statically embeds its own copy of TensorFlow Lite.
/// `tflite_flutter` linked a *second* copy, so on the iOS arm64 device build
/// both ended up in one binary → duplicate `TFLBufferConvert` Objective-C class
/// → corrupted symbol table → `EXC_BAD_ACCESS` / Isar `isar_version` failures.
/// Running embeddings through flutter_edge_ai's own LiteRT runtime keeps a single
/// TensorFlow Lite in the binary and removes the conflict entirely.
///
/// ## Bundled, not downloaded
/// The model + tokenizer ship as app assets (see [modelAsset]/[tokenizerAsset]),
/// so RAG works offline on first launch with no network fetch. `installEmbedder`
/// copies the asset into flutter_edge_ai's managed storage once (idempotent).
///
/// Output: 768-dimensional L2-normalised float vector.
@lazySingleton
class EmbeddingService {
  EmbeddingService(this._gateway, this._queue);

  final FlutterEdgeAiGateway _gateway;
  final EmbeddingQueue _queue;

  static const int embeddingDim = 768;

  /// Bundled asset paths — also referenced by [EmbeddingModelDownloader] so the
  /// install can be pre-warmed during the LLM download UX.
  static const String modelAsset = 'assets/models/embedding/gecko_1024_quant.tflite';
  static const String tokenizerAsset = 'assets/models/embedding/sentencepiece.model';

  EmbeddingModel? _model;

  bool get isReady => _model != null;

  // ── Init ───────────────────────────────────────────────────────────────────

  /// Installs the bundled embedder (idempotent) and opens it. Safe to call
  /// multiple times — no-op after a successful load. Degrades to no-context
  /// mode (returns no vectors) if the model fails to open.
  Future<void> init() async {
    if (isReady) return;
    try {
      await ensureInstalled();
      // Prefer GPU, fall back to CPU on load failure so RAG still works
      // everywhere.
      final backend = preferredLlmBackend;
      try {
        _model = await _gateway.getActiveEmbedder(preferredBackend: backend);
      } on Object catch (e) {
        if (backend == PreferredBackend.cpu) rethrow;
        debugPrint('🧠 Embedding: GPU load failed ($e) — retrying on CPU');
        _model = await _gateway.getActiveEmbedder(
          preferredBackend: PreferredBackend.cpu,
        );
      }
    } catch (e) {
      debugPrint('🧠 Embedding: model load failed — $e');
      _model = null;
    }
  }

  /// Registers the bundled Gecko model + tokenizer as flutter_edge_ai's active
  /// embedder. Idempotent — returns fast once installed.
  Future<void> ensureInstalled() async {
    if (_gateway.hasActiveEmbedder()) return;
    await _gateway.installEmbedder(
      modelAsset: modelAsset,
      tokenizerAsset: tokenizerAsset,
    );
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Embed [text] → 768-dim L2-normalised vector.
  ///
  /// [isDocument] selects the task prefix: documents being indexed (note
  /// content) use the document prefix, search queries use the query prefix.
  /// Getting this right is what makes asymmetric retrieval accurate.
  ///
  /// Returns [] if the model is not loaded (no crash, just no RAG context).
  ///
  /// Every call goes through [EmbeddingQueue]: a query is interactive (someone
  /// is waiting) and a document is background, so a Shiv question is never
  /// stuck behind a backlog of notes and PDF chunks.
  Future<List<double>> embed(String text, {bool isDocument = false}) {
    return _queue.run(
      () => _embed(text, isDocument: isDocument),
      priority:
          isDocument ? EmbedPriority.background : EmbedPriority.interactive,
    );
  }

  /// flutter_edge_ai 2.3 refuses an input longer than the model's window
  /// ([EmbeddingInputTooLongException]) instead of truncating it as 1.x did.
  /// A note can be arbitrarily long, so shrink it by the reported ratio and
  /// retry, a few times at most: the head of a note carries what it is about.
  static const int _maxFitAttempts = 4;

  Future<List<double>> _embed(String text, {required bool isDocument}) async {
    if (!isReady) await init();
    if (!isReady) return [];
    final taskType =
        isDocument ? TaskType.retrievalDocument : TaskType.retrievalQuery;
    var input = text;
    for (var attempt = 0; attempt < _maxFitAttempts; attempt++) {
      try {
        final vec = await _model!.embed(
          EmbeddingInput.text(input),
          taskType: taskType,
        );
        return _l2Normalize(vec);
      } on EmbeddingInputTooLongException catch (e) {
        final ratio = e.actualTokens != null && e.actualTokens! > 0
            ? e.maxInputTokens / e.actualTokens!
            : 0.5;
        final next = (input.length * ratio * 0.9).floor();
        if (next <= 0 || next >= input.length) break;
        debugPrint(
          '🧠 Embedding: input too long '
          '(${e.actualTokens ?? '?'}/${e.maxInputTokens} tokens) — '
          'shortening ${input.length} → $next chars',
        );
        input = input.substring(0, next);
      } catch (e) {
        debugPrint('🧠 Embedding: generate failed — $e');
        return [];
      }
    }
    debugPrint('🧠 Embedding: could not fit input into the model window');
    return [];
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
  }

  // ── L2 normalisation ──────────────────────────────────────────────────────

  /// Gecko already returns unit-norm vectors; normalising again is a no-op
  /// there but keeps cosine search correct regardless of the model.
  List<double> _l2Normalize(List<double> vec) {
    final norm = sqrt(vec.fold(0.0, (acc, v) => acc + v * v));
    if (norm == 0) return vec;
    return vec.map((v) => v / norm).toList();
  }
}
