import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/domain/entities/llm/llm_model_info.dart';

/// Per-model token budget for per-turn user-message assembly.
///
/// Total budget is split across priority buckets. If the assembled sections
/// overshoot, lower-priority sections are dropped first. Priority order
/// (highest → lowest):
///   1. user query (always kept)
///   2. top 1-2 seed notes
///   3. strong graph relations
///   4. remaining seed notes
///   5. memory summaries
class PromptBudget {
  const PromptBudget({
    required this.maxTokens,
    required this.queryTokens,
    required this.topNotesTokens,
    required this.graphRelationsTokens,
    required this.memoriesTokens,
    required this.topK,
    required this.maxHops,
    this.minScore = defaultMinScore,
  });

  /// How similar a note must be to the question (0..1, from the embedder) to
  /// be put in the prompt. Most unrelated notes score 0.6-0.7 against any
  /// question, so this only keeps out the clearly unrelated ones.
  static const double defaultMinScore = 0.3;

  /// The 0.6B model copies whatever note it is given, so for it a note must be
  /// really about the question. Measured with the real Gecko on a phone (20
  /// questions, 8 notes): notes that answer the question scored 0.74-0.85,
  /// the closest note to an unrelated question never above 0.70.
  static const double smallModelMinScore = 0.72;

  final int maxTokens;
  final int queryTokens;
  final int topNotesTokens;
  final int graphRelationsTokens;
  final int memoriesTokens;

  /// How many vector seed notes to retrieve. Larger models can handle more context.
  final int topK;

  /// Notes below this similarity are not retrieved. See [defaultMinScore].
  final double minScore;

  /// Graph traversal depth. 1-hop for small models (speed + context limit),
  /// 2-hop for larger models (richer multi-hop reasoning).
  final int maxHops;

  /// Pick a budget that fits the active model's real capacity.
  /// Cloud-backed [LlmModelInfo] → generous defaults (cloud context windows
  /// dwarf any local model). Local → per-id table.
  factory PromptBudget.forActiveModel(LlmModelInfo? model) {
    if (model == null) return _local(null);
    if (model.backend == LlmBackendType.uniunCloud) return _cloud(model);
    return _local(_localIdFromName(model.id));
  }

  /// Local-model budget. Used directly when callers already have an
  /// [AIModelId] (e.g. the existing `RagPipeline` path before backend
  /// awareness was added).
  factory PromptBudget.forModel(AIModelId? modelId) => _local(modelId);

  static AIModelId? _localIdFromName(String name) {
    for (final v in AIModelId.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static PromptBudget _local(AIModelId? modelId) {
    final int max;
    final int topK;
    final int maxHops;
    var minScore = defaultMinScore;
    switch (modelId) {
      case AIModelId.gemma4E4b:
        max = 8192;
        topK = 10;
        maxHops = 2;
        break;
      case AIModelId.gemma4E2b:
        max = 4096;
        topK = 5;
        maxHops = 2;
        break;
      case AIModelId.deepseekR1:
        max = 1024;
        topK = 3;
        maxHops = 1;
        break;
      case AIModelId.qwen25_05b:
      case null:
        max = 2048;
        topK = 3;
        maxHops = 1;
        minScore = smallModelMinScore;
    }
    return _build(max, topK, maxHops, minScore: minScore);
  }

  /// Cloud models routinely expose 32k–200k context windows. We don't try
  /// to fill them — too much context = noisy answers + higher token cost.
  /// 16k is a sweet spot: deep enough for multi-hop graph context, small
  /// enough that the price-per-turn stays reasonable.
  ///
  /// If [model.contextWindow] is reported (currently 0 from openrouter_api
  /// 1.0.2), we cap our budget at half of it so we leave room for the
  /// response.
  static PromptBudget _cloud(LlmModelInfo model) {
    final reported = model.contextWindow;
    final cap = reported > 0 ? (reported ~/ 2).clamp(4096, 32768) : 16384;
    return _build(cap, 15, 2);
  }

  static PromptBudget _build(
    int max,
    int topK,
    int maxHops, {
    double minScore = defaultMinScore,
  }) {
    // Split: query 10%, topNotes 35%, graphRelations 20%, summaries 15%.
    return PromptBudget(
      maxTokens: max,
      queryTokens: (max * 0.10).round(),
      topNotesTokens: (max * 0.35).round(),
      graphRelationsTokens: (max * 0.20).round(),
      memoriesTokens: (max * 0.15).round(),
      topK: topK,
      maxHops: maxHops,
      minScore: minScore,
    );
  }

  /// Rough estimate: English text averages ~4 characters per token for
  /// subword BPE/SentencePiece tokenisers. Good enough for local budgeting —
  /// we don't need token-perfect accuracy, just ranked trimming.
  static int estimateTokens(String text) => (text.length / 4).ceil();
}
