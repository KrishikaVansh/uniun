import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:openmls/openmls.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/encrypted_message_model.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/missing_profile_pubkey_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/private_group_join_request_model.dart';
import 'package:uniun/data/models/private_group_model.dart';
import 'package:uniun/data/repositories/e2ee_group_repository_impl.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/data/repositories/note_relation_repository_impl.dart';
import 'package:uniun/data/repositories/profile_repository_impl.dart';
import 'package:uniun/domain/entities/media/media_dim.dart';
import 'package:uniun/domain/services/marmot_mls_service.dart';
import 'package:uniun/domain/services/marmot_transport_service.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';

class _Mls extends Mock implements MarmotMlsService {}

/// Covers: MarmotTransportService over real Isar repositories and a mocked MLS
/// engine — the inbound queue (welcome, commit, leave, application message and
/// every envelope shape) and the publishing side (create, join, leave, send,
/// approve), including the paths that must leave an event queued.
void main() {
  late Isar isar;
  late _Mls mls;
  late MarmotTransportService transport;
  final me = Keychain.generate();

  setUp(() async {
    isar = await openTestIsar();
    mls = _Mls();
    transport = MarmotTransportService(
      E2EEGroupRepositoryImpl(
        isar,
        NoteAttachmentsEnricher(isar: isar),
        NoteRelationRepositoryImpl(isar: isar),
        MeshEventSigner.fixed(privkeyHex: me.private, pubkeyHex: me.public),
      ),
      mls,
      ProfileRepositoryImpl(isar: isar),
    );
  });

  tearDown(() async {
    await transport.stop();
    await isar.close(deleteFromDisk: true);
  });

  Future<void> seedGroup(String id, {String mlsId = 'bWxz'}) => isar.writeTxn(
      () => isar.privateGroupModels.put(privateGroupSeed(id)..mlsGroupId = mlsId));

  Future<void> queue(String eventId, int kind,
          {String groupId = 'g1', String payload = 'cGF5'}) =>
      isar.writeTxn(() => isar.encryptedMessageModels.put(
            EncryptedMessageModel()
              ..eventId = eventId
              ..groupId = groupId
              ..senderPubkey = kBobPub
              ..kind = kind
              ..encryptedPayload = payload
              ..timestamp = DateTime(2026, 1, 2),
          ));

  /// One full pass over whatever is queued.
  Future<void> processQueue() async {
    transport.start();
    await transport.stop();
  }

  void decryptsTo(String plaintext) {
    when(() => mls.decryptMessage(
          groupId: any(named: 'groupId'),
          base64Payload: any(named: 'base64Payload'),
          groupIdIsBase64: any(named: 'groupIdIsBase64'),
        )).thenAnswer((_) async => utf8.encode(plaintext));
  }

  group('inbound queue', () {
    test('a Welcome binds the MLS group id and is consumed', () async {
      await seedGroup('g1', mlsId: '');
      await queue('w', 9024);
      when(() => mls.joinGroupFromWelcome(welcomeB64: 'cGF5'))
          .thenAnswer((_) async => 'joined-mls');

      await processQueue();

      expect((await isar.privateGroupModels.where().findFirst())!.mlsGroupId,
          'joined-mls');
      expect(await isar.encryptedMessageModels.count(), 0);
    });

    test('a Welcome for a group we do not hold stays queued', () async {
      await queue('w', 9024);
      when(() => mls.joinGroupFromWelcome(welcomeB64: any(named: 'welcomeB64')))
          .thenAnswer((_) async => 'joined-mls');

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 1);
    });

    test('a Welcome the MLS engine rejects stays queued', () async {
      await seedGroup('g1', mlsId: '');
      await queue('w', 9024);
      when(() => mls.joinGroupFromWelcome(welcomeB64: any(named: 'welcomeB64')))
          .thenThrow(StateError('bad welcome'));

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 1);
      expect((await isar.privateGroupModels.where().findFirst())!.mlsGroupId, isEmpty);
    });

    test('a Commit is fed to MLS and consumed', () async {
      await seedGroup('g1');
      await queue('c', 9025);
      when(() => mls.processProtocolMessage(
            groupId: 'bWxz',
            base64Payload: 'cGF5',
            groupIdIsBase64: true,
          )).thenAnswer((_) async {});

      await processQueue();

      verify(() => mls.processProtocolMessage(
            groupId: 'bWxz',
            base64Payload: 'cGF5',
            groupIdIsBase64: true,
          )).called(1);
      expect(await isar.encryptedMessageModels.count(), 0);
    });

    test('a Commit waits for the Welcome: no group, or no MLS id yet',
        () async {
      await queue('c1', 9025, groupId: 'unknown');
      await seedGroup('g1', mlsId: '');
      await queue('c2', 9025);

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 2);
      verifyNever(() => mls.processProtocolMessage(
            groupId: any(named: 'groupId'),
            base64Payload: any(named: 'base64Payload'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          ));
    });

    test('a Commit MLS cannot process yet stays queued', () async {
      await seedGroup('g1');
      await queue('c', 9025);
      when(() => mls.processProtocolMessage(
            groupId: any(named: 'groupId'),
            base64Payload: any(named: 'base64Payload'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenThrow(StateError('epoch mismatch'));

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 1);
    });

    test('a leave notice is simply consumed', () async {
      await queue('l', 9022);

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 0);
      verifyZeroInteractions(mls);
    });

    test('a plain-text message is stored unread and the sender flagged for a '
        'profile fetch', () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      decryptsTo('plain नमस्ते 🌍');

      await processQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.eventId, 'm1');
      expect(note.kind, kPrivateGroupKind);
      expect(note.privateGroupId, 'g1');
      expect(note.authorPubkey, kBobPub);
      expect(note.content, 'plain नमस्ते 🌍');
      expect(note.type, NoteType.text);
      expect(note.created, DateTime(2026, 1, 2));
      expect(note.sig, isEmpty);
      expect(await isar.unreadNoteModels.count(), 1);
      expect(await isar.encryptedMessageModels.count(), 0);
      expect((await isar.missingProfilePubkeyModels.where().findAll()).map((m) => m.pubkey),
          [kBobPub]);
    });

    test('an envelope restores content, references, thread markers, embed '
        'and attachments; a malformed attachment is skipped', () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      final embed = jsonEncode({
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': 1,
        'kind': 1,
        'tags': <List<String>>[],
        'content': 'quoted',
        'sig': 'c' * 128,
      });
      decryptsTo(jsonEncode({
        'c': 'look',
        'e': ['ref-1', 'ref-2'],
        'r': 'root-id',
        'y': 'reply-id',
        'em': embed,
        'i': [
          {'x': 'sha-1', 'm': 'image/png', 's': 10, 'u': 'https://b/x', 'w': 4, 'h': 3, 'b': 'bh', 'n': 'p.png'},
          {'x': 'sha-2', 'm': 'application/pdf'},
          {'x': 'no-mime'},
          'not-a-map',
        ],
      }));

      await processQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.content, 'look');
      expect(note.eTagRefs, ['ref-1', 'ref-2']);
      expect(note.rootEventId, 'root-id');
      expect(note.replyToEventId, 'reply-id');
      expect(note.embeddedNoteJson, isNotNull);
      expect(note.type, NoteType.image);
      expect(note.attachments.map((a) => a.sha256), ['sha-1', 'sha-2']);
      expect(note.attachments.first.width, 4);
      expect(note.attachments.last.url, isNull);
      expect(await isar.noteRelationModels.count(), 2);
    });

    test('an envelope without images is a text note', () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      decryptsTo(jsonEncode({
        'c': 'doc',
        'e': <String>[],
        'i': [
          {'x': 'sha-2', 'm': 'application/pdf'},
        ],
      }));

      await processQueue();

      expect((await isar.noteModels.where().findFirst())!.type, NoteType.text);
    });

    test('JSON that is not an envelope is shown as the raw text', () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      await queue('m2', 9023);
      await queue('m3', 9023);
      var n = 0;
      final bodies = ['{"c":1,"e":[]}', '[1,2]', '{"unrelated":true}'];
      when(() => mls.decryptMessage(
            groupId: any(named: 'groupId'),
            base64Payload: any(named: 'base64Payload'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenAnswer((_) async => utf8.encode(bodies[n++]));

      await processQueue();

      final contents = (await isar.noteModels.where().findAll()).map((x) => x.content);
      expect(contents, unorderedEquals(bodies));
    });

    test('an application message waits for the group and its MLS id',
        () async {
      await queue('m1', 9023, groupId: 'unknown');
      await seedGroup('g1', mlsId: '');
      await queue('m2', 9023);

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 2);
      expect(await isar.noteModels.count(), 0);
    });

    test('a message MLS cannot decrypt stays queued', () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      when(() => mls.decryptMessage(
            groupId: any(named: 'groupId'),
            base64Payload: any(named: 'base64Payload'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenThrow(StateError('wrong epoch'));

      await processQueue();

      expect(await isar.encryptedMessageModels.count(), 1);
      expect(await isar.noteModels.count(), 0);
    });

    test('an already stored message is not stored twice and stays queued',
        () async {
      await seedGroup('g1');
      await queue('m1', 9023);
      decryptsTo('again');
      await processQueue();
      await queue('m1-dup', 9023);
      await isar.writeTxn(() async {
        final row = (await isar.encryptedMessageModels.where().findFirst())!;
        row.eventId = 'm1';
        await isar.encryptedMessageModels.put(row);
      });

      await processQueue();

      expect(await isar.noteModels.count(), 1);
      expect(await isar.unreadNoteModels.count(), 1);
    });

    test('an empty queue does nothing', () async {
      await processQueue();

      verifyZeroInteractions(mls);
    });

    test('start is idempotent and picks up messages that arrive later',
        () async {
      await seedGroup('g1');
      decryptsTo('later');
      transport
        ..start()
        ..start();

      await queue('m1', 9023);
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (await isar.noteModels.count() < 1) {
        if (DateTime.now().isAfter(end)) fail('message not processed');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(await isar.encryptedMessageModels.count(), 0);
    });
  });

  group('createGroup', () {
    test('creates the MLS group, then stores it signed and queues the '
        'kind-9002 event whose id is the group id', () async {
      when(() => mls.createGroup(creatorPubkeyHex: me.public)).thenAnswer(
          (_) async => CreateGroupResult(groupId: Uint8List.fromList([1, 2, 3])));

      final id = await transport.createGroup(
        privkeyHex: me.private,
        authorPubkey: me.public,
        name: 'Crew',
        description: 'the crew',
        relays: ['wss://r1'],
      );

      final group = (await isar.privateGroupModels.where().findFirst())!;
      expect(group.groupId, id);
      expect(group.mlsGroupId, base64Encode([1, 2, 3]));
      expect(group.name, 'Crew');
      expect(group.description, 'the crew');
      expect(group.relays, ['wss://r1']);
      expect(group.adminPubkey, me.public);
      expect(group.signedNostrEvent, isNotNull);
      final q = (await isar.eventQueueModels.where().findFirst())!;
      expect(q.eventId, id);
      expect(q.kind, 9002);
      expect(q.hTag, isNull);
      expect(q.authorPubkey, me.public);
      expect(jsonDecode(q.content), {'name': 'Crew', 'about': 'the crew'});
    });

    test('an MLS failure stores and queues nothing', () async {
      when(() => mls.createGroup(creatorPubkeyHex: any(named: 'creatorPubkeyHex')))
          .thenThrow(StateError('no signer'));

      await expectLater(
        transport.createGroup(
          privkeyHex: me.private,
          authorPubkey: me.public,
          name: 'x',
          description: '',
          relays: const [],
        ),
        throwsStateError,
      );

      expect(await isar.privateGroupModels.count(), 0);
      expect(await isar.eventQueueModels.count(), 0);
    });
  });

  group('joinGroup', () {
    test('queues the kind-9021 request carrying the key package and stores a '
        'stub group', () async {
      when(() => mls.generateKeyPackage(pubkeyHex: me.public))
          .thenAnswer((_) async => 'a2V5cGFja2FnZQ==');

      await transport.joinGroup(
        groupId: 'g1',
        authorPubkey: me.public,
        privkeyHex: me.private,
        relays: ['wss://r1'],
      );

      final q = (await isar.eventQueueModels.where().findFirst())!;
      expect(q.kind, 9021);
      expect(q.content, 'a2V5cGFja2FnZQ==');
      expect(q.hTag, 'g1');
      final stub = (await isar.privateGroupModels.where().findFirst())!;
      expect(stub.groupId, 'g1');
      expect(stub.mlsGroupId, isEmpty);
      expect(stub.relays, ['wss://r1']);
    });
  });

  group('leaveGroup', () {
    test('leaves MLS, queues the kind-9022 event and removes the group',
        () async {
      await seedGroup('g1');
      when(() => mls.leaveGroup(groupId: 'bWxz', groupIdIsBase64: true))
          .thenAnswer((_) async {});

      await transport.leaveGroup(
          groupId: 'g1', authorPubkey: me.public, privkeyHex: me.private);

      verify(() => mls.leaveGroup(groupId: 'bWxz', groupIdIsBase64: true)).called(1);
      expect(await isar.privateGroupModels.count(), 0);
      final q = (await isar.eventQueueModels.where().findFirst())!;
      expect([q.kind, q.hTag, q.content], [9022, 'g1', '']);
    });

    test('an MLS failure does not stop the local leave', () async {
      await seedGroup('g1');
      when(() => mls.leaveGroup(
            groupId: any(named: 'groupId'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenThrow(StateError('not a member'));

      await transport.leaveGroup(
          groupId: 'g1', authorPubkey: me.public, privkeyHex: me.private);

      expect(await isar.privateGroupModels.count(), 0);
      expect(await isar.eventQueueModels.count(), 1);
    });

    test('a group that never got its MLS id skips MLS; an unknown group '
        'still queues the leave', () async {
      await seedGroup('pending', mlsId: '');

      await transport.leaveGroup(
          groupId: 'pending', authorPubkey: me.public, privkeyHex: me.private);
      await transport.leaveGroup(
          groupId: 'unknown', authorPubkey: me.public, privkeyHex: me.private);

      verifyZeroInteractions(mls);
      expect(await isar.eventQueueModels.count(), 2);
    });
  });

  group('sendGroupMessage', () {
    String? sentPlaintext;

    setUp(() {
      sentPlaintext = null;
      when(() => mls.encryptMessage(
            groupId: any(named: 'groupId'),
            content: any(named: 'content'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenAnswer((i) async {
        sentPlaintext = i.namedArguments[#content] as String;
        return 'ZW5jcnlwdGVk';
      });
    });

    test('plain text goes verbatim; the local copy is read and the encrypted '
        'event is queued', () async {
      await seedGroup('g1');

      await transport.sendGroupMessage(
        groupId: 'g1',
        content: 'hello',
        authorPubkey: me.public,
        privkeyHex: me.private,
      );

      expect(sentPlaintext, 'hello');
      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.content, 'hello');
      expect(note.authorPubkey, me.public);
      expect(note.privateGroupId, 'g1');
      expect(note.type, NoteType.text);
      expect(await isar.unreadNoteModels.count(), 0);
      final q = (await isar.eventQueueModels.where().findFirst())!;
      expect(q.kind, 9023);
      expect(q.hTag, 'g1');
      expect(q.content, 'ZW5jcnlwdGVk');
      expect(note.eventId, q.eventId);
    });

    test('references, thread markers, embed and attachments travel in the '
        'encrypted envelope and on the local copy', () async {
      await seedGroup('g1');

      await transport.sendGroupMessage(
        groupId: 'g1',
        content: 'look',
        authorPubkey: me.public,
        privkeyHex: me.private,
        mentionRefs: ['ref-1'],
        rootEventId: 'root-id',
        replyToEventId: 'reply-id',
        embeddedNoteJson: '{"id":"x"}',
        attachments: [
          aMediaBlob(
            sha256: 'sha-1',
            mime: 'image/png',
            sizeBytes: 10,
            dim: const MediaDim(width: 4, height: 3),
            blurhash: 'bh',
            filename: 'p.png',
          ),
          aMediaBlob(sha256: 'sha-2', sizeBytes: 0, serverUrls: const []),
        ],
      );

      final env = jsonDecode(sentPlaintext!) as Map<String, dynamic>;
      expect(env['c'], 'look');
      expect(env['e'], ['ref-1']);
      expect(env['r'], 'root-id');
      expect(env['y'], 'reply-id');
      expect(env['em'], '{"id":"x"}');
      expect((env['i'] as List).first, {
        'x': 'sha-1',
        'm': 'image/png',
        's': 10,
        'u': 'https://blossom.example/sha256-aaa',
        'w': 4,
        'h': 3,
        'b': 'bh',
        'n': 'p.png',
      });
      expect((env['i'] as List).last, {'x': 'sha-2', 'm': 'image/jpeg'});
      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.type, NoteType.image);
      expect(note.rootEventId, 'root-id');
      expect(note.eTagRefs, ['ref-1']);
      expect(note.attachments, hasLength(2));
      expect(await isar.noteRelationModels.count(), 1);
    });

    test('an unknown group, or one without an MLS id, is refused before '
        'anything is encrypted or stored', () async {
      await seedGroup('pending', mlsId: '');

      for (final id in ['unknown', 'pending']) {
        await expectLater(
          transport.sendGroupMessage(
            groupId: id,
            content: 'x',
            authorPubkey: me.public,
            privkeyHex: me.private,
          ),
          throwsException,
        );
      }

      expect(sentPlaintext, isNull);
      expect(await isar.noteModels.count(), 0);
      expect(await isar.eventQueueModels.count(), 0);
    });
  });

  group('approveJoinRequest', () {
    setUp(() async {
      await seedGroup('pgroup-1');
      await isar.writeTxn(() => isar.privateGroupJoinRequestModels.putAll([
            joinRequestRow('r1', senderPubkey: kBobPub, keyPackageB64: 'kp-1'),
            joinRequestRow('r2', senderPubkey: kBobPub, keyPackageB64: 'kp-2'),
            joinRequestRow('r3', senderPubkey: kAlicePub, keyPackageB64: 'kp-3'),
          ]));
    });

    Future<void> approve({String groupId = 'pgroup-1', String kp = 'kp-1'}) =>
        transport.approveJoinRequest(
          groupId: groupId,
          userKeyPackageB64: kp,
          adminPrivkeyHex: me.private,
        );

    Future<Map<String, bool>> handled() async => {
          for (final r in await isar.privateGroupJoinRequestModels.where().findAll())
            r.eventId: r.handled
        };

    test('queues the Welcome and Commit and clears every request from that '
        'member', () async {
      when(() => mls.addMembers(
            groupId: 'bWxz',
            keyPackagesB64: ['kp-1'],
            groupIdIsBase64: true,
          )).thenAnswer((_) async => AddMembersResult(
            commit: Uint8List.fromList([9]),
            welcome: Uint8List.fromList([8]),
          ));

      await approve();

      final queued = await isar.eventQueueModels.where().findAll();
      expect(queued.map((q) => q.kind), unorderedEquals([9024, 9025]));
      expect(queued.firstWhere((q) => q.kind == 9024).content, base64Encode([8]));
      expect(queued.firstWhere((q) => q.kind == 9025).content, base64Encode([9]));
      expect(queued.every((q) => q.hTag == 'pgroup-1'), isTrue);
      expect(await handled(), {'r1': true, 'r2': true, 'r3': false});
    });

    test('a member already in the group is treated as approved: requests '
        'cleared, nothing queued', () async {
      when(() => mls.addMembers(
            groupId: any(named: 'groupId'),
            keyPackagesB64: any(named: 'keyPackagesB64'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenThrow(Exception('Duplicate Signature Key'));

      await approve();

      expect(await handled(), {'r1': true, 'r2': true, 'r3': false});
      expect(await isar.eventQueueModels.count(), 0);
    });

    test('any other MLS error is rethrown and leaves the requests pending',
        () async {
      when(() => mls.addMembers(
            groupId: any(named: 'groupId'),
            keyPackagesB64: any(named: 'keyPackagesB64'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenThrow(StateError('boom'));

      await expectLater(approve(), throwsStateError);

      expect((await handled()).values.any((h) => h), isFalse);
      expect(await isar.eventQueueModels.count(), 0);
    });

    test('an unknown group or one without an MLS id is refused', () async {
      await seedGroup('pending', mlsId: '');

      await expectLater(approve(groupId: 'unknown'), throwsException);
      await expectLater(approve(groupId: 'pending'), throwsException);
      verifyZeroInteractions(mls);
    });

    test('a key package with no stored request still queues the events',
        () async {
      when(() => mls.addMembers(
            groupId: any(named: 'groupId'),
            keyPackagesB64: any(named: 'keyPackagesB64'),
            groupIdIsBase64: any(named: 'groupIdIsBase64'),
          )).thenAnswer((_) async => AddMembersResult(
            commit: Uint8List.fromList([9]),
            welcome: Uint8List.fromList([8]),
          ));

      await approve(kp: 'unknown-kp');

      expect(await isar.eventQueueModels.count(), 2);
      expect((await handled()).values.any((h) => h), isFalse);
    });
  });
}
