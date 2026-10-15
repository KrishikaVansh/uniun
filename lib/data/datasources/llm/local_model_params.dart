import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';

/// Static map from our public [AIModelId] to the flutter_edge_ai engine params
/// the chat session needs.
///
/// `openChat` defaults `modelType` to [ModelType.gemmaIt]; if we don't override
/// it the SDK renders the wrong chat template (leading whitespace, missing
/// turn separators, sometimes degraded answers).
///
/// Duplicates the table in `AIModelRepositoryImpl` intentionally — that one
/// is for the download/install path, this one is for the runtime path. They
/// must stay in sync; if they drift, the engine + template will mismatch.
class LocalModelParams {
  const LocalModelParams({
    required this.modelType,
    required this.isThinking,
    required this.maxTokens,
  });

  final ModelType modelType;
  final bool isThinking;

  /// Hard KV-cache size the engine must be opened with. This is baked into the
  /// model file, not a free choice: e.g. the DeepSeek build is
  /// `deepseek_q8_ekv1280.task` — `ekv1280` = a 1280-token cache. Opening the
  /// engine with `maxTokens` larger than this aborts at `CalculatorGraph::Run`
  /// ("Max number of tokens is larger than the maximum cache size supported").
  final int maxTokens;

  static LocalModelParams? forId(AIModelId? id) {
    if (id == null) return null;
    switch (id) {
      case AIModelId.qwen25_05b:
        return const LocalModelParams(
          modelType: ModelType.qwen3,
          isThinking: false,
          maxTokens: 2048,
        );
      case AIModelId.deepseekR1:
        return const LocalModelParams(
          modelType: ModelType.deepSeek,
          isThinking: true,
          maxTokens: 1280,
        );
      case AIModelId.gemma4E2b:
        return const LocalModelParams(
          modelType: ModelType.gemma4,
          isThinking: false,
          maxTokens: 4096,
        );
      case AIModelId.gemma4E4b:
        return const LocalModelParams(
          modelType: ModelType.gemma4,
          isThinking: false,
          maxTokens: 8192,
        );
    }
  }
}
