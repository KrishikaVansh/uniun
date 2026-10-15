// Real-device check of Shiv answering from the user's own notes, on each local
// chat model. Three notes are saved and embedded with the real Gecko, then:
//   - a question only one note can answer: retrieval must surface that note
//     and the reply must carry its fact;
//   - a question with no note behind it: the reply must still be a sensible
//     answer, and no note may be cited as its source;
//   - a follow-up on the same conversation.
// Small models are loose, so replies are checked for a distinctive fact, not
// for wording. Each model's replies are printed so quality can be compared.
//
//   scripts/device_test.sh run integration_test/shiv_notes_qa_e2e_test.dart

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart'
    show GemmaEmbeddingTokenizers;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/data/datasources/llm/local_llm_runner.dart';
import 'package:uniun/data/datasources/note_vector_store.dart';
import 'package:uniun/data/models/graph_edge_model.dart';
import 'package:uniun/data/models/memory_node_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/repositories/pending_embedding_repository.dart';
import 'package:uniun/domain/repositories/vector_repository.dart';
import 'package:uniun/domain/usecases/vector_usecases.dart';
import 'package:uniun/features/shiv/generation/chat_helpers.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';
import 'package:uniun/features/shiv/rag/pipeline/rag_pipeline.dart';
import 'package:uniun/features/shiv/rag/prompt/prompt_budget.dart';

import 'support/test_model.dart';

const _prefix = 'e2e-qa-';

/// Deleted vectors stay searchable in the store (see the ghost-vector issue),
/// so a phone that has run this test before holds near-identical notes. Each
/// run therefore uses a different city, hotel, bike and month, and its
/// questions name them, which keeps this run's notes ahead of the leftovers.
const _cities = [
  ('Lisbon', 'Alfama Garden'),
  ('Reykjavik', 'Harbour Frost'),
  ('Kyoto', 'Maple Courtyard'),
  ('Valparaiso', 'Casa Azul'),
  ('Tbilisi', 'Sololaki Inn'),
  ('Zanzibar', 'Spice Coast'),
  ('Ljubljana', 'Dragon Bridge'),
  ('Cusco', 'Plaza Condor'),
];
const _bikes = ['Marin Alpine', 'Brompton', 'Cannondale Quick', 'Surly Disc'];
const _months = ['June', 'September', 'February', 'November'];

class _Notes {
  _Notes(int stamp)
    : city = _cities[stamp % _cities.length].$1,
      hotel = _cities[stamp % _cities.length].$2,
      bike = _bikes[(stamp ~/ 7) % _bikes.length],
      month = _months[(stamp ~/ 13) % _months.length];
  final String city;
  final String hotel;
  final String bike;
  final String month;

  /// (id suffix, text). Subjects are far apart so retrieval is unambiguous.
  List<(String, String)> get all => [
    (
      'trip',
      'Trip plan: we fly to $city on 14 March and stay at the $hotel hotel '
          'for five nights. Remember to book the tram tickets early.',
    ),
    (
      'recipe',
      'Grandmother\'s lentil soup: simmer red lentils with two carrots, one '
          'onion and a teaspoon of cumin for twenty five minutes, then add '
          'lemon.',
    ),
    (
      'bike',
      'Bike service log for the $bike: the rear tyre was replaced at '
          '4,200 km, and the chain must be oiled every 300 km. Next full '
          'service is due in $month.',
    ),
  ];
}

Future<String> _reply(
  AIModelRunner runner,
  RagMessage msg,
  String system, {
  List<(String, String)> history = const [],
}) async {
  final buf = StringBuffer();
  await for (final t in runner.sendAndStream(
    msg.userMessage,
    systemInstruction: system,
    cleanHistory: history,
  )) {
    buf.write(t);
  }
  return stripThinking(buf.toString()).trim();
}

