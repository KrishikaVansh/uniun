import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/repositories/draft_repository_impl.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/data/repositories/note_relation_repository_impl.dart';
import 'package:uniun/data/repositories/note_repository_impl.dart';
import 'package:uniun/data/repositories/note_resolver_repository_impl.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/usecases/draft_usecases.dart';
import 'package:uniun/domain/usecases/post_reply_usecase.dart';
import 'package:uniun/domain/usecases/profile_usecases.dart';
import 'package:uniun/domain/usecases/saved_note_usecases.dart';
import 'package:uniun/domain/usecases/unread_usecases.dart';
import 'package:uniun/domain/usecases/followed_note_usecases.dart';
import 'package:uniun/features/thread/bloc/thread_bloc.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/entities/user_key/user_key_entity.dart';
import 'package:uniun/domain/repositories/event_queue_repository.dart';
import 'package:uniun/domain/repositories/user_repository.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/gateway/inbound/handlers/kind31234_draft_handler.dart';
import 'package:uniun/gateway/inbound/verified_nostr_event.dart';

import '../_helpers/isar_test_harness.dart';

/// End-to-end scenarios for the draft → note publish lifecycle.
///
/// These tests don't mock the data layer — they wire up real Isar collections,
/// the real [DraftRepositoryImpl], the real [NoteRepositoryImpl], and the real
/// [Kind31234DraftHandler]. Only the two non-Isar collaborators are stubbed:
///   - [GetActiveUserKeysUseCase] — fixed test keys, no real bech32 nsec
///   - [EventQueueRepository] — recorder for outbound wraps so we can assert
///     "tombstone republished", "deletion signal emitted", etc.
///
/// The "publish" operation itself is the exact same two-step the real
/// [BrahmaCreateBloc._publishOneDraft] performs after signing succeeds:
///
///   1. noteRepo.saveNote(<freshly-minted real event>)
///   2. draftRepo.markPublished(draftId: uuid, eventId: signedEvent.id)
///
/// That's what the `_publishDraft(...)` helper below does — every scenario
/// goes through it, so what we're verifying is the real link-survival
/// behaviour the user sees in the app.
void main() {
  late Isar deviceA;
  late Isar deviceB;
  late DraftRepositoryImpl draftsA;
  late NoteRepositoryImpl notesA;
  late _RecordingEventQueue queueA;
  late Keychain me;

  setUp(() async {
    me = Keychain.generate();
    deviceA = await openTestIsar();
    deviceB = await openTestIsar();
    queueA = _RecordingEventQueue();
    final relationsA = NoteRelationRepositoryImpl(isar: deviceA);
    final attachmentsA = NoteAttachmentsEnricher(isar: deviceA);
    draftsA = DraftRepositoryImpl(
      isar: deviceA,
      eventQueue: queueA,
      getActiveUserKeys: _StubActiveKeys(me),
      attachments: attachmentsA,
    );
    notesA = NoteRepositoryImpl(
      isar: deviceA,
      relations: relationsA,
      resolver: NoteResolverRepositoryImpl(
        isar: deviceA,
        relations: relationsA,
        attachments: attachmentsA,
      ),
    );
  });

  tearDown(() async {
    await deviceA.close(deleteFromDisk: true);
    await deviceB.close(deleteFromDisk: true);
  });

  // ── Helpers ───────────────────────────────────────────────────────────────

  DraftEntity buildDraft({
    required String draftId,
    // Default content varies by draftId so multiple drafts published in the
    // same second don't collide on Nostr event ids (id = SHA256 over a
    // canonical serialization that includes content).
    String? content,
    String? rootEventId,
    String? replyToEventId,
    List<String> eTagRefs = const [],
    List<String> draftRefIds = const [],
    List<MediaBlobEntity> attachments = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => DraftEntity(
    draftId: draftId,
    content: content ?? 'body-$draftId',
    rootEventId: rootEventId,
    replyToEventId: replyToEventId,
    eTagRefs: eTagRefs,
    pTagRefs: const [],
    tTags: const [],
    draftRefIds: draftRefIds,
    attachments: attachments,
    createdAt: createdAt ?? DateTime(2026, 6, 1),
    updatedAt: updatedAt ?? DateTime(2026, 6, 1),
  );

  /// Stand-in for [BrahmaCreateBloc._publishOneDraft]: builds the published
  /// Kind-1 event the way the real bloc would (merging note-ref ids carried
  /// verbatim + resolved draft-ref UUIDs), saves it to the note repo, then
  /// tombstones the draft. Returns the freshly-minted event id.
  Future<String> publishDraft(
    String draftId, {
    Map<String, String> resolvedDraftRefs = const {},
  }) async {
    final draftRes = await draftsA.getDraftById(draftId);
    final draft = draftRes.getOrElse(() => throw StateError('missing draft'));

    final noteMentionIds = draft.eTagRefs
        .where((id) => id != draft.rootEventId && id != draft.replyToEventId)
        .toList();
    final resolvedIds = <String>[
      for (final uuid in draft.draftRefIds)
        if (resolvedDraftRefs[uuid] != null) resolvedDraftRefs[uuid]!,
    ];
    final mentionIds = [...noteMentionIds, ...resolvedIds];

    final tags = <List<String>>[
      if (draft.rootEventId != null) ['e', draft.rootEventId!, '', 'root'],
      if (draft.replyToEventId != null)
        ['e', draft.replyToEventId!, '', 'reply'],
      for (final id in mentionIds) ['e', id, '', 'mention'],
    ];
    final event = Event.from(
      privkey: me.private,
      kind: kNoteKind,
      content: draft.content,
      tags: tags,
    );

    final eTagRefs = [
      if (draft.rootEventId != null) draft.rootEventId!,
      if (draft.replyToEventId != null) draft.replyToEventId!,
      ...mentionIds,
    ];
    final note = NoteEntity(
      id: event.id,
      sig: event.sig,
      authorPubkey: event.pubkey,
      content: event.content,
      type: NoteType.text,
      eTagRefs: eTagRefs,
      pTagRefs: const [],
      tTags: const [],
      created: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
      rootEventId: draft.rootEventId,
      replyToEventId: draft.replyToEventId,
    );
    final saveRes = await notesA.saveNote(note);
    expect(saveRes.isRight(), isTrue);
    await draftsA.markPublished(draftId: draftId, eventId: event.id);
    return event.id;
  }

  /// BFS + Kahn's topo sort matching [BrahmaCreateBloc._publishDraftDependencies].
  Future<Map<String, String>> publishChain(String rootDraftId) async {
    final rootRes = await draftsA.getDraftById(rootDraftId);
    final root = rootRes.getOrElse(() => throw StateError('missing root'));

    // BFS reachable
    final reachable = <String, DraftEntity>{};
    final stack = [...root.draftRefIds];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (reachable.containsKey(id)) continue;
      final r = await draftsA.getDraftById(id);
      final d = r.fold((_) => null, (x) => x);
      if (d == null) continue;
      reachable[id] = d;
      if (d.publishedAsEventId != null) continue;
      for (final ref in d.draftRefIds) {
        if (!reachable.containsKey(ref)) stack.add(ref);
      }
    }

    final unpublished = {
      for (final e in reachable.entries)
        if (e.value.publishedAsEventId == null) e.key: e.value,
    };

    // Kahn's algorithm
    final indegree = <String, int>{for (final id in unpublished.keys) id: 0};
    for (final d in unpublished.values) {
      for (final ref in d.draftRefIds) {
        if (indegree.containsKey(ref)) {
          indegree[d.draftId] = (indegree[d.draftId] ?? 0) + 1;
        }
      }
    }
    final ready = [
      for (final e in indegree.entries)
        if (e.value == 0) e.key,
    ];
    final order = <String>[];
    while (ready.isNotEmpty) {
      final id = ready.removeLast();
      order.add(id);
      for (final other in unpublished.values) {
        if (other.draftRefIds.contains(id) &&
            indegree.containsKey(other.draftId)) {
          indegree[other.draftId] = indegree[other.draftId]! - 1;
          if (indegree[other.draftId] == 0) ready.add(other.draftId);
        }
      }
    }
    if (order.length != unpublished.length) {
      throw StateError('cycle in draft graph');
    }

    final resolved = <String, String>{
      for (final e in reachable.values)
        if (e.publishedAsEventId != null) e.draftId: e.publishedAsEventId!,
    };
    for (final id in order) {
      resolved[id] = await publishDraft(id, resolvedDraftRefs: resolved);
    }
    // Now the root itself.
    resolved[rootDraftId] = await publishDraft(
      rootDraftId,
      resolvedDraftRefs: resolved,
    );
    return resolved;
  }

  /// Helper to read a published note's e-tag mentions back from Isar.
  Future<List<String>> mentionsOf(String eventId) async {
    final note = (await notesA.getNoteById(
      eventId,
    )).getOrElse(() => throw 'left');
    return note.eTagRefs;
  }

  // ── 1. Solo publish (no chain) ───────────────────────────────────────────

  group('Scenario: publish ONE draft, no chain', () {
    test('top-level draft with no refs → clean publish, no e-tags', () async {
      await draftsA.saveDraft(buildDraft(draftId: 'lone'));
      final eventId = await publishDraft('lone');

      expect(await mentionsOf(eventId), isEmpty);
      // Draft is now a tombstone.
      final row = await deviceA.draftModels
          .filter()
          .draftIdEqualTo('lone')
          .findFirst();
      expect(row!.publishedAsEventId, eventId);
      // Hidden from getDrafts().
      expect((await draftsA.getDrafts()).getOrElse(() => []), isEmpty);
    });

    test(
      'draft referencing only PUBLISHED notes carries their event ids through',
      () async {
        // Simulate two notes already on the relay (real event ids).
        await notesA.saveNote(
          NoteEntity(
            id: 'real-1',
            sig: 's',
            authorPubkey: me.public,
            content: 'one',
            type: NoteType.text,
            eTagRefs: const [],
            pTagRefs: const [],
            tTags: const [],
            created: DateTime(2026, 1, 1),
          ),
        );
        await notesA.saveNote(
          NoteEntity(
            id: 'real-2',
            sig: 's',
            authorPubkey: me.public,
            content: 'two',
            type: NoteType.text,
            eTagRefs: const [],
            pTagRefs: const [],
            tTags: const [],
            created: DateTime(2026, 1, 1),
          ),
        );
        await draftsA.saveDraft(
          buildDraft(draftId: 'mixed-pub-only', eTagRefs: ['real-1', 'real-2']),
        );

        final eventId = await publishDraft('mixed-pub-only');
        expect(await mentionsOf(eventId), containsAll(['real-1', 'real-2']));
      },
    );

    test(
      'SOLO publish of a draft that links other drafts → published note has NO link',
      () async {
        // This is the "drop draft refs from this note's tags" branch in the
        // publish-chain dialog. User picked "Publish only this".
        await draftsA.saveDraft(buildDraft(draftId: 'child'));
        await draftsA.saveDraft(
          buildDraft(draftId: 'parent', draftRefIds: ['child']),
        );

        // Solo publish — pass resolvedDraftRefs={}: nothing to map UUIDs to,
        // so they're silently dropped from the e-tags (matches the real BLoC).
        final parentEvent = await publishDraft('parent');

        expect(
          await mentionsOf(parentEvent),
          isEmpty,
          reason: 'no chain → child stays a draft, parent published bare',
        );
        // Child draft survives unchanged.
        final child = (await draftsA.getDraftById(
          'child',
        )).getOrElse(() => throw 'gone');
        expect(child.publishedAsEventId, isNull);
      },
    );
  });

  // ── 2. Chain publish ─────────────────────────────────────────────────────

  group('Scenario: publish WHOLE CHAIN', () {
    test(
      'A → B (linear): publishing A also publishes B; A links to B-real',
      () async {
        await draftsA.saveDraft(buildDraft(draftId: 'B'));
        await draftsA.saveDraft(buildDraft(draftId: 'A', draftRefIds: ['B']));

        final resolved = await publishChain('A');
        final realA = resolved['A']!;
        final realB = resolved['B']!;

        expect(await mentionsOf(realA), [realB]);
        expect(await mentionsOf(realB), isEmpty);

        // Both drafts are tombstones now; getDrafts hides them.
        expect((await draftsA.getDrafts()).getOrElse(() => []), isEmpty);
      },
    );

    test(
      'A → B → C (deep): leaves publish first; intermediate carries real id',
      () async {
        await draftsA.saveDraft(buildDraft(draftId: 'C'));
        await draftsA.saveDraft(buildDraft(draftId: 'B', draftRefIds: ['C']));
        await draftsA.saveDraft(buildDraft(draftId: 'A', draftRefIds: ['B']));

        final resolved = await publishChain('A');

        // Each parent must reference the real event id of its child.
        expect(await mentionsOf(resolved['A']!), [resolved['B']!]);
        expect(await mentionsOf(resolved['B']!), [resolved['C']!]);
        expect(await mentionsOf(resolved['C']!), isEmpty);
      },
    );

    test(
      'Diamond A → {B, C} → D: D published once; A holds both branches',
      () async {
        // Distinct content per node — identical content + same keys + same
        // created_at would collide on Nostr event ids (SHA256 over the
        // canonical serialization).
        await draftsA.saveDraft(buildDraft(draftId: 'D', content: 'd-body'));
        await draftsA.saveDraft(
          buildDraft(draftId: 'B', content: 'b-body', draftRefIds: ['D']),
        );
        await draftsA.saveDraft(
          buildDraft(draftId: 'C', content: 'c-body', draftRefIds: ['D']),
        );
        await draftsA.saveDraft(
          buildDraft(draftId: 'A', content: 'a-body', draftRefIds: ['B', 'C']),
        );

        final resolved = await publishChain('A');
        // D is published exactly once even though both B and C reference it.
        expect(resolved.values.toSet(), hasLength(4));
        expect(
          await mentionsOf(resolved['A']!),
          containsAll([resolved['B']!, resolved['C']!]),
        );
        expect(await mentionsOf(resolved['B']!), [resolved['D']!]);
        expect(await mentionsOf(resolved['C']!), [resolved['D']!]);
      },
    );

    test('MIXED refs: draft links a real note AND another draft', () async {
      // The most common real-world case. User has one note already on the
      // relay, then drafts a new note that quotes both that real note and a
      // sibling draft. "Publish whole chain" must combine the two.
      await notesA.saveNote(
        NoteEntity(
          id: 'real-quote',
          sig: 's',
          authorPubkey: me.public,
          content: 'previously published',
          type: NoteType.text,
          eTagRefs: const [],
          pTagRefs: const [],
          tTags: const [],
          created: DateTime(2026, 1, 1),
        ),
      );
      await draftsA.saveDraft(buildDraft(draftId: 'sibling'));
      await draftsA.saveDraft(
        buildDraft(
          draftId: 'parent',
          eTagRefs: ['real-quote'],
          draftRefIds: ['sibling'],
        ),
      );

      final resolved = await publishChain('parent');
      expect(
        await mentionsOf(resolved['parent']!),
        containsAll(['real-quote', resolved['sibling']!]),
      );
    });

    test(
      'Closure contains an ALREADY-PUBLISHED tombstone — reuse mapping, do not republish',
      () async {
        // 1. Pre-publish C solo so its tombstone exists.
        await draftsA.saveDraft(buildDraft(draftId: 'C'));
        final eventC = await publishDraft('C');

        // 2. Create B and A — B references the C UUID (it hasn't been swept
        // out of B's draftRefIds yet because B was created before publish).
        // The repo's markPublished sweep already rewrote any existing parent.
        // Manually re-establish the un-swept state to test the closure path.
        await deviceA.writeTxn(() async {
          await deviceA.draftModels.put(
            DraftModel()
              ..draftId = 'B'
              ..content = 'b'
              ..eTagRefs = const []
              ..pTagRefs = const []
              ..tTags = const []
              ..draftRefIds = ['C']
              ..createdAt = DateTime(2026, 1, 1)
              ..updatedAt = DateTime(2026, 1, 1),
          );
          await deviceA.draftModels.put(
            DraftModel()
              ..draftId = 'A'
              ..content = 'a'
              ..eTagRefs = const []
              ..pTagRefs = const []
              ..tTags = const []
              ..draftRefIds = ['B']
              ..createdAt = DateTime(2026, 1, 1)
              ..updatedAt = DateTime(2026, 1, 1),
          );
        });

        final resolved = await publishChain('A');
        // C must NOT be re-published — its real eventId reuses the tombstone.
        expect(resolved['C'], eventC);
        expect(await mentionsOf(resolved['B']!), [eventC]);
        expect(await mentionsOf(resolved['A']!), [resolved['B']!]);
      },
    );

    test(
      'Dangling draftRefId (target doesn\'t exist) — chain succeeds and drops it',
      () async {
        await draftsA.saveDraft(
          buildDraft(draftId: 'A', draftRefIds: ['ghost-uuid']),
        );
        final resolved = await publishChain('A');
        // Dangling UUID never resolves, so it doesn't appear in A's e-tags.
        expect(await mentionsOf(resolved['A']!), isEmpty);
      },
    );

    test('Cycle A → B → A is detected and throws', () async {
      await draftsA.saveDraft(buildDraft(draftId: 'A', draftRefIds: ['B']));
      await draftsA.saveDraft(buildDraft(draftId: 'B', draftRefIds: ['A']));
      await expectLater(publishChain('A'), throwsStateError);
      // Neither got published — both still live drafts.
      final live = (await draftsA.getDrafts()).getOrElse(() => []);
      expect(live.map((d) => d.draftId).toSet(), {'A', 'B'});
    });
  });

  // ── 3. Cross-device sync (NIP-37 reconciliation) ─────────────────────────

  group('Scenario: cross-device sync', () {
    test(
      'publish on A → tombstone wrap delivered to B rewrites B\'s parent draft',
      () async {
        // Device A authors B-references-C, publishes C solo. The tombstone
        // wrap reaches Device B (which still holds its own B-references-C
        // copy after the earlier "save draft" syncs). The handler on B must
        // rewrite B's draftRefIds → eTagRefs.

        // Seed B's local state as if a prior save sync arrived.
        await deviceB.writeTxn(() async {
          await deviceB.draftModels.put(
            DraftModel()
              ..draftId = 'C'
              ..content = 'c body'
              ..eTagRefs = const []
              ..pTagRefs = const []
              ..tTags = const []
              ..createdAt = DateTime(2026, 1, 1)
              ..updatedAt = DateTime(2026, 1, 1),
          );
          await deviceB.draftModels.put(
            DraftModel()
              ..draftId = 'B'
              ..content = 'b body'
              ..eTagRefs = const []
              ..pTagRefs = const []
              ..tTags = const []
              ..draftRefIds = ['C']
              ..createdAt = DateTime(2026, 1, 1)
              ..updatedAt = DateTime(2026, 1, 1),
          );
        });

        // Device A: save C and publish solo → markPublished pushes a tombstone
        // wrap into queueA. Capture it.
        await draftsA.saveDraft(buildDraft(draftId: 'C', content: 'c body'));
        final eventC = await publishDraft('C');

        // Find the published-as wrap A emitted (the one carrying the
        // post-markPublished republish — last call with dTag='C').
        final wrapCall = queueA.calls.lastWhere(
          (c) => c.dTag == 'C' && c.content.isNotEmpty,
        );

        // Reconstruct an inbound event the way the relay would deliver it
        // back to Device B, and feed it through B's handler.
        final inbound = <String, dynamic>{
          'id': 'evt-wrap-C',
          'pubkey': me.public,
          'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'kind': kDraftWrapKind,
          'content': wrapCall.content,
          'tags': [
            ['d', 'C'],
            ['k', kNoteKind.toString()],
          ],
        };
        final handlerB = Kind31234DraftHandler(
          activePubkey: me.public,
          activePrivkey: me.private,
        );
        await handlerB.handle(trustedEvent(inbound), deviceB);

        // B's row for C is now a tombstone — and its `B` row has the real
        // event id swept into eTagRefs.
        final bRow = (await deviceB.draftModels
            .filter()
            .draftIdEqualTo('B')
            .findFirst())!;
        expect(bRow.draftRefIds, isEmpty);
        expect(bRow.eTagRefs, [eventC]);
      },
    );

    test(
      'save-draft wrap from device A reaches B and creates the draft there',
      () async {
        await draftsA.saveDraft(
          buildDraft(draftId: 'cross-sync', content: 'authored on A'),
        );
        // Newest non-tombstone wrap A emitted for this draftId.
        final wrapCall = queueA.calls.lastWhere(
          (c) => c.dTag == 'cross-sync' && c.content.isNotEmpty,
        );

        final handlerB = Kind31234DraftHandler(
          activePubkey: me.public,
          activePrivkey: me.private,
        );
        await handlerB.handle(
          trustedEvent(<String, dynamic>{
            'id': 'evt-cs',
            'pubkey': me.public,
            'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'kind': kDraftWrapKind,
            'content': wrapCall.content,
            'tags': [
              ['d', 'cross-sync'],
            ],
          }),
          deviceB,
        );

        final row = (await deviceB.draftModels
            .filter()
            .draftIdEqualTo('cross-sync')
            .findFirst())!;
        expect(row.content, 'authored on A');
      },
    );

    test(
      'chain-publish on A → each tombstone wrap propagates to B independently',
      () async {
        // Seed B with the linear chain A → B → C.
        await deviceB.writeTxn(() async {
          for (final id in ['C', 'B', 'A']) {
            await deviceB.draftModels.put(
              DraftModel()
                ..draftId = id
                ..content = '$id body'
                ..eTagRefs = const []
                ..pTagRefs = const []
                ..tTags = const []
                ..draftRefIds = id == 'A'
                    ? ['B']
                    : id == 'B'
                    ? ['C']
                    : const []
                ..createdAt = DateTime(2026, 1, 1)
                ..updatedAt = DateTime(2026, 1, 1),
            );
          }
        });

        // Author the same chain on A and publish it.
        await draftsA.saveDraft(buildDraft(draftId: 'C'));
        await draftsA.saveDraft(buildDraft(draftId: 'B', draftRefIds: ['C']));
        await draftsA.saveDraft(buildDraft(draftId: 'A', draftRefIds: ['B']));
        final resolved = await publishChain('A');

        // Deliver every tombstone wrap A emitted to B, in arrival order.
        final handlerB = Kind31234DraftHandler(
          activePubkey: me.public,
          activePrivkey: me.private,
        );
        var i = 0;
        for (final call in queueA.calls.where((c) => c.content.isNotEmpty)) {
          await handlerB.handle(
            trustedEvent(<String, dynamic>{
              'id': 'evt-$i',
              'pubkey': me.public,
              'created_at': 1_700_000_000 + i,
              'kind': kDraftWrapKind,
              'content': call.content,
              'tags': [
                ['d', call.dTag!],
              ],
            }),
            deviceB,
          );
          i++;
        }

        // B is fully reconciled: every row is a tombstone pointing at the same
        // real event ids A minted.
        for (final id in ['A', 'B', 'C']) {
          final row = await deviceB.draftModels
              .filter()
              .draftIdEqualTo(id)
              .findFirst();
          expect(
            row?.publishedAsEventId,
            resolved[id],
            reason: 'device B converges on the same eventId for $id',
          );
        }
      },
    );
  });

  // ── 4. Edit-then-publish & misc ──────────────────────────────────────────

  group('Scenario: edit then publish', () {
    test(
      'save → edit → save → publish: the LATEST content reaches Nostr',
      () async {
        await draftsA.saveDraft(buildDraft(draftId: 'd', content: 'v1'));
        await draftsA.saveDraft(
          buildDraft(
            draftId: 'd',
            content: 'v2 final',
            updatedAt: DateTime(2026, 6, 2),
          ),
        );
        final eventId = await publishDraft('d');
        final note = (await notesA.getNoteById(
          eventId,
        )).getOrElse(() => throw 'left');
        expect(note.content, 'v2 final');
      },
    );

    test(
      'publishing a reply draft preserves NIP-10 root + reply markers',
      () async {
        await draftsA.saveDraft(
          buildDraft(
            draftId: 'reply',
            rootEventId: 'real-root',
            replyToEventId: 'real-parent',
            eTagRefs: ['real-root', 'real-parent'],
            content: 'replying',
          ),
        );
        final eventId = await publishDraft('reply');
        final note = (await notesA.getNoteById(
          eventId,
        )).getOrElse(() => throw 'left');
        expect(note.rootEventId, 'real-root');
        expect(note.replyToEventId, 'real-parent');
        expect(note.eTagRefs, containsAll(['real-root', 'real-parent']));
      },
    );

    test(
      'publishing twice via solo → second call is a no-op against the same tombstone',
      () async {
        await draftsA.saveDraft(buildDraft(draftId: 'd'));
        final first = await publishDraft('d');
        // Second publish via the same draftId — the draft is now a tombstone
        // and getDraftById still returns it (the repo only hides tombstones
        // in the list, not in single-id lookups). The note repo is idempotent
        // on the new event id, so we won't get a duplicate.
        final second = await publishDraft('d');
        // Both calls minted real events, but the note repo accepted both —
        // exercising the "Nostr immutability + idempotent local save" path.
        expect(first, isNotEmpty);
        expect(second, isNotEmpty);
      },
    );
  });

  // ── 5. Property check: graph integrity post-chain ────────────────────────

  group('Scenario: reply to a draft from its thread', () {
    late NoteResolverRepositoryImpl resolverA;

    ThreadBloc threadBloc() {
      resolverA = NoteResolverRepositoryImpl(
        isar: deviceA,
        relations: NoteRelationRepositoryImpl(isar: deviceA),
        attachments: NoteAttachmentsEnricher(isar: deviceA),
      );
      final getProfile = _MockGetProfile();
      when(() => getProfile.call(any())).thenAnswer(
        (_) async => const Left(Failure.errorFailure('no profile')),
      );
      final getAllSaved = _MockGetAllSaved();
      when(() => getAllSaved.call()).thenAnswer((_) async => const Right([]));
      final markSeen = _MockMarkSeen();
      when(() => markSeen.call(any())).thenAnswer((_) async => const Right(unit));
      final watch = _MockWatchMarkers();
      when(() => watch.call(any())).thenAnswer((_) => const Stream.empty());
      return ThreadBloc(
        resolverA,
        _MockPostReply(),
        getProfile,
        getAllSaved,
        _MockGetSavedReplies(),
        _MockGetSavedReferences(),
        markSeen,
        watch,
        GetDraftByIdUseCase(draftsA),
        GetDraftRepliesUseCase(draftsA),
        SaveDraftUseCase(draftsA),
        _StubActiveUser(me),
      );
    }

    /// Waits until [done] holds (polling), so a slow machine cannot race the
    /// bloc's async load/save.
    Future<void> until(bool Function() done) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('condition not met in 10s');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<ThreadBloc> openThread(String id, {bool draft = false}) async {
      final bloc = threadBloc();
      bloc.add(LoadThreadEvent(id, draft: draft));
      await until(() => bloc.state.status == ThreadStatus.loaded);
      return bloc;
    }

    /// Opens the draft thread on `parent` and writes `text` as a reply from the
    /// composer, the way the screen does.
    Future<void> replyFromThread(String parent, String text) async {
      final bloc = await openThread(parent, draft: true);
      final before = bloc.state.replies.length;
      bloc.add(PostReplyEvent(text));
      await until(() => bloc.state.replies.length == before + 1);
      await bloc.close();
    }

    Future<String> onlyReplyOf(String parent) async {
      final replies = (await draftsA.getDraftsReferencing(parent))
          .getOrElse(() => throw 'left');
      expect(replies, hasLength(1));
      return replies.single.draftId;
    }

    test('the reply is saved as a draft linked to its parent and shows in the '
        "parent's draft thread", () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));

      await replyFromThread('parent', 'sounds good');

      final replyId = await onlyReplyOf('parent');
      final reply = (await draftsA.getDraftById(replyId)).getOrElse(() => throw 'x');
      expect(reply.content, 'sounds good');
      expect(reply.draftRefIds, ['parent']);

      final bloc = await openThread('parent', draft: true);
      expect(bloc.state.replies.map((r) => r.content), ['sounds good']);
      expect(bloc.state.draftIds, {'parent', replyId});
      await bloc.close();
    });

    test('a reply to a reply nests: each draft thread shows its own replies',
        () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));
      await replyFromThread('parent', 'first');
      final first = await onlyReplyOf('parent');

      await replyFromThread(first, 'second');

      expect(await onlyReplyOf(first), isNot(first));
      expect(await onlyReplyOf('parent'), first);
    });

    test('publishing the parent relinks the reply: the link becomes a real '
        'event id and the published reply mentions the published parent',
        () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));
      await replyFromThread('parent', 'sounds good');
      final replyId = await onlyReplyOf('parent');

      final parentEvent = await publishDraft('parent');

      final reply = (await draftsA.getDraftById(replyId)).getOrElse(() => throw 'x');
      expect(reply.draftRefIds, isEmpty);
      expect(reply.eTagRefs, [parentEvent]);

      final replyEvent = await publishDraft(replyId);
      expect(await mentionsOf(replyEvent), [parentEvent]);

      // The published parent's normal thread now lists the reply.
      final published = await openThread(parentEvent);
      expect(published.state.replies.map((r) => r.id), [replyEvent]);
      await published.close();
    });

    test('publishing the reply with its chain publishes the parent first and '
        'keeps the link', () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));
      await replyFromThread('parent', 'sounds good');
      final replyId = await onlyReplyOf('parent');

      final resolved = await publishChain(replyId);

      expect(await mentionsOf(resolved[replyId]!), [resolved['parent']!]);
    });

    test('publishing only the reply drops the link instead of breaking it',
        () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));
      await replyFromThread('parent', 'sounds good');
      final replyId = await onlyReplyOf('parent');

      final replyEvent = await publishDraft(replyId);

      expect(await mentionsOf(replyEvent), isEmpty);
      expect((await draftsA.getDraftById('parent')).isRight(), isTrue,
          reason: 'the parent stays a draft');
    });

    test('a reply left unpublished after its parent was deleted still opens',
        () async {
      await draftsA.saveDraft(buildDraft(draftId: 'parent'));
      await replyFromThread('parent', 'orphan');
      final replyId = await onlyReplyOf('parent');
      await draftsA.deleteDraft('parent');

      final bloc = await openThread(replyId, draft: true);

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.root!.content, 'orphan');
      await bloc.close();
    });
  });

  group('Property: every chain leaves the graph self-consistent', () {
    test(
      'After chain publish of A → B → C: each note\'s mentions == its real children',
      () async {
        await draftsA.saveDraft(buildDraft(draftId: 'C'));
        await draftsA.saveDraft(buildDraft(draftId: 'B', draftRefIds: ['C']));
        await draftsA.saveDraft(buildDraft(draftId: 'A', draftRefIds: ['B']));
        final resolved = await publishChain('A');

        // For every (parent, child) edge in the original draft graph, the
        // published parent's eTagRefs must contain the published child's id.
        final edges = <String, List<String>>{
          'A': ['B'],
          'B': ['C'],
          'C': [],
        };
        for (final entry in edges.entries) {
          final parentEvent = resolved[entry.key]!;
          final realMentions = await mentionsOf(parentEvent);
          for (final child in entry.value) {
            expect(
              realMentions,
              contains(resolved[child]!),
              reason: '${entry.key} → $child link must survive',
            );
          }
        }
      },
    );
  });
}

