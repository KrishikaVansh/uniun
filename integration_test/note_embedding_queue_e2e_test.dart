// Real-device check of the pending-embeddings queue (#231): a note handed to
// EmbedAndStoreNoteUseCase is queued, embedded by NoteEmbeddingWorker with the
// real Gecko model, its vector is stored, and its queue row is gone.
// Embedding is slow on weak phones (about 12 s a note on a Snapdragon 710), so
// the wait is generous. The test vector is deleted afterwards.
//
// The second test covers deletion: leftover vectors of earlier runs are swept
// on launch, and a deleted note's vector leaves the store and search at once.
//
//   scripts/device_test.sh run integration_test/note_embedding_queue_e2e_test.dart

import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart' show GemmaEmbeddingTokenizers;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/data/datasources/note_vector_store.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/domain/repositories/pending_embedding_repository.dart';
import 'package:uniun/domain/repositories/vector_repository.dart';
import 'package:uniun/domain/usecases/deleted_note_usecases.dart';
import 'package:uniun/features/shiv/rag/indexing/note_vector_cleanup_worker.dart';
import 'package:uniun/domain/usecases/vector_usecases.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a queued note is embedded, stored and leaves the queue',
    (tester) async {
      await configureDependencies();
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
        embeddingBackends: const [LiteRtEmbeddingBackend()],
        embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
      );
      final pending = getIt<PendingEmbeddingRepository>();
      final vectors = getIt<VectorRepository>();
      final embedding = getIt<EmbeddingService>();

      // A cold embedder load is the first embed: fail loudly, never skip, since
      // Gecko ships as a bundled asset.
      expect(
        await embedding.embed('probe'),
        isNotEmpty,
        reason: '[] means the bundled embedding model did not load',
      );

      // `--no-uninstall` keeps the device database, so rows queued by earlier
      // tests are still pending and would each cost an embed plus an extract
      // pass. This test is about its own note, so start from an empty queue.
      for (;;) {
        final next = (await pending.next()).getOrElse(() => null);
        if (next == null) break;
        await pending.remove(next.eventId);
      }

      final id = 'e2e-pending-${DateTime.now().microsecondsSinceEpoch}';
      const text = 'The harbour lighthouse keeper logged every ship at dawn.';
      // Search returns a hit's text from the notes tables, so the note must exist
      // there, as a saved or own note would.
      final isar = getIt<Isar>();
      await isar.writeTxn(
        () => isar.noteModels.put(
          NoteModel(
            eventId: id,
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
      await getIt<EmbedAndStoreNoteUseCase>().call((id, text));
      expect(
        (await pending.count()).getOrElse(() => -1),
        greaterThanOrEqualTo(1),
      );

      try {
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while ((await pending.count()).getOrElse(() => -1) > 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }

        expect(
          (await pending.count()).getOrElse(() => -1),
          0,
          reason: 'queue should be drained',
        );

        expect(
          await getIt<NoteVectorStore>().contains(id),
          isTrue,
          reason: 'the vector should be stored',
        );
      } finally {
        await vectors.delete(id);
        await isar.writeTxn(
          () => isar.noteModels
              .filter()
              .eventIdStartsWith('e2e-pending-')
              .deleteAll(),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  testWidgets(
    'launch sweep clears leftovers; deleting a note removes its vector',
    (tester) async {
      if (!getIt.isRegistered<Isar>()) await configureDependencies();
      await FlutterEdgeAi.initialize(
        inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
        embeddingBackends: const [LiteRtEmbeddingBackend()],
        embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
      );
      final isar = getIt<Isar>();
      final store = getIt<NoteVectorStore>();
      final embedder = getIt<EmbeddingService>();
      final pending = getIt<PendingEmbeddingRepository>();
      expect(await embedder.embed('probe'), isNotEmpty);

      // Leftover test vectors, seen through the index and through the table.
      Future<int> leftovers() async {
        var n = 0;
        for (final probe in const [
          'Trip plan: we fly to Lisbon and stay at a hotel for five nights',
          'Bike service log: the rear tyre was replaced',
          'Grandmother lentil soup with carrots and cumin',
          'The harbour lighthouse keeper logged every ship at dawn',
        ]) {
          final hits = await store.search(await embedder.embed(probe), topK: 60);
          n += hits.where((h) => h.id.startsWith('e2e-')).length;
        }
        return n;
      }

      final before = await leftovers();
      final idsBefore = (await store.ids()).length;
      // ignore: avoid_print
      print('VECCLEAN before: e2e hits=$before vectors=$idsBefore');

      final worker = getIt<NoteVectorCleanupWorker>();
      worker.start();
      await worker.idle();

      // The store rebuilds its index a little after the last delete, so give
      // the first test's cleanup that long.
      var after = await leftovers();
      final settle = DateTime.now().add(const Duration(seconds: 90));
      while (after > 0 && DateTime.now().isBefore(settle)) {
        await Future<void>.delayed(const Duration(seconds: 5));
        after = await leftovers();
      }
      // ignore: avoid_print
      print('VECCLEAN after sweep: e2e hits=$after '
          'vectors=${(await store.ids()).length}');
      expect(after, 0, reason: 'no leftover test vector may be searchable');

      // Drain stale queue rows so the next note is embedded promptly.
      for (;;) {
        final next = (await pending.next()).getOrElse(() => null);
        if (next == null) break;
        await pending.remove(next.eventId);
      }

      final id = 'e2e-clean-${DateTime.now().microsecondsSinceEpoch}';
      const text = 'The mountain hut warden writes the weather in a red book.';
      await isar.writeTxn(
        () => isar.noteModels.put(
          NoteModel(
            eventId: id,
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
      await getIt<EmbedAndStoreNoteUseCase>().call((id, text));
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      while (!await store.contains(id) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(await store.contains(id), isTrue, reason: 'the note is embedded');

      final deleted = await getIt<DeleteNoteUseCase>().call(id);
      expect(deleted.isRight(), isTrue);
      final gone = DateTime.now().add(const Duration(seconds: 30));
      while (await store.contains(id) && DateTime.now().isBefore(gone)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      expect(await store.contains(id), isFalse,
          reason: 'deleting the note must remove its vector');
      final hits = await store.search(await embedder.embed(text), topK: 20);
      expect(hits.map((h) => h.id), isNot(contains(id)));
      // ignore: avoid_print
      print('VECCLEAN OK: deleted note vector gone, search clean');
      await worker.stop();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
