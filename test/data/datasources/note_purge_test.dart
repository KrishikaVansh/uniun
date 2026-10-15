@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/data/datasources/note_purge.dart';
import 'package:uniun/data/models/graph_edge_model.dart';
import 'package:uniun/data/models/graph_node_model.dart';
import 'package:uniun/data/models/memory_node_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/pending_embedding_model.dart';
import 'package:uniun/data/models/pending_extraction_model.dart';
import 'package:uniun/data/models/pending_vector_delete_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';

import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';

/// Covers: [purgeNotesInTxn] on real Isar — one transaction removes a note and
/// everything derived from it, keeps connected notes and shared concepts, and
/// queues the vector delete. A note that is still saved keeps its knowledge.
void main() {
  late Isar isar;

  setUp(() async => isar = await openTestIsar());
  tearDown(() async => isar.close(deleteFromDisk: true));

  Future<void> purge(List<String> ids) =>
      isar.writeTxn(() => purgeNotesInTxn(isar, ids));

  Future<void> seedKnowledge(String noteId, List<String> concepts) async {
    await isar.writeTxn(() async {
      await isar.memoryNodeModels.put(
        MemoryNodeModel()
          ..noteId = noteId
          ..summary = 'summary of $noteId'
          ..keyPoints = const []
          ..concepts = concepts
          ..linkedNoteIds = const []
          ..updatedAt = DateTime(2026),
      );
      for (final c in concepts) {
        if (await isar.graphNodeModels.filter().keyEqualTo(c).count() == 0) {
          await isar.graphNodeModels.put(
            GraphNodeModel()
              ..key = c
              ..name = c
              ..type = 'Concept'
              ..createdAt = DateTime(2026)
              ..updatedAt = DateTime(2026),
          );
        }
        await isar.graphEdgeModels.put(
          GraphEdgeModel()
            ..sourceKey = noteId
            ..targetKey = c
            ..relationType = 'mentions'
            ..sourceNoteId = noteId
            ..createdAt = DateTime(2026),
        );
      }
    });
  }

  Future<List<String>> queuedVectors() async => (await isar
          .pendingVectorDeleteModels
          .where()
          .findAll())
      .map((r) => r.eventId)
      .toList()
    ..sort();

  test('removes the note, its unread row and relation edges both ways',
      () async {
    await seedNoteRow(isar, 'a');
    await seedNoteRow(isar, 'b');
    await seedUnreadRow(isar, 'a');
    await seedRelationEdge(isar, 'a', 'b');
    await seedRelationEdge(isar, 'c', 'a');

    await purge(['a']);

    expect(await isar.noteModels.filter().eventIdEqualTo('a').count(), 0);
    expect(await isar.noteModels.filter().eventIdEqualTo('b').count(), 1);
    expect(await isar.unreadNoteModels.where().count(), 0);
    expect(await isar.noteRelationModels.where().count(), 0);
  });

  test('keeps a connected note, its memory and its own edges', () async {
    await seedNoteRow(isar, 'a');
    await seedNoteRow(isar, 'b');
    await seedKnowledge('a', ['isar', 'flutter']);
    await seedKnowledge('b', ['isar']);

    await purge(['a']);

    final memories = await isar.memoryNodeModels.where().findAll();
    expect(memories.map((m) => m.noteId), ['b']);
    final edges = await isar.graphEdgeModels.where().findAll();
    expect(edges.map((e) => e.sourceNoteId).toSet(), {'b'});
    expect(await isar.noteModels.filter().eventIdEqualTo('b').count(), 1);
  });

  test('keeps a concept another note still uses and drops one nobody does',
      () async {
    await seedKnowledge('a', ['isar', 'only-a']);
    await seedKnowledge('b', ['isar']);

    await purge(['a']);

    final keys = (await isar.graphNodeModels.where().findAll())
        .map((n) => n.key)
        .toSet();
    expect(keys, {'isar'});
  });

  test('takes the deleted note out of other notes\' linked ids', () async {
    await seedKnowledge('b', ['isar']);
    await isar.writeTxn(() async {
      final m = (await isar.memoryNodeModels
          .where()
          .noteIdEqualTo('b')
          .findFirst())!;
      m.linkedNoteIds = ['a', 'c'];
      await isar.memoryNodeModels.put(m);
    });

    await purge(['a']);

    final m =
        (await isar.memoryNodeModels.where().noteIdEqualTo('b').findFirst())!;
    expect(m.linkedNoteIds, ['c']);
  });

  test('drops its pending embedding and pending extraction rows', () async {
    await isar.writeTxn(() async {
      await isar.pendingEmbeddingModels.put(
        PendingEmbeddingModel()
          ..eventId = 'a'
          ..text = 't'
          ..createdAt = DateTime(2026),
      );
      await isar.pendingEmbeddingModels.put(
        PendingEmbeddingModel()
          ..eventId = 'b'
          ..text = 't'
          ..createdAt = DateTime(2026),
      );
      await isar.pendingExtractionModels.put(
        PendingExtractionModel()
          ..noteId = 'a'
          ..content = 't'
          ..vec = const []
          ..createdAt = DateTime(2026),
      );
    });

    await purge(['a']);

    expect(
      (await isar.pendingEmbeddingModels.where().findAll()).map((r) => r.eventId),
      ['b'],
    );
    expect(await isar.pendingExtractionModels.where().count(), 0);
  });

  test('queues one vector delete per purged note, also for unknown ids',
      () async {
    await seedNoteRow(isar, 'a');

    await purge(['a', 'never-stored']);
    await purge(['a']);

    expect(await queuedVectors(), ['a', 'never-stored']);
  });

  test('a note that is still saved keeps its vector, memory and graph',
      () async {
    await seedNoteRow(isar, 'a');
    await seedNoteRow(isar, 'b');
    await seedKnowledge('a', ['isar']);
    await isar.writeTxn(
      () => isar.savedNoteModels.put(savedNoteRow('a', content: 'saved copy')),
    );

    await purge(['a', 'b']);

    expect(await isar.noteModels.where().count(), 0);
    expect(await queuedVectors(), ['b']);
    expect(await isar.memoryNodeModels.where().count(), 1);
    expect(await isar.graphEdgeModels.where().count(), 1);
  });

  test('a removed saved row does not count as saved', () async {
    await seedNoteRow(isar, 'a');
    await isar.writeTxn(
      () => isar.savedNoteModels.put(
        savedNoteRow('a')..removedAt = DateTime(2026),
      ),
    );

    await purge(['a']);

    expect(await queuedVectors(), ['a']);
  });

  test('an empty list changes nothing', () async {
    await seedNoteRow(isar, 'a');

    await purge(const []);

    expect(await isar.noteModels.where().count(), 1);
    expect(await queuedVectors(), isEmpty);
  });

  test('unicode and very long ids are handled', () async {
    final long = 'x' * 500;
    await seedNoteRow(isar, 'नमस्ते-🌟');
    await seedNoteRow(isar, long);

    await purge(['नमस्ते-🌟', long]);

    expect(await isar.noteModels.where().count(), 0);
    expect(await queuedVectors(), hasLength(2));
  });

  test('a hundred notes purge in one pass', () async {
    final ids = [for (var i = 0; i < 100; i++) 'n$i'];
    await isar.writeTxn(
      () => isar.noteModels.putAll([for (final id in ids) noteRow(id)]),
    );

    await purge(ids);

    expect(await isar.noteModels.where().count(), 0);
    expect(await queuedVectors(), hasLength(100));
  });

  test('a few thousand notes with knowledge purge in one pass, without a '
      'per-note scan', () async {
    final ids = [for (var i = 0; i < 3000; i++) 'bulk$i'];
    await isar.writeTxn(() async {
      await isar.noteModels.putAll([for (final id in ids) noteRow(id)]);
      await isar.memoryNodeModels.putAll([
        for (final id in ids)
          MemoryNodeModel()
            ..noteId = id
            ..summary = 's'
            ..keyPoints = const []
            ..concepts = const []
            ..linkedNoteIds = const []
            ..updatedAt = DateTime(2026),
      ]);
      await isar.graphEdgeModels.putAll([
        for (final id in ids)
          GraphEdgeModel()
            ..sourceKey = id
            ..targetKey = 'shared'
            ..relationType = 'mentions'
            ..sourceNoteId = id
            ..createdAt = DateTime(2026),
      ]);
    });

    final clock = Stopwatch()..start();
    await purge(ids);
    clock.stop();

    expect(await isar.noteModels.where().count(), 0);
    expect(await isar.memoryNodeModels.where().count(), 0);
    expect(await isar.graphEdgeModels.where().count(), 0);
    expect(await queuedVectors(), hasLength(3000));
    // A scan per id over 3000 rows takes minutes; index lookups take seconds.
    expect(clock.elapsed, lessThan(const Duration(seconds: 30)));
  });
}
