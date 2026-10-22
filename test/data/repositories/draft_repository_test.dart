import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/repositories/draft_repository_impl.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/user_key/user_key_entity.dart';
import 'package:uniun/domain/repositories/event_queue_repository.dart';
import 'package:uniun/domain/repositories/user_repository.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';

import '../../_helpers/isar_test_harness.dart';

/// End-to-end tests for [DraftRepositoryImpl]. Uses a real on-disk Isar (so
/// queries with filters/indexes/sorts run for real) but stubs the two
/// non-Isar collaborators:
///   - [GetActiveUserKeysUseCase] → a subclass that returns fixed test keys
///     (avoids depending on a real bech32 nsec / FlutterSecureStorage)
///   - [EventQueueRepository] → a recorder that captures every wrap publish
///     so we can assert "deletion signal emitted", "republish on
///     markPublished", etc. without spinning up the gateway.
///
/// The repository's own behaviour — Isar reads/writes, sweep loops, tombstone
/// retention queries — runs unstubbed.
void main() {
  late Isar isar;
  late DraftRepositoryImpl repo;
  late _RecordingEventQueue events;
  late _StubActiveKeys keys;

  setUp(() async {
    isar = await openTestIsar();
    events = _RecordingEventQueue();
    keys = _StubActiveKeys();
    repo = DraftRepositoryImpl(
      isar: isar,
      eventQueue: events,
      getActiveUserKeys: keys,
      attachments: NoteAttachmentsEnricher(isar: isar),
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  DraftEntity draft({
    String draftId = 'd-1',
    String content = 'hello',
    String? rootEventId,
    String? replyToEventId,
    List<String> eTagRefs = const [],
    List<String> pTagRefs = const [],
    List<String> tTags = const [],
    List<String> draftRefIds = const [],
    String? publishedAsEventId,
    List<MediaBlobEntity> attachments = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      DraftEntity(
        draftId: draftId,
        content: content,
        rootEventId: rootEventId,
        replyToEventId: replyToEventId,
        eTagRefs: eTagRefs,
        pTagRefs: pTagRefs,
        tTags: tTags,
        draftRefIds: draftRefIds,
        publishedAsEventId: publishedAsEventId,
        attachments: attachments,
        createdAt: createdAt ?? DateTime(2026, 6, 1),
        updatedAt: updatedAt ?? DateTime(2026, 6, 1),
      );

  // ── saveDraft ─────────────────────────────────────────────────────────────

  group('saveDraft', () {
    test('creates a new row and returns the enriched entity', () async {
      final res = await repo.saveDraft(draft(draftId: 'd-1', content: 'first'));
      expect(res.isRight(), isTrue);
      expect(res.getOrElse(() => throw 'left').content, 'first');

      final row = await isar.draftModels
          .filter()
          .draftIdEqualTo('d-1')
          .findFirst();
      expect(row, isNotNull);
      expect(row!.content, 'first');
    });

    test('updating an existing draft replaces the row in place (no duplicate)', () async {
      await repo.saveDraft(draft(draftId: 'd-1', content: 'v1'));
      await repo.saveDraft(draft(
        draftId: 'd-1',
        content: 'v2',
        updatedAt: DateTime(2026, 6, 2),
      ));

      final all = await isar.draftModels
          .filter()
          .draftIdEqualTo('d-1')
          .findAll();
      expect(all, hasLength(1), reason: 'draftId is the unique key');
      expect(all.single.content, 'v2');
      expect(all.single.updatedAt, DateTime(2026, 6, 2));
    });

    test('persists draftRefIds + publishedAsEventId verbatim', () async {
      await repo.saveDraft(draft(
        draftId: 'parent',
        draftRefIds: ['child-a', 'child-b'],
      ));
      final row = (await isar.draftModels.filter().draftIdEqualTo('parent').findFirst())!;
      expect(row.draftRefIds, ['child-a', 'child-b']);
      expect(row.publishedAsEventId, isNull);
    });

    test('enqueues a NIP-37 wrap on every save', () async {
      events.calls.clear();
      await repo.saveDraft(draft(draftId: 'd-1'));
      expect(events.calls, hasLength(1));
      expect(events.calls.single.kind, 31234);
      expect(events.calls.single.dTag, 'd-1');
      expect(events.calls.single.content, isNotEmpty,
          reason: 'live save → encrypted content, not the deletion signal');
    });

    test('publish failure does NOT surface as a save failure (local is source of truth)', () async {
      events.shouldThrow = true;
      final res = await repo.saveDraft(draft(draftId: 'd-1'));
      expect(res.isRight(), isTrue,
          reason: 'best-effort relay sync — Isar succeeded so the save succeeded');
      expect(await isar.draftModels.where().count(), 1);
    });
  });

  // ── getDrafts ─────────────────────────────────────────────────────────────

  group('getDrafts', () {
    test('returns rows sorted updatedAt-DESC (newest first)', () async {
      await repo.saveDraft(draft(
        draftId: 'old',
        updatedAt: DateTime(2026, 1, 1),
      ));
      await repo.saveDraft(draft(
        draftId: 'new',
        updatedAt: DateTime(2026, 6, 1),
      ));
      await repo.saveDraft(draft(
        draftId: 'mid',
        updatedAt: DateTime(2026, 3, 1),
      ));

      final list =
          (await repo.getDrafts()).getOrElse(() => []).map((d) => d.draftId).toList();
      expect(list, ['new', 'mid', 'old']);
    });

    test('excludes tombstones (publishedAsEventId set)', () async {
      // Insert a live draft and a tombstone directly via Isar.
      await isar.writeTxn(() async {
        await isar.draftModels.put(DraftModel()
          ..draftId = 'live'
          ..content = 'live'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = DateTime(2026, 1, 1)
          ..updatedAt = DateTime(2026, 1, 1));
        await isar.draftModels.put(DraftModel()
          ..draftId = 'gone'
          ..content = 'gone'
          ..publishedAsEventId = 'evt-published'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = DateTime(2026, 1, 1)
          ..updatedAt = DateTime(2026, 1, 1));
      });

      final list = (await repo.getDrafts()).getOrElse(() => []);
      expect(list.map((d) => d.draftId), ['live']);
    });

    test('empty when no drafts exist', () async {
      final res = await repo.getDrafts();
      expect(res.isRight(), isTrue);
      expect(res.getOrElse(() => []), isEmpty);
    });
  });

  // ── getDraftById ──────────────────────────────────────────────────────────

  group('getDraftById', () {
    test('returns the draft when present', () async {
      await repo.saveDraft(draft(draftId: 'd-1', content: 'body'));
      final res = await repo.getDraftById('d-1');
      expect(res.isRight(), isTrue);
      expect(res.getOrElse(() => throw 'left').content, 'body');
    });

    test('returns notFound when missing', () async {
      final res = await repo.getDraftById('nope');
      expect(res.isLeft(), isTrue);
      res.fold(
        (f) => expect(f.toString().toLowerCase(), contains('not found')),
        (_) => fail('expected Left'),
      );
    });
  });

  // ── getDraftsReferencing ──────────────────────────────────────────────────

  group('getDraftsReferencing', () {
    Future<List<String>> repliesTo(String id) async => (await repo
            .getDraftsReferencing(id))
        .getOrElse(() => throw 'left')
        .map((d) => d.draftId)
        .toList();

    test('returns only the drafts that reference the id, oldest first',
        () async {
      await repo.saveDraft(draft(draftId: 'parent'));
      await repo.saveDraft(draft(
          draftId: 'late',
          draftRefIds: ['parent'],
          createdAt: DateTime(2026, 6, 3)));
      await repo.saveDraft(draft(
          draftId: 'early',
          draftRefIds: ['other', 'parent'],
          createdAt: DateTime(2026, 6, 2)));
      await repo.saveDraft(draft(draftId: 'unrelated', draftRefIds: ['other']));

      expect(await repliesTo('parent'), ['early', 'late']);
    });

    test('a reply that was already published is no longer a draft reply',
        () async {
      await repo.saveDraft(draft(draftId: 'parent'));
      await repo.saveDraft(draft(
          draftId: 'sent', draftRefIds: ['parent'], publishedAsEventId: 'e1'));

      expect(await repliesTo('parent'), isEmpty);
    });

    test('an id nothing references, or an empty id, has no replies', () async {
      await repo.saveDraft(draft(draftId: 'parent'));

      expect(await repliesTo('parent'), isEmpty);
      expect(await repliesTo(''), isEmpty);
    });

    test('replies keep their staged attachments', () async {
      await repo.saveDraft(draft(draftId: 'parent'));
      await repo.saveDraft(draft(
          draftId: 'pic',
          draftRefIds: ['parent'],
          attachments: [
            const MediaBlobEntity(
                sha256: 'sha-1', mime: 'image/png', sizeBytes: 3),
          ]));

      final reply = (await repo.getDraftsReferencing('parent'))
          .getOrElse(() => throw 'left')
          .single;
      expect(reply.attachments.single.sha256, 'sha-1');
    });

    test('publishing the parent turns the reference into a real event id, so '
        'the reply stops being a draft reply', () async {
      await repo.saveDraft(draft(draftId: 'parent'));
      await repo.saveDraft(draft(draftId: 'reply', draftRefIds: ['parent']));

      await repo.markPublished(draftId: 'parent', eventId: 'evt-parent');

      expect(await repliesTo('parent'), isEmpty);
      final reply = (await repo.getDraftById('reply')).getOrElse(() => throw 'x');
      expect(reply.draftRefIds, isEmpty);
      expect(reply.eTagRefs, ['evt-parent']);
    });

    test('a closed database surfaces as Left', () async {
      await isar.close();

      expect((await repo.getDraftsReferencing('parent')).isLeft(), isTrue);
      isar = await openTestIsar();
    });
  });

  // ── deleteDraft ───────────────────────────────────────────────────────────

  group('deleteDraft', () {
    test('removes the row locally', () async {
      await repo.saveDraft(draft(draftId: 'd-1'));
      await repo.deleteDraft('d-1');
      expect(await isar.draftModels.where().count(), 0);
    });

    test('emits a NIP-37 deletion signal (empty content) on the same d-tag', () async {
      await repo.saveDraft(draft(draftId: 'd-1'));
      events.calls.clear();

      await repo.deleteDraft('d-1');

      expect(events.calls, hasLength(1));
      expect(events.calls.single.dTag, 'd-1');
      expect(events.calls.single.content, '',
          reason: 'empty content = NIP-37 deletion signal');
    });

    test('deleting a missing draft is a no-op locally but still publishes a tombstone wrap', () async {
      // Receivers of this wrap may still hold the draft and need the signal.
      final res = await repo.deleteDraft('ghost');
      expect(res.isRight(), isTrue);
      expect(events.calls.where((c) => c.dTag == 'ghost'), hasLength(1));
    });
  });

  // ── markPublished ─────────────────────────────────────────────────────────

  group('markPublished', () {
    test('stamps publishedAsEventId on the target row', () async {
      await repo.saveDraft(draft(draftId: 'd-1'));
      await repo.markPublished(draftId: 'd-1', eventId: 'evt-1');

      final row = (await isar.draftModels.filter().draftIdEqualTo('d-1').findFirst())!;
      expect(row.publishedAsEventId, 'evt-1');
    });

    test('republishes the wrap (so other devices learn UUID→eventId)', () async {
      await repo.saveDraft(draft(draftId: 'd-1'));
      events.calls.clear();
      await repo.markPublished(draftId: 'd-1', eventId: 'evt-1');
      expect(events.calls.where((c) => c.dTag == 'd-1'), hasLength(1));
    });

    test('sweeps local drafts that reference this UUID — rewrites to eventId', () async {
      // parent references child by UUID; publish child → parent's draftRefIds
      // loses the UUID and gains the real eventId in eTagRefs.
      await repo.saveDraft(draft(draftId: 'child'));
      await repo.saveDraft(draft(
        draftId: 'parent',
        draftRefIds: ['child'],
      ));

      await repo.markPublished(draftId: 'child', eventId: 'evt-child');

      final parent =
          (await isar.draftModels.filter().draftIdEqualTo('parent').findFirst())!;
      expect(parent.draftRefIds, isEmpty);
      expect(parent.eTagRefs, contains('evt-child'));
    });

    test('sweep is idempotent — re-running adds nothing', () async {
      await repo.saveDraft(draft(draftId: 'child'));
      await repo.saveDraft(draft(draftId: 'parent', draftRefIds: ['child']));
      await repo.markPublished(draftId: 'child', eventId: 'evt-child');
      await repo.markPublished(draftId: 'child', eventId: 'evt-child');

      final parent =
          (await isar.draftModels.filter().draftIdEqualTo('parent').findFirst())!;
      expect(parent.eTagRefs.where((e) => e == 'evt-child'), hasLength(1));
    });

    test('one published child fans out to multiple parents', () async {
      await repo.saveDraft(draft(draftId: 'child'));
      await repo.saveDraft(draft(draftId: 'p1', draftRefIds: ['child']));
      await repo.saveDraft(draft(draftId: 'p2', draftRefIds: ['child', 'other']));

      await repo.markPublished(draftId: 'child', eventId: 'evt-child');

      final p1 = (await isar.draftModels.filter().draftIdEqualTo('p1').findFirst())!;
      final p2 = (await isar.draftModels.filter().draftIdEqualTo('p2').findFirst())!;

      expect(p1.draftRefIds, isEmpty);
      expect(p1.eTagRefs, ['evt-child']);

      expect(p2.draftRefIds, ['other'], reason: 'unrelated UUID survives');
      expect(p2.eTagRefs, ['evt-child']);
    });

    test('missing draft → no-op, returns Right(unit)', () async {
      final res = await repo.markPublished(draftId: 'ghost', eventId: 'evt');
      expect(res.isRight(), isTrue);
    });
  });

  // ── rewriteDraftRefs (cross-device sweep) ────────────────────────────────

  group('rewriteDraftRefs', () {
    test('rewrites draftRefIds → eTagRefs on every referencing draft', () async {
      await repo.saveDraft(draft(draftId: 'a', draftRefIds: ['x']));
      await repo.saveDraft(draft(draftId: 'b', draftRefIds: ['x']));
      await repo.saveDraft(draft(draftId: 'c', draftRefIds: ['y']));

      await repo.rewriteDraftRefs(draftUuid: 'x', eventId: 'evt-x');

      final a = (await isar.draftModels.filter().draftIdEqualTo('a').findFirst())!;
      final b = (await isar.draftModels.filter().draftIdEqualTo('b').findFirst())!;
      final c = (await isar.draftModels.filter().draftIdEqualTo('c').findFirst())!;
      expect(a.draftRefIds, isEmpty);
      expect(a.eTagRefs, ['evt-x']);
      expect(b.draftRefIds, isEmpty);
      expect(b.eTagRefs, ['evt-x']);
      expect(c.draftRefIds, ['y'], reason: 'unrelated UUID untouched');
      expect(c.eTagRefs, isEmpty);
    });

    test('no referencing drafts → no-op (no writes, no publish)', () async {
      await repo.saveDraft(draft(draftId: 'lone'));
      events.calls.clear();
      final res = await repo.rewriteDraftRefs(draftUuid: 'nope', eventId: 'evt');
      expect(res.isRight(), isTrue);
      expect(events.calls, isEmpty);
    });

    test('does NOT add eventId twice if already present in eTagRefs', () async {
      await repo.saveDraft(draft(
        draftId: 'a',
        draftRefIds: ['x'],
        eTagRefs: ['evt-x'],
      ));
      await repo.rewriteDraftRefs(draftUuid: 'x', eventId: 'evt-x');
      final a = (await isar.draftModels.filter().draftIdEqualTo('a').findFirst())!;
      expect(a.eTagRefs, ['evt-x']);
    });
  });

  // ── purgePublishedTombstonesOlderThan ────────────────────────────────────

  group('purgePublishedTombstonesOlderThan', () {
    test('deletes tombstones older than the retention; keeps fresh ones + live drafts', () async {
      final now = DateTime.now();
      await isar.writeTxn(() async {
        // Fresh tombstone — should survive.
        await isar.draftModels.put(DraftModel()
          ..draftId = 't-fresh'
          ..content = ''
          ..publishedAsEventId = 'evt'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = now
          ..updatedAt = now.subtract(const Duration(days: 1)));
        // Stale tombstone — should be deleted.
        await isar.draftModels.put(DraftModel()
          ..draftId = 't-stale'
          ..content = ''
          ..publishedAsEventId = 'evt'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = now.subtract(const Duration(days: 60))
          ..updatedAt = now.subtract(const Duration(days: 60)));
        // Live draft — never touched, even if old.
        await isar.draftModels.put(DraftModel()
          ..draftId = 'live'
          ..content = 'live'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = now.subtract(const Duration(days: 60))
          ..updatedAt = now.subtract(const Duration(days: 60)));
      });

      final purged = (await repo.purgePublishedTombstonesOlderThan(
        const Duration(days: 30),
      ))
          .getOrElse(() => -1);
      expect(purged, 1);

      final remaining =
          (await isar.draftModels.where().findAll()).map((d) => d.draftId).toSet();
      expect(remaining, {'t-fresh', 'live'});
    });

    test('no tombstones → returns 0', () async {
      final purged = (await repo.purgePublishedTombstonesOlderThan(
        const Duration(days: 30),
      ))
          .getOrElse(() => -1);
      expect(purged, 0);
    });
  });

  // ── Edge cases / complex queries ──────────────────────────────────────────

  group('edge cases', () {
    test('reply draft preserves NIP-10 markers when re-saved', () async {
      await repo.saveDraft(draft(
        draftId: 'r-1',
        rootEventId: 'root',
        replyToEventId: 'parent',
        eTagRefs: ['root', 'parent'],
      ));
      final row = (await isar.draftModels.filter().draftIdEqualTo('r-1').findFirst())!;
      expect(row.rootEventId, 'root');
      expect(row.replyToEventId, 'parent');
      expect(row.eTagRefs, ['root', 'parent']);
    });

    test('chain publish path: A→B→C tombstones cascade correctly', () async {
      // C — leaf, no draftRefIds
      // B — references C
      // A — references B (and C)
      await repo.saveDraft(draft(draftId: 'C'));
      await repo.saveDraft(draft(draftId: 'B', draftRefIds: ['C']));
      await repo.saveDraft(draft(draftId: 'A', draftRefIds: ['B', 'C']));

      // Publish in topo order: C, then B, then A
      await repo.markPublished(draftId: 'C', eventId: 'evt-C');
      // After C: B and A have evt-C in eTagRefs; B.draftRefIds=[], A.draftRefIds=[B]
      var b = (await isar.draftModels.filter().draftIdEqualTo('B').findFirst())!;
      var a = (await isar.draftModels.filter().draftIdEqualTo('A').findFirst())!;
      expect(b.draftRefIds, isEmpty);
      expect(b.eTagRefs, contains('evt-C'));
      expect(a.draftRefIds, ['B']);
      expect(a.eTagRefs, contains('evt-C'));

      await repo.markPublished(draftId: 'B', eventId: 'evt-B');
      a = (await isar.draftModels.filter().draftIdEqualTo('A').findFirst())!;
      expect(a.draftRefIds, isEmpty);
      expect(a.eTagRefs, containsAll(['evt-C', 'evt-B']));
    });

    test('rewrite + republish is observed by the event queue', () async {
      await repo.saveDraft(draft(draftId: 'child'));
      await repo.saveDraft(draft(draftId: 'parent', draftRefIds: ['child']));
      events.calls.clear();
      await repo.markPublished(draftId: 'child', eventId: 'evt-child');
      // markPublished republishes the tombstone wrap for 'child' AND each
      // swept parent — so the queue must contain a 'parent' republish too.
      expect(events.calls.where((c) => c.dTag == 'parent'), isNotEmpty,
          reason: 'parent must republish so other devices pick up the rewrite');
    });
  });
}

// ── Test doubles ──────────────────────────────────────────────────────────

class _StubActiveKeys extends GetActiveUserKeysUseCase {
  _StubActiveKeys() : super(_UnusedUserRepo());

  @override
  Future<Either<Failure, UserSigningKeys>> call() async {
    return const Right(UserSigningKeys(
      privkeyHex:
          '0000000000000000000000000000000000000000000000000000000000000001',
      pubkeyHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ));
  }
}

class _UnusedUserRepo implements UserRepository {
  @override
  Future<Either<Failure, UserKeyEntity>> generateKey() => throw UnimplementedError();
  @override
  Future<Either<Failure, UserKeyEntity>> getActiveUser() => throw UnimplementedError();
  @override
  Future<Either<Failure, UserKeyEntity>> importKey(String nsec) => throw UnimplementedError();
  @override
  Future<Either<Failure, Unit>> logout() => throw UnimplementedError();
  @override
  Future<({String privkeyHex, String pubkeyHex})?> getActiveKeysHex() async => null;
}

class _EnqueueCall {
  _EnqueueCall({
    required this.kind,
    required this.content,
    required this.dTag,
  });
  final int kind;
  final String content;
  final String? dTag;
}

class _RecordingEventQueue implements EventQueueRepository {
  final List<_EnqueueCall> calls = [];
  bool shouldThrow = false;

  @override
  Future<Either<Failure, int>> enqueueSignedEvent({
    required String eventId,
    required String authorPubkey,
    required String sig,
    required int kind,
    required List<String> eTagRefs,
    String? rootEventId,
    String? replyToEventId,
    required List<String> pTagRefs,
    required List<String> tTags,
    required String content,
    required DateTime created,
    String? embeddedNoteJson,
    int? quoteKind,
    String? hTag,
    String? dTag,
    int? expirationSec,
    List<String> serverTags = const [],
    List<MediaBlobEntity> imeta = const [],
    String? reportType,
  }) async {
    if (shouldThrow) throw StateError('relay down');
    calls.add(_EnqueueCall(kind: kind, content: content, dTag: dTag));
    return const Right(1);
  }
}