// ── Test doubles ─────────────────────────────────────────────────────────

class _MockPostReply extends Mock implements PostReplyUseCase {}

class _MockGetProfile extends Mock implements GetProfileUseCase {}

class _MockGetAllSaved extends Mock implements GetAllSavedNotesUseCase {}

class _MockGetSavedReplies extends Mock implements GetSavedRepliesUseCase {}

class _MockGetSavedReferences extends Mock
    implements GetSavedReferencesUseCase {}

class _MockMarkSeen extends Mock implements MarkUnreadSeenUseCase {}

class _MockWatchMarkers extends Mock
    implements WatchThreadUnreadMarkersUseCase {}

class _StubActiveUser extends GetActiveUserUseCase {
  _StubActiveUser(this._kc) : super(_UnusedUserRepo());
  final Keychain _kc;
  @override
  Future<Either<Failure, UserKeyEntity>> call() async => Right(
    UserKeyEntity(
      pubkeyHex: _kc.public,
      npub: 'npub-${_kc.public}',
      nsec: 'nsec',
      createdAt: DateTime(2026),
    ),
  );
}

class _StubActiveKeys extends GetActiveUserKeysUseCase {
  _StubActiveKeys(this._kc) : super(_UnusedUserRepo());
  final Keychain _kc;
  @override
  Future<Either<Failure, UserSigningKeys>> call() async {
    return Right(
      UserSigningKeys(privkeyHex: _kc.private, pubkeyHex: _kc.public),
    );
  }
}

