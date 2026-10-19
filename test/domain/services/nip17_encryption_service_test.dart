import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:nip44/nip44.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/core/notes/embedded_note_codec.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/dm/dm_conversation_model.dart';
import 'package:uniun/data/models/dm/encrypted_dm_model.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/missing_profile_pubkey_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/repositories/dm_conversation_repository_impl.dart';
import 'package:uniun/data/repositories/event_queue_repository_impl.dart';
import 'package:uniun/data/repositories/nip17_repository_impl.dart';
import 'package:uniun/data/repositories/note_relation_repository_impl.dart';
import 'package:uniun/data/repositories/profile_repository_impl.dart';
import 'package:uniun/domain/entities/media/media_dim.dart';
import 'package:uniun/domain/services/nip17_encryption_service.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_test_harness.dart';

/// Covers: Nip17EncryptionService end to end over real Isar and real NIP-44 —
/// send → gift wrap → receive round trip, every rejection path of the
/// inbound pipeline, queue watching, and the no-key guards.
void main() {
  late Isar isar;
  final alice = Keychain.generate();
  final bob = Keychain.generate();

  Nip17EncryptionService serviceFor(Keychain who, {Isar? db, bool withKey = true}) {
    final d = db ?? isar;
    return Nip17EncryptionService(
      Nip17RepositoryImpl(
        isar: d,
        relations: NoteRelationRepositoryImpl(isar: d),
        conversations: DmConversationRepositoryImpl(
          isar: d,
          signer: MeshEventSigner.fixed(
              privkeyHex: who.private, pubkeyHex: who.public),
        ),
      ),
      EventQueueRepositoryImpl(isar: d),
      ProfileRepositoryImpl(isar: d),
      privkeyHex: withKey ? who.private : null,
    );
  }

  setUp(() async => isar = await openTestIsar());
  tearDown(() async => isar.close(deleteFromDisk: true));

  Map<String, dynamic> rumor({
    int kind = kDmTextKind,
    String? pubkey,
    String content = 'hello',
    List<List<String>> tags = const [],
    String id = 'rumor-1',
    int? createdAt = 1700000000,
  }) =>
      {
        'id': id,
        'pubkey': pubkey ?? alice.public,
        if (createdAt != null) 'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
      };

  /// A gift wrap to Bob carrying [chat], sealed by [sealer].
  Future<EncryptedDmModel> giftWrap(
    Map<String, dynamic> chat, {
    Keychain? sealer,
    int sealKind = 13,
    String eventId = 'wrap-1',
  }) async {
    final from = sealer ?? alice;
    final seal = Event.from(
      privkey: from.private,
      kind: sealKind,
      tags: const [],
      content: await Nip44.encryptMessage(jsonEncode(chat), from.private, bob.public),
      createdAt: 1700000000,
    );
    final ephemeral = Keychain.generate().private;
    return EncryptedDmModel(
      eventId: eventId,
      sig: 'sig',
      authorPubkey: Keychain(ephemeral).public,
      pTagRef: bob.public,
      content: await Nip44.encryptMessage(
          jsonEncode(seal.toJson()), ephemeral, bob.public),
      kind: 1059,
      created: DateTime(2026),
    );
  }

  Future<void> queueWrap(EncryptedDmModel wrap) =>
      isar.writeTxn(() => isar.encryptedDmModels.put(wrap));

  group('processInboundQueue', () {
    test('stores a text DM, creates the conversation, flags the sender for a '
        'profile fetch and consumes the wrap', () async {
      await queueWrap(await giftWrap(rumor(content: 'नमस्ते 🌍')));

      await serviceFor(bob).processInboundQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.eventId, 'rumor-1');
      expect(note.content, 'नमस्ते 🌍');
      expect(note.sig, isEmpty);
      expect(note.authorPubkey, alice.public);
      expect(note.type, NoteType.text);
      expect(note.created, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
      final conv = (await isar.dmConversationModels.where().findFirst())!;
      expect(conv.otherPubkey, alice.public);
      expect(note.conversationId, conv.id);
      expect(await isar.unreadNoteModels.count(), 1);
      expect(await isar.encryptedDmModels.count(), 0);
      expect(
        (await isar.missingProfilePubkeyModels.where().findAll()).map((m) => m.pubkey),
        [alice.public],
      );
    });

    test('parses reply, root, mention, subject, embed and imeta tags',
        () async {
      final embed = jsonEncode({
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': 1,
        'kind': 1,
        'tags': <List<String>>[],
        'content': 'quoted',
        'sig': 'c' * 128,
      });
      await queueWrap(await giftWrap(rumor(tags: [
        ['p', bob.public],
        ['e', 'root-id', '', 'root'],
        ['e', 'reply-id', '', 'reply'],
        ['e', 'mention-id', '', 'mention'],
        ['subject', 'Re: plans'],
        EmbeddedNoteCodec.tag(embed),
        ['imeta', 'url https://b.example/x', 'x sha-x', 'm image/png', 'size 12', 'dim 40x30', 'blurhash bh', 'name pic.png'],
        [],
        ['e'],
      ])));

      await serviceFor(bob).processInboundQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.pTagRefs, [bob.public]);
      expect(note.rootEventId, 'root-id');
      expect(note.replyToEventId, 'reply-id');
      expect(note.eTagRefs, ['root-id', 'reply-id', 'mention-id']);
      expect(note.subject, 'Re: plans');
      expect(note.embeddedNoteJson, isNotNull);
      final a = note.attachments.single;
      expect([a.url, a.sha256, a.mime, a.sizeBytes, a.width, a.height, a.blurhash, a.filename],
          ['https://b.example/x', 'sha-x', 'image/png', 12, 40, 30, 'bh', 'pic.png']);
    });

    test('an untagged e reference counts as the direct reply', () async {
      await queueWrap(await giftWrap(rumor(tags: [
        ['e', 'parent-id'],
      ])));

      await serviceFor(bob).processInboundQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.replyToEventId, 'parent-id');
      expect(note.rootEventId, isNull);
    });

    test('a file message (kind 15) is typed from its url; plain text and '
        'reactions stay text', () async {
      await queueWrap(await giftWrap(
          rumor(kind: kDmFileKind, content: 'https://x.example/a.PNG', id: 'img'),
          eventId: 'w1'));
      await queueWrap(await giftWrap(
          rumor(kind: kDmFileKind, content: 'https://x.example/doc', id: 'lnk'),
          eventId: 'w2'));
      await queueWrap(await giftWrap(
          rumor(kind: kDmFileKind, content: 'just words', id: 'txt'),
          eventId: 'w3'));
      await queueWrap(await giftWrap(
          rumor(kind: 7, content: 'https://x.example/a.png', id: 'react'),
          eventId: 'w4'));

      await serviceFor(bob).processInboundQueue();

      final types = {
        for (final n in await isar.noteModels.where().findAll()) n.eventId: n.type
      };
      expect(types, {
        'img': NoteType.image,
        'lnk': NoteType.link,
        'txt': NoteType.text,
        'react': NoteType.text,
      });
    });

    test('a missing created_at falls back to now; a missing id and content '
        'fall back to empty', () async {
      final before = DateTime.now();
      final chat = rumor(createdAt: null)..remove('id')..remove('content');
      await queueWrap(await giftWrap(chat));

      await serviceFor(bob).processInboundQueue();

      final note = (await isar.noteModels.where().findFirst())!;
      expect(note.eventId, isEmpty);
      expect(note.content, isEmpty);
      expect(note.created.isAfter(before.subtract(const Duration(seconds: 2))), isTrue);
    });

    test('redelivery of the same rumor keeps one note and one unread row',
        () async {
      await queueWrap(await giftWrap(rumor(), eventId: 'w1'));
      await queueWrap(await giftWrap(rumor(), eventId: 'w2'));

      await serviceFor(bob).processInboundQueue();

      expect(await isar.noteModels.count(), 1);
      expect(await isar.unreadNoteModels.count(), 1);
      expect(await isar.encryptedDmModels.count(), 0);
    });

    test('our own copy of a DM (sealed to ourselves) is stored read',
        () async {
      await queueWrap(await giftWrap(rumor(pubkey: bob.public), sealer: bob));

      await serviceFor(bob).processInboundQueue();

      expect(await isar.noteModels.count(), 1);
      expect(await isar.unreadNoteModels.count(), 0);
    });

    for (final c in <(String, Future<EncryptedDmModel> Function())>[
      ('a seal that is not kind 13', () => giftWrap(rumor(), sealKind: 14)),
      ('an unsupported inner kind', () => giftWrap(rumor(kind: 1))),
      ('an inner pubkey that differs from the seal sender',
          () => giftWrap(rumor(pubkey: bob.public))),
      ('a wrap that does not decrypt', () async {
        final w = await giftWrap(rumor());
        w.content = 'not-a-valid-ciphertext';
        return w;
      }),
    ]) {
      test('${c.$1} is discarded and stores nothing', () async {
        await queueWrap(await c.$2());

        await serviceFor(bob).processInboundQueue();

        expect(await isar.noteModels.count(), 0);
        expect(await isar.encryptedDmModels.count(), 0);
        expect(await isar.missingProfilePubkeyModels.count(), 0);
      });
    }

    test('one bad wrap does not stop the good ones behind it', () async {
      final bad = await giftWrap(rumor(), sealKind: 14, eventId: 'bad');
      await queueWrap(bad);
      await queueWrap(await giftWrap(rumor(id: 'good'), eventId: 'good'));

      await serviceFor(bob).processInboundQueue();

      expect((await isar.noteModels.where().findAll()).map((n) => n.eventId), ['good']);
      expect(await isar.encryptedDmModels.count(), 0);
    });

    test('an empty queue does nothing', () async {
      await serviceFor(bob).processInboundQueue();

      expect(await isar.noteModels.count(), 0);
    });

    test('without a private key the queue is left untouched', () async {
      await queueWrap(await giftWrap(rumor()));

      await serviceFor(bob, withKey: false).processInboundQueue();

      expect(await isar.encryptedDmModels.count(), 1);
      expect(await isar.noteModels.count(), 0);
    });

    test('an unreadable queue throws instead of silently dropping wraps',
        () async {
      final service = serviceFor(bob);
      await isar.close();

      await expectLater(service.processInboundQueue(), throwsException);
      isar = await openTestIsar();
    });
  });

  group('start', () {
    test('processes what is queued now and what arrives later', () async {
      await queueWrap(await giftWrap(rumor(id: 'early'), eventId: 'w1'));
      serviceFor(bob).start();
      await _until(() async => await isar.noteModels.count() == 1);

      await queueWrap(await giftWrap(rumor(id: 'late'), eventId: 'w2'));
      await _until(() async => await isar.noteModels.count() == 2);

      expect(await isar.encryptedDmModels.count(), 0);
    });
  });

  group('sendDm', () {
    final aliceToBob = serviceFor;

    test('round trip: the sender keeps a local copy, queues a kind-1059 wrap '
        'to the receiver, and the receiver decrypts the same message',
        () async {
      final sent = aNote(
        id: 'local-1',
        authorPubkey: alice.public,
        kind: kDmFileKind,
        content: 'see attached',
        conversationId: 7,
        pTagRefs: [bob.public],
      ).copyWith(
        type: NoteType.image,
        rootEventId: 'root-id',
        replyToEventId: 'reply-id',
        eTagRefs: ['root-id', 'reply-id', 'mention-id'],
        embeddedNoteJson: jsonEncode({
          'id': 'a' * 64,
          'pubkey': 'b' * 64,
          'created_at': 1,
          'kind': 1,
          'tags': <List<String>>[],
          'content': 'quoted',
          'sig': 'c' * 128,
        }),
        attachments: [
          aMediaBlob(
            sha256: 'sha-1',
            mime: 'image/png',
            sizeBytes: 99,
            dim: const MediaDim(width: 8, height: 6),
            blurhash: 'bh',
            filename: 'a.png',
          ),
          aMediaBlob(sha256: 'sha-2', sizeBytes: 0, serverUrls: const [], filename: ''),
        ],
      );

      await aliceToBob(alice).sendDm(sent, receiverPubkey: bob.public);

      final local = (await isar.noteModels.where().findFirst())!;
      expect(local.eventId, 'local-1');
      expect(local.conversationId, 7);
      final queued = (await isar.eventQueueModels.where().findAll()).single;
      expect(queued.kind, 1059);
      expect(queued.pTagRefs, [bob.public]);
      expect(queued.authorPubkey, isNot(alice.public));
      expect(queued.eTagRefs, isEmpty);

      // Hand the queued wrap to the receiver, as the gateway would.
      await queueWrap(EncryptedDmModel(
        eventId: queued.eventId,
        sig: queued.sig,
        authorPubkey: queued.authorPubkey,
        pTagRef: bob.public,
        content: queued.content,
        kind: 1059,
        created: queued.created,
      ));
      await isar.writeTxn(() => isar.noteModels.clear());

      await serviceFor(bob).processInboundQueue();

      final received = (await isar.noteModels.where().findFirst())!;
      expect(received.authorPubkey, alice.public);
      expect(received.content, 'see attached');
      expect(received.kind, kDmFileKind);
      expect(received.rootEventId, 'root-id');
      expect(received.replyToEventId, 'reply-id');
      expect(received.eTagRefs, ['root-id', 'reply-id', 'mention-id']);
      expect(received.embeddedNoteJson, isNotNull);
      // The url-less second blob is sent but dropped by the receiver's parser.
      expect(received.attachments, hasLength(1));
      expect(received.attachments.first.url, 'https://blossom.example/sha256-aaa');
      expect(received.attachments.first.width, 8);
      expect(received.attachments.first.filename, 'a.png');
      // The rumor id is the NIP-01 hash of the payload Alice built.
      final payload = [
        0,
        alice.public,
        received.created.millisecondsSinceEpoch ~/ 1000,
        kDmFileKind,
        [
          ['p', bob.public],
          ['e', 'root-id', '', 'root'],
          ['e', 'reply-id', '', 'reply'],
          ['e', 'mention-id', '', 'mention'],
          EmbeddedNoteCodec.tag(sent.embeddedNoteJson!),
          [
            'imeta',
            'url https://blossom.example/sha256-aaa',
            'm image/png',
            'x sha-1',
            'size 99',
            'dim 8x6',
            'blurhash bh',
            'name a.png',
          ],
          ['imeta', 'm image/jpeg', 'x sha-2'],
        ],
        'see attached',
      ];
      expect(received.eventId,
          sha256.convert(utf8.encode(jsonEncode(payload))).toString());
    });

    test('a plain message with no references or attachments', () async {
      await aliceToBob(alice).sendDm(
        aNote(id: 'p1', authorPubkey: alice.public, kind: kDmTextKind, conversationId: 1),
        receiverPubkey: bob.public,
      );

      expect(await isar.eventQueueModels.count(), 1);
      expect(await isar.noteModels.count(), 1);
    });

    test('without a private key it throws before touching storage', () async {
      await expectLater(
        aliceToBob(alice, withKey: false).sendDm(
          aNote(id: 'p1', kind: kDmTextKind, conversationId: 1),
          receiverPubkey: bob.public,
        ),
        throwsException,
      );

      expect(await isar.noteModels.count(), 0);
      expect(await isar.eventQueueModels.count(), 0);
    });

    test('a local save that fails stops before anything is queued', () async {
      final msg = aNote(id: 'dup', kind: kDmTextKind, conversationId: 1);
      await aliceToBob(alice).sendDm(msg, receiverPubkey: bob.public);
      await isar.writeTxn(() => isar.eventQueueModels.clear());

      await expectLater(
        aliceToBob(alice).sendDm(msg, receiverPubkey: bob.public),
        throwsException,
      );

      expect(await isar.eventQueueModels.count(), 0);
    });

    test('a receiver key that is not a pubkey fails the encryption step',
        () async {
      await expectLater(
        aliceToBob(alice).sendDm(
          aNote(id: 'p1', kind: kDmTextKind, conversationId: 1),
          receiverPubkey: 'not-a-pubkey',
        ),
        throwsA(anything),
      );

      expect(await isar.eventQueueModels.count(), 0);
    });
  });
}

Future<void> _until(Future<bool> Function() cond) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!await cond()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in 10s');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
