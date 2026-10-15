import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/data/datasources/llm/local_model_params.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';

void main() {
  group('LocalModelParams.forId', () {
    test('null id returns null', () {
      expect(LocalModelParams.forId(null), isNull);
    });

    test('qwen25_05b maps to qwen3, non-thinking, 2048 tokens', () {
      final p = LocalModelParams.forId(AIModelId.qwen25_05b)!;
      expect(p.modelType, ModelType.qwen3);
      expect(p.isThinking, isFalse);
      expect(p.maxTokens, 2048);
    });

    test('deepseekR1 maps to deepSeek, thinking, 1280 tokens', () {
      final p = LocalModelParams.forId(AIModelId.deepseekR1)!;
      expect(p.modelType, ModelType.deepSeek);
      expect(p.isThinking, isTrue);
      expect(p.maxTokens, 1280);
    });

    test('gemma4E2b maps to gemma4, non-thinking, 4096 tokens', () {
      final p = LocalModelParams.forId(AIModelId.gemma4E2b)!;
      expect(p.modelType, ModelType.gemma4);
      expect(p.isThinking, isFalse);
      expect(p.maxTokens, 4096);
    });

    test('gemma4E4b maps to gemma4, non-thinking, 8192 tokens', () {
      final p = LocalModelParams.forId(AIModelId.gemma4E4b)!;
      expect(p.modelType, ModelType.gemma4);
      expect(p.isThinking, isFalse);
      expect(p.maxTokens, 8192);
    });

    test('every AIModelId resolves to a non-null entry (catalog completeness)',
        () {
      for (final id in AIModelId.values) {
        expect(LocalModelParams.forId(id), isNotNull, reason: id.name);
      }
    });
  });
}
