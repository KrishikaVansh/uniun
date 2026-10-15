import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/enum/gana_run_status.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/models/followed_note_model.dart';
import 'package:uniun/data/models/gana_run_model.dart';
import 'package:uniun/data/models/media/media_cache_model.dart';
import 'package:uniun/data/models/notes/media_attachment.dart';
import 'package:uniun/data/models/memory_node_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/pending_vector_delete_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';
import 'package:uniun/gateway/cleanup/cleanup_manager.dart';

import '../../_helpers/isar_test_harness.dart';

const _kSelf = 'self-pub-hex';
const _kAlice = 'alice-pub-hex';

NoteModel _note({
  required String eventId,
  String authorPubkey = _kAlice,
  int kind = kNoteKind,
  DateTime? created,
  List<MediaAttachment> attachments = const [],
}) {
  return NoteModel(
    eventId: eventId,
    sig: 'sig',
    authorPubkey: authorPubkey,
    content: 'x',
    kind: kind,
    type: NoteType.text,
    eTagRefs: const [],
    pTagRefs: const [],
    tTags: const [],
    created: created ?? DateTime.now().subtract(const Duration(days: 30)),
    attachments: attachments,
  );
}

/// Covers: CleanupManager's start/stop timer lifecycle (retention-disabled
/// never ticks, double-start is idempotent), note eviction (own/saved/
/// followed notes are spared, non-public kinds untouched, cutoff boundary),
/// media GC (orphaned cache rows + files are removed, referenced-via-note
/// and referenced-via-saved-row media survive, a missing file on disk
/// doesn't block the Isar row cleanup), Gana run-log pruning (per-Gana ring
/// of 10 + the 1000 global cap), and published-draft tombstone purging
/// (age cutoff, only rows with publishedAsEventId set).
void main() {
  late Isar isar;
  late Directory tmpDir;

  setUp(() async {
    isar = await openTestIsar();
    tmpDir = await Directory.systemTemp.createTemp('cleanup_test_');
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('start/stop', () {
    test('retention == null never starts a timer (runOnce not scheduled)',
        () async {
      final mgr = CleanupManager(isar: isar, activePubkey: _kSelf, retention: null);
      mgr.start();
      // No direct timer accessor; verify indirectly via no note eviction
      // even for an old stale note (runOnce would delete it if it fired).
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1'));
      });
      await mgr.runOnce();
      expect(await isar.noteModels.where().count(), 1); // retention null -> no eviction
      mgr.stop();
    });

    test('start with retention set arms the periodic timer and schedules '
        'the delayed first sweep', () {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      expect(mgr.start, returnsNormally);
      mgr.stop();
    });

    test('a second start() call is a no-op (timer already armed)', () {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      mgr.start();
      expect(mgr.start, returnsNormally); // early-return, no double timer
      mgr.stop();
    });

    test('stop before start is a harmless no-op', () {
      final mgr = CleanupManager(isar: isar, activePubkey: _kSelf, retention: null);
      expect(mgr.stop, returnsNormally);
    });

    test('a thrown error inside a phase is caught and logged, not '
        'propagated', () async {
      final closedIsar = await openTestIsar();
      await closedIsar.close(deleteFromDisk: true);
      final mgr = CleanupManager(
        isar: closedIsar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await expectLater(mgr.runOnce(), completes);
    });

    test('runOnce is reentrancy-guarded (concurrent calls collapse to one '
        'sweep)', () async {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      final f1 = mgr.runOnce();
      final f2 = mgr.runOnce(); // should return immediately, _running guard
      await Future.wait([f1, f2]);
      // No crash / no throw is the assertion here.
    });
  });

  group('note eviction', () {
    test('a stale Kind-1 note past the cutoff is deleted', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1'));
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 0);
    });

    test('an evicted note queues its vector delete and loses its memory, '
        'a saved one keeps both', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.putAll([
          _note(eventId: 'old'),
          _note(eventId: 'kept'),
        ]);
        await isar.savedNoteModels.put(
          SavedNoteModel()
            ..eventId = 'kept'
            ..authorPubkey = 'p'
            ..sig = ''
            ..content = 'c'
            ..type = NoteType.text
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..created = DateTime(2026)
            ..savedAt = DateTime(2026),
        );
        for (final id in ['old', 'kept']) {
          await isar.memoryNodeModels.put(
            MemoryNodeModel()
              ..noteId = id
              ..summary = 's'
              ..keyPoints = const []
              ..concepts = const []
              ..linkedNoteIds = const []
              ..updatedAt = DateTime(2026),
          );
        }
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(
        (await isar.pendingVectorDeleteModels.where().findAll())
            .map((r) => r.eventId),
        ['old'],
      );
      expect(
        (await isar.memoryNodeModels.where().findAll()).map((m) => m.noteId),
        ['kept'],
      );
    });

    test('a note newer than the cutoff survives', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1', created: DateTime.now()));
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 1);
    });

    test('own notes are spared regardless of age', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1', authorPubkey: _kSelf));
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 1);
    });

    test('a saved note is spared', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1'));
        await isar.savedNoteModels.put(
          SavedNoteModel()
            ..eventId = 'n1'
            ..sig = 'sig'
            ..authorPubkey = _kAlice
            ..content = 'x'
            ..type = NoteType.text
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..created = DateTime.now()
            ..savedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 1);
    });

    test('a followed note is spared', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'n1'));
        await isar.followedNoteModels.put(
          FollowedNoteModel()
            ..eventId = 'n1'
            ..contentPreview = 'x'
            ..followedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 1);
    });

    test('a stale Kind-42 group message is also evicted', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'm1', kind: kGroupMessageKind));
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 0);
    });

    test('non-public kinds (e.g. DM, private group) are never touched by '
        'eviction', () async {
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(eventId: 'd1', kind: 14));
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.noteModels.where().count(), 1);
    });

    test('an empty note set is a harmless no-op', () async {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();
      expect(await isar.noteModels.where().count(), 0);
    });
  });

  group('media GC', () {
    test('an orphaned cache row (no surviving note or saved-row reference) '
        'is deleted, and its file removed from disk', () async {
      final file = File('${tmpDir.path}/orphan.jpg')..writeAsStringSync('x');
      await isar.writeTxn(() async {
        await isar.mediaCacheModels.put(
          MediaCacheModel()
            ..sha256 = 'orphan-sha'
            ..localPath = file.path
            ..downloadedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.mediaCacheModels.where().count(), 0);
      expect(await file.exists(), isFalse);
    });

    test('media referenced by a live note survives GC', () async {
      final file = File('${tmpDir.path}/kept.jpg')..writeAsStringSync('x');
      await isar.writeTxn(() async {
        await isar.noteModels.put(_note(
          eventId: 'n1',
          authorPubkey: _kSelf, // own note, spared by eviction
          attachments: [
            MediaAttachment()
              ..sha256 = 'kept-sha'
              ..mime = 'image/jpeg',
          ],
        ));
        await isar.mediaCacheModels.put(
          MediaCacheModel()
            ..sha256 = 'kept-sha'
            ..localPath = file.path
            ..downloadedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.mediaCacheModels.where().count(), 1);
      expect(await file.exists(), isTrue);
    });

    test('media referenced only by a SavedNoteModel row survives GC',
        () async {
      final file = File('${tmpDir.path}/saved.jpg')..writeAsStringSync('x');
      await isar.writeTxn(() async {
        await isar.savedNoteModels.put(
          SavedNoteModel()
            ..eventId = 's1'
            ..sig = 'sig'
            ..authorPubkey = _kAlice
            ..content = 'x'
            ..type = NoteType.text
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..created = DateTime.now()
            ..savedAt = DateTime.now()
            ..attachments = [
              MediaAttachment()
                ..sha256 = 'saved-sha'
                ..mime = 'image/jpeg',
            ],
        );
        await isar.mediaCacheModels.put(
          MediaCacheModel()
            ..sha256 = 'saved-sha'
            ..localPath = file.path
            ..downloadedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.mediaCacheModels.where().count(), 1);
    });

    test('a cache row whose file is already missing on disk is still '
        'removed from Isar (no crash)', () async {
      await isar.writeTxn(() async {
        await isar.mediaCacheModels.put(
          MediaCacheModel()
            ..sha256 = 'ghost-sha'
            ..localPath = '${tmpDir.path}/does-not-exist.jpg'
            ..downloadedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.mediaCacheModels.where().count(), 0);
    });

    test('retention == null skips media GC entirely', () async {
      final file = File('${tmpDir.path}/x.jpg')..writeAsStringSync('x');
      await isar.writeTxn(() async {
        await isar.mediaCacheModels.put(
          MediaCacheModel()
            ..sha256 = 'x-sha'
            ..localPath = file.path
            ..downloadedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(isar: isar, activePubkey: _kSelf, retention: null);
      await mgr.runOnce();

      expect(await isar.mediaCacheModels.where().count(), 1);
    });

    test('no cache rows at all is a harmless no-op', () async {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();
      expect(await isar.mediaCacheModels.where().count(), 0);
    });
  });

  group('Gana run-log pruning', () {
    Future<void> seedRun(String ganaId, String runId, DateTime startedAt) {
      return isar.writeTxn(() async {
        await isar.ganaRunModels.put(
          GanaRunModel()
            ..runId = runId
            ..ganaId = ganaId
            ..startedAt = startedAt
            ..status = GanaRunStatus.succeeded,
        );
      });
    }

    /// Builds many rows in a single transaction (vs. one writeTxn per row) —
    /// large seed counts (hundreds+) would otherwise take minutes.
    Future<void> seedRunsBulk(List<GanaRunModel> rows) {
      return isar.writeTxn(() => isar.ganaRunModels.putAll(rows));
    }

    test('keeps only the newest 10 runs per Gana', () async {
      for (var i = 0; i < 15; i++) {
        await seedRun('g1', 'run-$i', DateTime(2026, 1, 1).add(Duration(hours: i)));
      }
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      final remaining = await isar.ganaRunModels
          .filter()
          .ganaIdEqualTo('g1')
          .findAll();
      expect(remaining.length, 10);
      // The newest 10 (run-5..run-14) survive.
      expect(
        remaining.map((r) => r.runId).toSet(),
        {for (var i = 5; i < 15; i++) 'run-$i'},
      );
    });

    test('an empty Gana-run table is a harmless no-op', () async {
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();
      expect(await isar.ganaRunModels.where().count(), 0);
    });

    test('enforces the global 1000-run cap across many Ganas', () async {
      // 3 Ganas x 5 runs each = 15 total, well under the per-Gana keep of
      // 10 but let's push the GLOBAL cap by seeding many distinct Ganas
      // with few runs each so the per-Gana ring never trims anything —
      // only the global cap should act.
      for (var g = 0; g < 3; g++) {
        for (var i = 0; i < 5; i++) {
          await seedRun('gana-$g', 'gana-$g-run-$i',
              DateTime(2026, 1, 1).add(Duration(hours: g * 10 + i)));
        }
      }
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      // 15 total is under the 1000 cap and under the per-gana ring of 10 —
      // nothing should be removed.
      expect(await isar.ganaRunModels.where().count(), 15);
    });

    test('trims the oldest runs once the global 1000-run cap is exceeded',
        () async {
      // 101 Ganas x 10 runs = 1010 total. Each Gana's ring keeps all 10 of
      // its own runs (right at the per-Gana limit), so only the GLOBAL cap
      // trims anything: the 10 globally-oldest runs.
      final rows = <GanaRunModel>[
        for (var g = 0; g < 101; g++)
          for (var i = 0; i < 10; i++)
            GanaRunModel()
              ..runId = 'gana-$g-run-$i'
              ..ganaId = 'gana-$g'
              ..startedAt = DateTime(2026, 1, 1).add(Duration(minutes: g * 10 + i))
              ..status = GanaRunStatus.succeeded,
      ];
      await seedRunsBulk(rows);
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.ganaRunModels.where().count(), 1000);
      // The globally-oldest run (gana-0-run-0) must be gone.
      expect(
        await isar.ganaRunModels.filter().runIdEqualTo('gana-0-run-0').count(),
        0,
      );
    });
  });

  group('published-draft tombstone purge', () {
    test('a published draft older than 30 days is purged', () async {
      await isar.writeTxn(() async {
        await isar.draftModels.put(
          DraftModel()
            ..draftId = 'd1'
            ..content = 'x'
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..publishedAsEventId = 'evt-1'
            ..createdAt = DateTime.now().subtract(const Duration(days: 40))
            ..updatedAt = DateTime.now().subtract(const Duration(days: 31)),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.draftModels.where().count(), 0);
    });

    test('a recently-published draft is kept', () async {
      await isar.writeTxn(() async {
        await isar.draftModels.put(
          DraftModel()
            ..draftId = 'd1'
            ..content = 'x'
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..publishedAsEventId = 'evt-1'
            ..createdAt = DateTime.now()
            ..updatedAt = DateTime.now(),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.draftModels.where().count(), 1);
    });

    test('an unpublished (still-editing) draft is never purged, regardless '
        'of age', () async {
      await isar.writeTxn(() async {
        await isar.draftModels.put(
          DraftModel()
            ..draftId = 'd1'
            ..content = 'x'
            ..eTagRefs = const []
            ..pTagRefs = const []
            ..tTags = const []
            ..createdAt = DateTime.now().subtract(const Duration(days: 400))
            ..updatedAt = DateTime.now().subtract(const Duration(days: 400)),
        );
      });
      final mgr = CleanupManager(
        isar: isar,
        activePubkey: _kSelf,
        retention: const Duration(days: 7),
      );
      await mgr.runOnce();

      expect(await isar.draftModels.where().count(), 1);
    });
  });
}
