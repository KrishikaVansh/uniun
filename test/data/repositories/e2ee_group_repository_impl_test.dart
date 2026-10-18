import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/encrypted_message_model.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/media/media_cache_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/private_group_join_request_model.dart';
import 'package:uniun/data/models/private_group_model.dart';
import 'package:uniun/data/repositories/e2ee_group_repository_impl.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/data/repositories/note_relation_repository_impl.dart';
import 'package:uniun/domain/entities/event_queue/queued_event_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/repositories/note_relation_repository.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';

/// Covers: E2EEGroupRepositoryImpl group CRUD + watch streams, private-group
/// message scoping with attachment cache enrichment, and the pending
/// join-request queue (unhandled-only, timestamp order).
void main() {
  late Isar isar;
  late E2EEGroupRepositoryImpl repo;

  setUp(() async {
    isar = await openTestIsar();
    repo = E2EEGroupRepositoryImpl(
      isar,
      NoteAttachmentsEnricher(isar: isar),
      NoteRelationRepositoryImpl(isar: isar),
      MeshEventSigner.fixed(privkeyHex: kTestPrivHex, pubkeyHex: kTestPubHex),
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  group('groups', () {
    test('saveGroup / getGroups round-trips every field', () async {
      await repo.saveGroup(aPrivateGroup(
        groupId: 'pg-1',
        name: 'Secret',
        description: 'the inner circle',
        relays: ['wss://r1'],
        adminPubkey: kAlicePub,
      ));

      final groups = await repo.getGroups();
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.groupId, 'pg-1');
      expect(g.mlsGroupId, 'mls_pg-1');
      expect(g.name, 'Secret');
      expect(g.description, 'the inner circle');
      expect(g.relays, ['wss://r1']);
      expect(g.adminPubkey, kAlicePub);
    });

    test('saveGroup with the entity\'s Isar id updates in place', () async {
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-1', name: 'v1'));
      final existing = (await repo.getGroups()).single;

      await repo.saveGroup(aPrivateGroup(
          id: existing.id, groupId: 'pg-1', name: 'v2'));

      final rows = await isar.privateGroupModels.where().findAll();
      expect(rows, hasLength(1));
      expect(rows.single.name, 'v2');
    });

    test('deleteGroup removes only the targeted group', () async {
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-1'));
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-2'));

      await repo.deleteGroup('pg-1');

      expect((await repo.getGroups()).map((g) => g.groupId), ['pg-2']);
      // Deleting an unknown id is a no-op, not an error.
      await repo.deleteGroup('nope');
      expect(await isar.privateGroupModels.count(), 1);
    });

    test('watchGroups fires immediately with current state, then on change',
        () async {
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-1'));

      final emissions = repo.watchGroups().take(2).toList();
      // Trigger the second emission after the watcher is attached.
      await Future<void>.delayed(Duration.zero);
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-2'));

      final frames = await emissions;
      expect(frames.first.map((g) => g.groupId), ['pg-1']);
      expect(frames.last.map((g) => g.groupId).toSet(), {'pg-1', 'pg-2'});
    });
  });

  group('messages', () {
    test('only this group\'s Kind-9023 rows, oldest first — other private '
        'groups, public groups and feed notes stay invisible', () async {
      await seedNoteRow(isar, 'pm-2',
          kind: kPrivateGroupKind,
          privateGroupId: 'pg-1',
          created: tNow.add(const Duration(minutes: 1)));
      await seedNoteRow(isar, 'pm-1',
          kind: kPrivateGroupKind, privateGroupId: 'pg-1', created: tNow);
      await seedNoteRow(isar, 'other-group',
          kind: kPrivateGroupKind, privateGroupId: 'pg-2');
      await seedNoteRow(isar, 'public-group',
          kind: kGroupMessageKind, groupId: 'pg-1');
      await seedNoteRow(isar, 'feed-note');

      final msgs = await repo.getMessages('pg-1');
      expect(msgs.map((e) => e.id).toList(), ['pm-1', 'pm-2']);
      expect(msgs.first.sourcePrivateGroupId, 'pg-1');
    });

    test('attachment cache state is joined onto returned messages', () async {
      await seedNoteRow(isar, 'pm-media',
          kind: kPrivateGroupKind,
          privateGroupId: 'pg-1',
          attachments: [mediaAttachmentRow(sha256: 'sha-img')]);
      await isar.writeTxn(() async {
        await isar.mediaCacheModels
            .put(mediaCacheRow('sha-img', localPath: '/data/media/sha-img.jpg'));
      });

      final msg = (await repo.getMessages('pg-1')).single;
      expect(msg.attachments.single.localPath, '/data/media/sha-img.jpg');
    });

    test('watchMessages emits the enriched list when a message lands',
        () async {
      final emissions = repo.watchMessages('pg-1').take(2).toList();
      await Future<void>.delayed(Duration.zero);
      await seedNoteRow(isar, 'pm-1',
          kind: kPrivateGroupKind, privateGroupId: 'pg-1');

      final frames = await emissions;
      expect(frames.first, isEmpty);
      expect(frames.last.map((e) => e.id), ['pm-1']);
    });

    test('unicode content round-trips intact', () async {
      await seedNoteRow(isar, 'pm-uni',
          kind: kPrivateGroupKind,
          privateGroupId: 'pg-1',
          content: Content.emoji);
      expect((await repo.getMessages('pg-1')).single.content, Content.emoji);
    });
  });

  group('join requests', () {
    test('returns only UNHANDLED requests for the group, oldest first',
        () async {
      await isar.writeTxn(() async {
        await isar.privateGroupJoinRequestModels.putAll([
          joinRequestRow('req-late',
              groupId: 'pg-1', timestamp: tNow.add(const Duration(hours: 1))),
          joinRequestRow('req-early', groupId: 'pg-1', timestamp: tNow),
          joinRequestRow('req-done',
              groupId: 'pg-1', handled: true, timestamp: tT0),
          joinRequestRow('req-other', groupId: 'pg-2'),
        ]);
      });

      final pending = await repo.getJoinRequests('pg-1');
      expect(pending.map((r) => r.eventId).toList(),
          ['req-early', 'req-late']);
      expect(pending.first.keyPackageB64, 'a2V5cGFja2FnZQ==');
    });

    test('watchJoinRequests drops a request from the stream once handled',
        () async {
      await isar.writeTxn(() async {
        await isar.privateGroupJoinRequestModels
            .put(joinRequestRow('req-1', groupId: 'pg-1'));
      });

      final emissions = repo.watchJoinRequests('pg-1').take(2).toList();
      await Future<void>.delayed(Duration.zero);
      await isar.writeTxn(() async {
        final row = (await isar.privateGroupJoinRequestModels
            .where()
            .eventIdEqualTo('req-1')
            .findFirst())!;
        row.handled = true;
        await isar.privateGroupJoinRequestModels.put(row);
      });

      final frames = await emissions;
      expect(frames.first.map((r) => r.eventId), ['req-1']);
      expect(frames.last, isEmpty);
    });
  });

  group('Marmot transport storage', () {
    EncryptedMessageModel pending(String eventId, {int kind = 9023, String groupId = 'pg-1'}) =>
        EncryptedMessageModel()
          ..eventId = eventId
          ..groupId = groupId
          ..senderPubkey = kBobPub
          ..kind = kind
          ..encryptedPayload = 'payload-$eventId'
          ..timestamp = DateTime(2026, 1, 2);

    QueuedEventEntity queued(String id, {int kind = 9023, String? hTag = 'pg-1'}) =>
        QueuedEventEntity(
          eventId: id,
          kind: kind,
          content: 'content-$id',
          authorPubkey: kAlicePub,
          sig: 'sig-$id',
          created: DateTime(2026, 1, 3),
          hTag: hTag,
        );

    Future<int> seedPending(String eventId, {int kind = 9023}) => isar
        .writeTxn(() => isar.encryptedMessageModels.put(pending(eventId, kind: kind)));

    group('queue', () {
      test('findGroup maps the stored group, null when absent', () async {
        await repo.saveGroup(aPrivateGroup(groupId: 'pg-1'));

        expect((await repo.findGroup('pg-1'))!.mlsGroupId, 'mls_pg-1');
        expect(await repo.findGroup('nope'), isNull);
      });

      test('pendingMessages maps every field of the queued rows', () async {
        await seedPending('m1', kind: 9025);

        final m = (await repo.pendingMessages()).single;

        expect(m.eventId, 'm1');
        expect(m.groupId, 'pg-1');
        expect(m.senderPubkey, kBobPub);
        expect(m.kind, 9025);
        expect(m.encryptedPayload, 'payload-m1');
        expect(m.timestamp, DateTime(2026, 1, 2));
      });

      test('watchPendingMessages fires when a message is queued', () async {
        final fired = repo.watchPendingMessages().first;
        await seedPending('m1');
        await fired.timeout(const Duration(seconds: 5));
      });

      test('discardPendingMessage removes only that row', () async {
        final keep = await seedPending('keep');
        final drop = await seedPending('drop');

        await repo.discardPendingMessage(drop);
        await repo.discardPendingMessage(9999);

        expect((await repo.pendingMessages()).map((m) => m.id), [keep]);
      });
    });

    group('confirmWelcome', () {
      test('binds the MLS id, clears a tombstone, re-signs and consumes the '
          'event atomically', () async {
        await isar.writeTxn(() => isar.privateGroupModels.put(
            privateGroupSeed('pg-1')
              ..mlsGroupId = ''
              ..removedAt = DateTime(2026)));
        final id = await seedPending('welcome', kind: 9024);

        final ok = await repo.confirmWelcome(
            pendingId: id, groupId: 'pg-1', mlsGroupId: 'mls-new');

        expect(ok, isTrue);
        final row = (await isar.privateGroupModels.where().findFirst())!;
        expect(row.mlsGroupId, 'mls-new');
        expect(row.removedAt, isNull);
        expect(row.signedNostrEvent, isNotNull);
        expect(await isar.encryptedMessageModels.count(), 0);
      });

      test('an unknown group returns false and leaves the event queued',
          () async {
        final id = await seedPending('welcome', kind: 9024);

        final ok = await repo.confirmWelcome(
            pendingId: id, groupId: 'pg-1', mlsGroupId: 'mls-new');

        expect(ok, isFalse);
        expect(await isar.encryptedMessageModels.count(), 1);
        expect(await isar.privateGroupModels.count(), 0);
      });
    });

    group('saveDecryptedMessage', () {
      NoteEntity incoming(String id) => aNote(
            id: id,
            authorPubkey: kBobPub,
            kind: kPrivateGroupKind,
          ).copyWith(sourcePrivateGroupId: 'pg-1', sig: '');

      test('stores a new message unread, with its attachments, and consumes '
          'the event', () async {
        final pid = await seedPending('m1');

        await repo.saveDecryptedMessage(
          pendingId: pid,
          message: incoming('m1').copyWith(
            content: 'नमस्ते 🌍',
            attachments: [aMediaBlob(sha256: 'sha-1')],
          ),
        );

        final note = (await isar.noteModels.where().findFirst())!;
        expect(note.privateGroupId, 'pg-1');
        expect(note.content, 'नमस्ते 🌍');
        expect(note.attachments.single.sha256, 'sha-1');
        expect(await isar.unreadNoteModels.count(), 1);
        expect(await isar.encryptedMessageModels.count(), 0);
      });

      test('a message already stored is refused by the unique event id and '
          'the event stays queued', () async {
        final msg = incoming('m1');
        await repo.sendMessage(message: msg, event: queued('m1'));
        final pid = await seedPending('m1');

        await expectLater(
          repo.saveDecryptedMessage(pendingId: pid, message: msg),
          throwsA(anything),
        );

        expect(await isar.noteModels.count(), 1);
        expect(await isar.unreadNoteModels.count(), 0);
        expect(await isar.encryptedMessageModels.count(), 1);
      });

      test('mention refs are recorded as reference edges', () async {
        final pid = await seedPending('m1');

        await repo.saveDecryptedMessage(
          pendingId: pid,
          message: incoming('m1').copyWith(eTagRefs: ['ref-1', 'ref-2']),
        );

        final edges = await isar.noteRelationModels.where().findAll();
        expect(edges.map((e) => e.parentId), unorderedEquals(['ref-1', 'ref-2']));
      });

      test('a failure leaves the event queued and stores nothing', () async {
        final pid = await seedPending('m1');
        final relations = _Relations();
        when(() => relations.addEdgesInTxn(
              parents: any(named: 'parents'),
              childId: any(named: 'childId'),
            )).thenThrow(StateError('edge write failed'));
        final failing = E2EEGroupRepositoryImpl(
          isar,
          NoteAttachmentsEnricher(isar: isar),
          relations,
          MeshEventSigner.fixed(privkeyHex: kTestPrivHex, pubkeyHex: kTestPubHex),
        );

        await expectLater(
          failing.saveDecryptedMessage(
              pendingId: pid, message: incoming('m1').copyWith(eTagRefs: ['r'])),
          throwsStateError,
        );

        expect(await isar.noteModels.count(), 0);
        expect(await isar.unreadNoteModels.count(), 0);
        expect(await isar.encryptedMessageModels.count(), 1);
      });
    });

    group('createGroup', () {
      test('stores a signed group and queues the creation event together',
          () async {
        await repo.createGroup(
          group: aPrivateGroup(groupId: 'pg-9', adminPubkey: kSelfPub),
          event: queued('pg-9', kind: 9002, hTag: null),
        );

        final row = (await isar.privateGroupModels.where().findFirst())!;
        expect(row.groupId, 'pg-9');
        expect(row.adminPubkey, kSelfPub);
        expect(row.mlsGroupId, 'mls_pg-9');
        expect(row.signedNostrEvent, isNotNull);
        final q = (await isar.eventQueueModels.where().findFirst())!;
        expect(q.eventId, 'pg-9');
        expect(q.kind, 9002);
        expect(q.hTag, isNull);
        expect(q.sentCount, 0);
        expect(q.created, DateTime(2026, 1, 3));
      });

      test('a queue failure rolls the group back', () async {
        await isar.writeTxn(() => isar.eventQueueModels.put(
            EventQueueModel()
              ..eventId = 'pg-9'
              ..kind = 1
              ..content = ''
              ..authorPubkey = kAlicePub
              ..sig = ''
              ..eTagRefs = []
              ..pTagRefs = []
              ..tTags = []
              ..sentCount = 0
              ..created = DateTime(2026)
              ..enqueuedAt = DateTime(2026)));

        await expectLater(
          repo.createGroup(
            group: aPrivateGroup(groupId: 'pg-9'),
            event: queued('pg-9', kind: 9002),
          ),
          throwsA(anything),
        );

        expect(await isar.privateGroupModels.count(), 0);
      });
    });

    group('requestJoin', () {
      test('stores a placeholder group and queues the join request',
          () async {
        await repo.requestJoin(
          groupId: 'pg-1',
          relays: ['wss://r1'],
          event: queued('join', kind: 9021),
        );

        final row = (await isar.privateGroupModels.where().findFirst())!;
        expect(row.mlsGroupId, isEmpty);
        expect(row.name, 'pg-1');
        expect(row.relays, ['wss://r1']);
        expect(row.signedNostrEvent, isNotNull);
        expect((await isar.eventQueueModels.where().findFirst())!.hTag, 'pg-1');
      });

      test('a stored group with no relays gets them; one with relays is '
          'left alone', () async {
        await repo.saveGroup(aPrivateGroup(groupId: 'bare', relays: []));
        await repo.saveGroup(aPrivateGroup(groupId: 'rich', relays: ['wss://keep']));

        await repo.requestJoin(
            groupId: 'bare', relays: ['wss://new'], event: queued('j1', kind: 9021));
        await repo.requestJoin(
            groupId: 'rich', relays: ['wss://new'], event: queued('j2', kind: 9021));

        final bare = (await isar.privateGroupModels.where().groupIdEqualTo('bare').findFirst())!;
        final rich = (await isar.privateGroupModels.where().groupIdEqualTo('rich').findFirst())!;
        expect(bare.relays, ['wss://new']);
        expect(rich.relays, ['wss://keep']);
        expect(await isar.eventQueueModels.count(), 2);
      });

      test('a stored group with no relays and none offered stays as is',
          () async {
        await repo.saveGroup(aPrivateGroup(groupId: 'bare', relays: []));

        await repo.requestJoin(
            groupId: 'bare', relays: [], event: queued('j1', kind: 9021));

        final row = (await isar.privateGroupModels.where().findFirst())!;
        expect(row.relays, isEmpty);
        expect(row.signedNostrEvent, isNull);
        expect(await isar.eventQueueModels.count(), 1);
      });
    });

    test('leaveGroup queues the leave event and deletes the group together',
        () async {
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-1'));
      await repo.saveGroup(aPrivateGroup(groupId: 'pg-2'));

      await repo.leaveGroup(groupId: 'pg-1', event: queued('leave', kind: 9022));

      expect((await repo.getGroups()).map((g) => g.groupId), ['pg-2']);
      expect((await isar.eventQueueModels.where().findFirst())!.kind, 9022);
    });

    group('sendMessage', () {
      test('stores the note (read), its edges and the queued event in one '
          'transaction', () async {
        await repo.sendMessage(
          message: aNote(id: 'out-1', authorPubkey: kSelfPub, kind: kPrivateGroupKind)
              .copyWith(
            sourcePrivateGroupId: 'pg-1',
            eTagRefs: ['ref-1'],
            attachments: [aMediaBlob()],
          ),
          event: queued('out-1'),
        );

        final note = (await isar.noteModels.where().findFirst())!;
        expect(note.privateGroupId, 'pg-1');
        expect(note.attachments, hasLength(1));
        expect(await isar.unreadNoteModels.count(), 0);
        expect(await isar.noteRelationModels.count(), 1);
        expect((await isar.eventQueueModels.where().findFirst())!.hTag, 'pg-1');
      });

      test('a failure queues nothing and stores nothing', () async {
        final relations = _Relations();
        when(() => relations.addEdgesInTxn(
              parents: any(named: 'parents'),
              childId: any(named: 'childId'),
            )).thenThrow(StateError('edge write failed'));
        final failing = E2EEGroupRepositoryImpl(
          isar,
          NoteAttachmentsEnricher(isar: isar),
          relations,
          MeshEventSigner.fixed(privkeyHex: kTestPrivHex, pubkeyHex: kTestPubHex),
        );

        await expectLater(
          failing.sendMessage(
            message: aNote(id: 'out-1', kind: kPrivateGroupKind)
                .copyWith(sourcePrivateGroupId: 'pg-1', eTagRefs: ['r']),
            event: queued('out-1'),
          ),
          throwsStateError,
        );

        expect(await isar.noteModels.count(), 0);
        expect(await isar.eventQueueModels.count(), 0);
      });
    });

    group('join requests', () {
      setUp(() async {
        await isar.writeTxn(() => isar.privateGroupJoinRequestModels.putAll([
              joinRequestRow('r1', senderPubkey: kBobPub, keyPackageB64: 'kp-1'),
              joinRequestRow('r2', senderPubkey: kBobPub, keyPackageB64: 'kp-2'),
              joinRequestRow('r3', senderPubkey: kAlicePub, keyPackageB64: 'kp-3'),
              joinRequestRow('r4', senderPubkey: kBobPub, keyPackageB64: 'kp-1', groupId: 'other'),
            ]));
      });

      test('senderForKeyPackage finds the pending requester, null otherwise',
          () async {
        expect(await repo.senderForKeyPackage('pgroup-1', 'kp-1'), kBobPub);
        expect(await repo.senderForKeyPackage('pgroup-1', 'missing'), isNull);
        expect(await repo.senderForKeyPackage('empty-group', 'kp-1'), isNull);
      });

      test('senderForKeyPackage ignores a request already handled', () async {
        await repo.approveJoinRequests(
            groupId: 'pgroup-1', keyPackageB64: 'kp-1', senderPubkey: kBobPub);

        expect(await repo.senderForKeyPackage('pgroup-1', 'kp-1'), isNull);
      });

      test('approving queues the events and clears every pending request '
          'from that sender, in this group only', () async {
        await repo.approveJoinRequests(
          groupId: 'pgroup-1',
          keyPackageB64: 'kp-1',
          senderPubkey: kBobPub,
          events: [queued('welcome', kind: 9024), queued('commit', kind: 9025)],
        );

        final handled = {
          for (final r in await isar.privateGroupJoinRequestModels.where().findAll())
            r.eventId: r.handled
        };
        expect(handled, {'r1': true, 'r2': true, 'r3': false, 'r4': false});
        expect((await isar.eventQueueModels.where().findAll()).map((e) => e.kind),
            unorderedEquals([9024, 9025]));
        expect((await repo.getJoinRequests('pgroup-1')).map((r) => r.eventId), ['r3']);
      });

      test('with no events and no sender it only marks the matching key '
          'package', () async {
        await repo.approveJoinRequests(groupId: 'pgroup-1', keyPackageB64: 'kp-2');

        final handled = {
          for (final r in await isar.privateGroupJoinRequestModels.where().findAll())
            r.eventId: r.handled
        };
        expect(handled['r2'], isTrue);
        expect(handled['r1'], isFalse);
        expect(await isar.eventQueueModels.count(), 0);
      });

      test('nothing matching marks nothing but still queues the events',
          () async {
        await repo.approveJoinRequests(
          groupId: 'pgroup-1',
          keyPackageB64: 'unknown',
          events: [queued('welcome', kind: 9024)],
        );

        expect(
            (await isar.privateGroupJoinRequestModels.where().findAll())
                .every((r) => !r.handled),
            isTrue);
        expect(await isar.eventQueueModels.count(), 1);
      });
    });
  });
}

class _Relations extends Mock implements NoteRelationRepository {}