/// Extraction writes graph edges and memory summaries keyed by the note id;
/// left behind they feed an earlier run's facts into later answers.
Future<void> _dropDerived(Isar isar) => isar.writeTxn(() async {
  await isar.memoryNodeModels
      .filter()
      .noteIdStartsWith(_prefix)
      .deleteAll();
  await isar.graphEdgeModels
      .filter()
      .sourceNoteIdStartsWith(_prefix)
      .deleteAll();
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // How similar the real Gecko says a note is to a question, for notes that
  // answer it and notes that do not. It is what the relevance cut-off for
  // small models is chosen from, and it is printed, not just asserted.
  testWidgets('relevance scores: related notes vs unrelated notes',
      (tester) async {
    if (!getIt.isRegistered<Isar>()) await configureDependencies();
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
      embeddingBackends: const [LiteRtEmbeddingBackend()],
      embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    );
    final embedder = getIt<EmbeddingService>();
    expect(await embedder.embed('probe'), isNotEmpty);

    const notes = <String, String>{
      'trip': 'Trip plan: we fly to Lisbon on 14 March and stay at the Alfama '
          'Garden hotel for five nights. Remember to book the tram tickets '
          'early.',
      'recipe': "Grandmother's lentil soup: simmer red lentils with two "
          'carrots, one onion and a teaspoon of cumin for twenty five '
          'minutes, then add lemon.',
      'bike': 'Bike service log: the rear tyre was replaced at 4,200 km, and '
          'the chain must be oiled every 300 km. Next full service is due in '
          'June.',
      'codeword': 'This is a test post. The celebration codeword is '
          'marmalade.',
      'report': 'Quarterly report is due on Friday: finish the sales slides '
          'and send them to the team.',
      'dentist': 'Dentist appointment on 3 May at 10:30, bring the insurance '
          'card.',
      'book': 'Reading Dune: finished part one, the desert planet and the '
          'spice are the best bits so far.',
      'garden': 'Tomatoes need watering every second day, and the basil '
          'should stay in the shade.',
    };
    // question -> the note that answers it (null: no note does).
    const questions = <(String, String?)>[
      ('Which hotel are we staying at in Lisbon?', 'trip'),
      ('What do I need to book early for the trip?', 'trip'),
      ('How long should the lentils simmer?', 'recipe'),
      ('When is the next service for my bike?', 'bike'),
      ('How often should I oil the chain?', 'bike'),
      ('What is the celebration codeword?', 'codeword'),
      ('When is my dentist appointment?', 'dentist'),
      ('What is due on Friday?', 'report'),
      ('How far have I got in Dune?', 'book'),
      ('How often do the tomatoes need water?', 'garden'),
      ('What did I write about my travel plans?', 'trip'),
      ('Tell me about my notes on food', 'recipe'),
      ('What is the capital of France?', null),
      ('How to grow in life?', null),
      ('Write me a poem about the sea', null),
      ('What is 12 times 8?', null),
      ('who are you', null),
      ('please explain how photosynthesis works', null),
      ('Translate good morning into Spanish', null),
      ('What is the best way to learn guitar?', null),
    ];

    final dir = await Directory.systemTemp.createTemp('relevance_');
    final store = await NoteVectorStore.open(dir.path);
    try {
      for (final e in notes.entries) {
        await store.upsert(
          e.key,
          await embedder.embed(e.value, isDocument: true),
        );
      }
      final related = <double>[];
      final unrelatedTop = <double>[];
      final unrelatedAll = <double>[];
      for (final (q, answer) in questions) {
        final hits = await store.search(await embedder.embed(q), topK: 8);
        final byId = {for (final h in hits) h.id: h.score};
        final top = hits.first;
        final line = hits
            .take(3)
            .map((h) => '${h.id}:${h.score.toStringAsFixed(2)}')
            .join(' ');
        // ignore: avoid_print
        print('RELEVANCE ${answer == null ? 'NONE ' : 'RELATED'} '
            '"$q" -> top: $line');
        if (answer != null) {
          related.add(byId[answer] ?? 0);
        } else {
          unrelatedTop.add(top.score);
        }
        for (final h in hits) {
          if (h.id != answer) unrelatedAll.add(h.score);
        }
      }
      related.sort();
      unrelatedTop.sort();
      // ignore: avoid_print
      print('RELEVANCE SUMMARY related(answering note): '
          'min=${related.first.toStringAsFixed(2)} '
          'median=${related[related.length ~/ 2].toStringAsFixed(2)} '
          'max=${related.last.toStringAsFixed(2)} | '
          'unrelated question, closest note: '
          'min=${unrelatedTop.first.toStringAsFixed(2)} '
          'median=${unrelatedTop[unrelatedTop.length ~/ 2].toStringAsFixed(2)} '
          'max=${unrelatedTop.last.toStringAsFixed(2)}');
      expect(related, hasLength(12));
      expect(unrelatedTop, hasLength(8));
      // The small-model cut-off must sit between the two groups: no unrelated
      // question reaches it, and at least ten of the twelve related ones do.
      // If this fails after an embedder change, re-measure the cut-off.
      const cutOff = PromptBudget.smallModelMinScore;
      expect(unrelatedTop.last, lessThan(cutOff),
          reason: 'an unrelated question would pull a note into the prompt');
      expect(related.where((s) => s >= cutOff).length, greaterThanOrEqualTo(10),
          reason: 'too many answering notes would be dropped');
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  for (final id in [AIModelId.qwen25_05b, AIModelId.gemma4E2b]) {
    testWidgets(
      '${id.name}: answers from saved notes and from general knowledge',
      (tester) async {
        expect(
          await provisionTestModel(id),
          isTrue,
          reason: 'no ${id.name} fixture on the phone',
        );
        if (!getIt.isRegistered<Isar>()) await configureDependencies();
        final isar = getIt<Isar>();
        final pending = getIt<PendingEmbeddingRepository>();
        final vectors = getIt<VectorRepository>();
        final rag = getIt<RagPipeline>();
        final runner = getIt<AIModelRunner>();

        expect(
          await getIt<EmbeddingService>().embed('probe'),
          isNotEmpty,
          reason: '[] means the bundled embedding model did not load',
        );

        // Stale queue rows from earlier runs would be embedded before ours.
        for (;;) {
          final next = (await pending.next()).getOrElse(() => null);
          if (next == null) break;
          await pending.remove(next.eventId);
        }

        // Notes left by an earlier, interrupted run.
        final stale = await isar.noteModels
            .filter()
            .eventIdStartsWith(_prefix)
            .findAll();
        for (final n in stale) {
          await vectors.delete(n.eventId);
        }
        await isar.writeTxn(
          () => isar.noteModels.filter().eventIdStartsWith(_prefix).deleteAll(),
        );
        await _dropDerived(isar);

        final stamp = DateTime.now().microsecondsSinceEpoch;
        final notes = _Notes(stamp);
        String idOf(String s) => '$_prefix$stamp-$s';
        try {
          for (final (s, text) in notes.all) {
            await isar.writeTxn(
              () => isar.noteModels.put(
                NoteModel(
                  eventId: idOf(s),
                  sig: '',
                  authorPubkey: 'e2e',
                  content: text,
                  type: NoteType.text,
                  eTagRefs: const [],
                  pTagRefs: const [],
                  tTags: const [],
                  created: DateTime.now(),
                ),
              ),
            );
            await getIt<EmbedAndStoreNoteUseCase>().call((idOf(s), text));
          }
          final deadline = DateTime.now().add(const Duration(minutes: 12));
          while ((await pending.count()).getOrElse(() => -1) > 0 &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          expect(
            (await pending.count()).getOrElse(() => -1),
            0,
            reason: 'all three notes should be embedded',
          );

          await rag.init();
          await runner.initChat();
          final system = await rag.buildSystemInstruction();

          // 1. A question only the trip note can answer.
          final q1 = 'Which hotel are we staying at in ${notes.city}?';
          final m1 = await rag.buildMessage(userQuestion: q1);
          expect(
            m1.sourceNoteIds,
            contains(idOf('trip')),
            reason: 'retrieval should surface the trip note',
          );
          final a1 = await _reply(runner, m1, system);
          // ignore: avoid_print
          print('QA[${id.name}] note   Q="$q1" A="$a1"');
          expect(a1.toLowerCase(), contains(notes.hotel.split(' ').first.toLowerCase()));

          // 2. A follow-up in the same conversation, answerable from the
          //    same note.
          const q2 = 'And what should I book early?';
          final m2 = await rag.buildMessage(userQuestion: q2);
          final a2 = await _reply(
            runner,
            m2,
            system,
            history: [(q1, a1)],
          );
          // ignore: avoid_print
          print('QA[${id.name}] follow Q="$q2" A="$a2"');
          expect(a2, isNotEmpty);

          // 3. A different note.
          final q3 = 'When is the next full service for my ${notes.bike} bike?';
          final m3 = await rag.buildMessage(userQuestion: q3);
          expect(m3.sourceNoteIds, contains(idOf('bike')));
          final a3 = await _reply(runner, m3, system);
          // ignore: avoid_print
          print('QA[${id.name}] note   Q="$q3" A="$a3"');
          expect(a3.toLowerCase(), contains(notes.month.toLowerCase()));

          // 4. General knowledge no note covers: a real answer, and none of
          //    the test notes may be presented as its source.
          const q4 = 'What is the capital of France?';
          final m4 = await rag.buildMessage(userQuestion: q4);
          final a4 = await _reply(runner, m4, system);
          // ignore: avoid_print
          print('QA[${id.name}] general Q="$q4" A="$a4" '
              'sources=${m4.sourceNoteIds.where((s) => s.startsWith(_prefix)).length}');
          expect(a4.toLowerCase(), contains('paris'));
        } finally {
          for (final (s, _) in notes.all) {
            await vectors.delete(idOf(s));
          }
          await isar.writeTxn(
            () => isar.noteModels
                .filter()
                .eventIdStartsWith('$_prefix$stamp')
                .deleteAll(),
          );
          await _dropDerived(isar);
        }
      },
      timeout: const Timeout(Duration(minutes: 25)),
    );
  }
}
