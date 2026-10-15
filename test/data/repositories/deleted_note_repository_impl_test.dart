import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/data/models/deleted_note_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/pending_vector_delete_model.dart';
import 'package:uniun/data/repositories/deleted_note_repository_impl.dart';

import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';

/// End-to-end tests for [DeletedNoteRepositoryImpl]. Real Isar so the
/// tombstone-insert + note-delete + relation-cleanup happen inside a single
/// writeTxn on real collections.
void main() {
  late Isar isar;
  late DeletedNoteRepositoryImpl repo;

  setUp(() async {
    isar = await openTestIsar();
    // Phase 6: local-hide is per-device, no mesh signer needed.
    repo = DeletedNoteRepositoryImpl(isar: isar);
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  Future<void> seedNote(String eventId, {String content = 'x'}) =>
      seedNoteRow(isar, eventId, content: content);
  Future<void> seedUnread(String eventId) => seedUnreadRow(isar, eventId);
  Future<void> seedEdge(String parent, String child) =>
      seedRelationEdge(isar, parent, child);

  // ── deleteNote ───────────────────────────────────────────────────────────

  group('deleteNote', () {
    test('inserts tombstone + returns Right(unit)', () async {
      final r = await repo.deleteNote('ev-1');
      expect(r.isRight(), isTrue);
      final tombstones =
          await isar.deletedNoteModels.where().findAll();
      expect(tombstones, hasLength(1));
      expect(tombstones.single.eventId, 'ev-1');
      expect(tombstones.single.deletedAt, isNotNull);
    });

    test('deletes the note row from Note collection', () async {
      await seedNote('ev-1');
      expect(await isar.noteModels.count(), 1);
      await repo.deleteNote('ev-1');
      expect(await isar.noteModels.count(), 0);
    });

    test('queues the note\'s vector for deletion in the same commit', () async {
      await seedNote('ev-1');

      await repo.deleteNote('ev-1');

      expect(
        (await isar.pendingVectorDeleteModels.where().findAll())
            .map((r) => r.eventId),
        ['ev-1'],
      );
    });

    test('deletes the unread row projection', () async {
      await seedUnread('ev-1');
      await repo.deleteNote('ev-1');
      expect(await isar.unreadNoteModels.count(), 0);
    });

    test('removes edges where the note is parent', () async {
      await seedEdge('ev-1', 'child-1');
      await seedEdge('ev-1', 'child-2');
      await repo.deleteNote('ev-1');
      expect(await isar.noteRelationModels.count(), 0);
    });

    test('removes edges where the note is child', () async {
      await seedEdge('parent', 'ev-1');
      await seedEdge('other-parent', 'ev-1');
      await repo.deleteNote('ev-1');
      expect(await isar.noteRelationModels.count(), 0);
    });

    test('leaves unrelated edges intact', () async {
      await seedEdge('ev-1', 'child');
      await seedEdge('unrelated-a', 'unrelated-b');
      await repo.deleteNote('ev-1');
      final remaining =
          await isar.noteRelationModels.where().findAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.parentId, 'unrelated-a');
      expect(remaining.single.childId, 'unrelated-b');
    });

    test('idempotent — second delete on same id still Right, single tombstone',
        () async {
      await repo.deleteNote('ev-1');
      final r = await repo.deleteNote('ev-1');
      expect(r.isRight(), isTrue);
      final tombstones = await isar.deletedNoteModels.where().findAll();
      expect(tombstones, hasLength(1),
          reason: 'unique eventId index replaces on re-put');
    });

    test('deletes even when note row does not exist (tombstone-only)',
        () async {
      final r = await repo.deleteNote('ghost');
      expect(r.isRight(), isTrue);
      final tombstones = await isar.deletedNoteModels.where().findAll();
      expect(tombstones.single.eventId, 'ghost');
    });

    test('full cascade — one call cleans note + unread + edges together',
        () async {
      await seedNote('ev-1');
      await seedUnread('ev-1');
      await seedEdge('ev-1', 'child');
      await seedEdge('parent', 'ev-1');
      await repo.deleteNote('ev-1');
      expect(await isar.noteModels.count(), 0);
      expect(await isar.unreadNoteModels.count(), 0);
      expect(await isar.noteRelationModels.count(), 0);
      expect(await isar.deletedNoteModels.count(), 1);
    });
  });

  // ── Scale ─────────────────────────────────────────────────────────────────

  group('scale', () {
    test('50 sequential deletes', () async {
      for (var i = 0; i < 50; i++) {
        await seedNote('ev-$i');
        await repo.deleteNote('ev-$i');
      }
      expect(await isar.deletedNoteModels.count(), 50);
      expect(await isar.noteModels.count(), 0);
    });
  });
}