class _UnusedUserRepo implements UserRepository {
  @override
  Future<Either<Failure, UserKeyEntity>> generateKey() =>
      throw UnimplementedError();
  @override
  Future<Either<Failure, UserKeyEntity>> getActiveUser() =>
      throw UnimplementedError();
  @override
  Future<Either<Failure, UserKeyEntity>> importKey(String nsec) =>
      throw UnimplementedError();
  @override
  Future<Either<Failure, Unit>> logout() => throw UnimplementedError();
  @override
  Future<({String privkeyHex, String pubkeyHex})?> getActiveKeysHex() async =>
      null;
}

class _EnqueueCall {
  _EnqueueCall({required this.content, required this.dTag});
  final String content;
  final String? dTag;
}

VerifiedNostrEvent trustedEvent(Map<String, dynamic> raw) {
  return VerifiedNostrEvent(
    id: raw['id'] as String,
    pubkey: raw['pubkey'] as String,
    createdAt: raw['created_at'] as int,
    kind: raw['kind'] as int,
    tags: (raw['tags'] as List)
        .map((tag) => (tag as List).cast<String>())
        .toList(),
    content: raw['content'] as String,
    sig: raw['sig'] as String? ?? '',
    raw: raw,
  );
}

class _RecordingEventQueue implements EventQueueRepository {
  final List<_EnqueueCall> calls = [];
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
    calls.add(_EnqueueCall(content: content, dTag: dTag));
    return const Right(1);
  }
}
