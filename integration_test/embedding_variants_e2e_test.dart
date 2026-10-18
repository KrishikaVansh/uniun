// Real-device guard for the two bundled Gecko files (#266).
//
// The app embeds with the 256-token file and switches to the 1024-token file
// only for text that does not fit (EmbeddingService). That is safe only while
// both files give the same vector for the same text, so this checks it with
// the real files, then runs a question, a note too long for the short file
// and a note too long even for the long file through the real service, and
// prints the time of each. The measurements behind the design are in
// docs/SHIVA/embedding.md.
//
//   scripts/device_test.sh run integration_test/embedding_variants_e2e_test.dart

import 'dart:math';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart'
    show GemmaEmbeddingTokenizers;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';

const _note =
    'Espresso needs finely ground beans and about nine bars of pressure to '
    'extract properly.';
const _question = 'How do I get a good shot from my coffee machine?';

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (sqrt(na) * sqrt(nb));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the short and long Gecko files agree, and the app uses the short one',
    (tester) async {
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
        embeddingBackends: const [LiteRtEmbeddingBackend()],
        embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
      );
      if (!getIt.isRegistered<Isar>()) await configureDependencies();

      // The same text through each bundled file.
      final gateway = FlutterEdgeAiGatewayImpl();
      Future<List<double>> through(String asset, String text) async {
        await gateway.installEmbedder(
          modelAsset: asset,
          tokenizerAsset: EmbeddingService.tokenizerAsset,
        );
        final model = await gateway.getActiveEmbedder(
          preferredBackend: PreferredBackend.cpu,
        );
        return model.embed(
          EmbeddingInput.text(text),
          taskType: TaskType.retrievalDocument,
        );
      }

      final short = await through(EmbeddingService.shortModelAsset, _note);
      final long = await through(EmbeddingService.modelAsset, _note);
      final agree = _cosine(short, long);
      // ignore: avoid_print
      print('GECKO same note, 256 vs 1024 file: cosine '
          '${agree.toStringAsFixed(4)}');
      expect(short, hasLength(EmbeddingService.embeddingDim));
      expect(agree, greaterThan(0.999),
          reason: 'the two files no longer share one vector space');

      // The app's own path: questions and short notes on the short file,
      // anything longer on the long file, over-long text shortened.
      final service = getIt<EmbeddingService>();
      Future<(int, int)> timed(String text, {bool isDocument = false}) async {
        final sw = Stopwatch()..start();
        final v = await service.embed(text, isDocument: isDocument);
        return (v.length, sw.elapsedMilliseconds);
      }

      final notes = List.filled(60, _note).join(' ');
      final (q, qMs) = await timed(_question);
      final (q2, q2Ms) = await timed(_question);
      final (mid, midMs) = await timed(
        notes.substring(0, 1190), // under the character limit, over 256 tokens
        isDocument: true,
      );
      final (big, bigMs) = await timed(notes.substring(0, 3500), isDocument: true);
      final (huge, hugeMs) = await timed(notes, isDocument: true); // > 1024 tokens
      final (back, backMs) = await timed(_question);
      // ignore: avoid_print
      print('GECKO through the app: question $qMs ms, again $q2Ms ms | '
          '1,190-char note $midMs ms | 3,500-char note $bigMs ms | '
          '${notes.length}-char note $hugeMs ms | question after them $backMs ms');

      for (final n in [q, q2, mid, big, huge, back]) {
        expect(n, EmbeddingService.embeddingDim);
      }
      // A question on the short file is far faster than a note on the long
      // one (2.2 s against 11.7 s on a Snapdragon 710).
      expect(q2Ms, lessThan(bigMs ~/ 2));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
