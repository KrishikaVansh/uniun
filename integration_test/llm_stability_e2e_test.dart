// Real-device stability checks for the on-device LLM stack, run on every model
// fixture pushed to the phone (Qwen3 0.6B and Gemma 4 E2B).
//
// These guard the regressions a package bump is most likely to bring back:
//   1. Stop mid-reply, then ask again: the next reply must not be empty
//      (flutter_edge_ai_litertlm (then flutter_edge_ai_litertlm 1.8.1) bug).
//   2. Opening and closing chats repeatedly must not grow process memory
//      without bound (native leak class fixed in 1.4.0 / core 2.1.3).
//   3. Switching Qwen -> Gemma -> Qwen must answer every time and give the
//      memory back.
//   4. A note far longer than the embedder window must still embed through
//      the real Gecko (2.3 throws instead of truncating).
//
// Memory is read from the OS with flutter_edge_ai_diagnostics. A model that
// has no fixture on the phone is a loud failure, not a skip: push it with
// `scripts/device_test.sh push-model <file>`.
//
//   scripts/device_test.sh run integration_test/llm_stability_e2e_test.dart

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';

import 'support/test_model.dart';

const _mib = 1024 * 1024;

Future<String> _ask(InferenceModel model, String prompt) async {
  final chat = await model.openChat(temperature: 0.2, topK: 20);
  try {
    await chat.addQueryChunk(Message.text(text: prompt));
    final buf = StringBuffer();
    await for (final r in chat.generateChatResponseAsync()) {
      if (r is TextResponse) buf.write(r.token);
    }
    return buf.toString();
  } finally {
    await chat.close();
  }
}

Future<int> _anonymousMib() async {
  final s = await FlutterEdgeAiDiagnostics.memorySnapshot();
  expect(
    s.anonymousBytes,
    isNotNull,
    reason: 'the OS did not report anonymous memory',
  );
  return s.anonymousBytes! ~/ _mib;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const models = [AIModelId.qwen25_05b, AIModelId.gemma4E2b];

  for (final id in models) {
    group(id.name, () {
      testWidgets(
        'stopping mid-reply leaves the chat usable',
        (t) async {
          expect(
            await provisionTestModel(id),
            isTrue,
            reason: 'no ${id.name} fixture on the phone',
          );
          final model = await FlutterEdgeAi.getActiveModel(maxTokens: 512);
          try {
            final chat = await model.openChat(temperature: 0.8, topK: 40);
            await chat.addQueryChunk(
              Message.text(text: 'Write a long story about a lighthouse.'),
            );
            var tokens = 0;
            await for (final r in chat.generateChatResponseAsync()) {
              if (r is TextResponse && ++tokens >= 5) {
                await chat.stopGeneration();
                break;
              }
            }
            expect(tokens, greaterThanOrEqualTo(5));

            await chat.addQueryChunk(
              Message.text(text: 'Reply with the single word: OK'),
            );
            final buf = StringBuffer();
            await for (final r in chat.generateChatResponseAsync()) {
              if (r is TextResponse) buf.write(r.token);
            }
            await chat.close();
            expect(
              buf.toString().trim(),
              isNotEmpty,
              reason: 'the reply after a stop came back empty',
            );
          } finally {
            await model.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );

      testWidgets(
        'repeated chats do not leak native memory',
        (t) async {
          expect(await provisionTestModel(id), isTrue);
          final model = await FlutterEdgeAi.getActiveModel(maxTokens: 256);
          try {
            await _ask(model, 'Say hello.'); // warm-up: engine + KV cache
            final before = await _anonymousMib();
            for (var i = 0; i < 6; i++) {
              final reply = await _ask(model, 'Name one colour. Turn $i.');
              expect(reply.trim(), isNotEmpty, reason: 'turn $i was empty');
            }
            final grew = await _anonymousMib() - before;
            // ignore: avoid_print
            print(
              '${id.name}: anonymous memory grew by $grew MiB over 6 chats',
            );
            expect(
              grew,
              lessThan(150),
              reason: 'six chats grew process memory by $grew MiB',
            );
          } finally {
            await model.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );
    });
  }

  testWidgets(
    'switching models answers every time and frees memory',
    (t) async {
      final results = <String>[];
      int? baseline;
      for (final id in [
        AIModelId.qwen25_05b,
        AIModelId.gemma4E2b,
        AIModelId.qwen25_05b,
      ]) {
        expect(await provisionTestModel(id), isTrue);
        final model = await FlutterEdgeAi.getActiveModel(maxTokens: 256);
        try {
          final reply = await _ask(model, 'Reply with the single word: OK');
          expect(
            reply.trim(),
            isNotEmpty,
            reason: '${id.name} answered nothing after a switch',
          );
          results.add('${id.name}: ${reply.trim().length} chars');
        } finally {
          await model.close();
        }
        baseline ??= await _anonymousMib();
      }
      final after = await _anonymousMib();
      // ignore: avoid_print
      print('switch results: $results; $baseline MiB -> $after MiB');
      expect(
        after - baseline!,
        lessThan(600),
        reason: 'memory after switching back grew by ${after - baseline} MiB',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );

  testWidgets(
    'a note far longer than the embedder window still embeds',
    (t) async {
      expect(await provisionTestModel(AIModelId.gemma4E2b), isTrue);
      await configureDependencies();
      final embedding = getIt<EmbeddingService>();

      final probe = await embedding.embed('probe', isDocument: true);
      expect(probe, isNotEmpty, reason: 'the bundled Gecko did not load');

      final long =
          'The harbour lighthouse keeper logged every ship at dawn. ' * 800;
      final vec = await embedding.embed(long, isDocument: true);

      expect(vec, hasLength(probe.length));
      expect(vec.any((v) => v != 0), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
