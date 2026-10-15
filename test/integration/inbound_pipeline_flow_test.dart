import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/data/models/blocked_user_model.dart';
import 'package:uniun/data/models/deleted_note_model.dart';
import 'package:uniun/data/models/dm/encrypted_dm_model.dart';
import 'package:uniun/data/models/encrypted_message_model.dart';
import 'package:uniun/data/models/missing_profile_pubkey_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/private_group_join_request_model.dart';
import 'package:uniun/data/models/private_group_model.dart';
import 'package:uniun/data/models/profile_model.dart';
import 'package:uniun/gateway/inbound/handlers/kind0_profile_handler.dart';
import 'package:uniun/gateway/inbound/handlers/kind1059_dm_handler.dart';
import 'package:uniun/gateway/inbound/handlers/kind1_note_handler.dart';
import 'package:uniun/gateway/inbound/handlers/kind9021_25_handler.dart';
import 'package:uniun/gateway/inbound/inbound_bus.dart';
import 'package:uniun/gateway/inbound/missing_profile_tracker.dart';
import 'package:uniun/gateway/session/nostr_frame.dart';
import 'package:uniun/gateway/session/relay_session.dart';

import '../_helpers/isar_test_harness.dart';

class _FakeSession extends Fake implements RelaySession {
  final controller = StreamController<InboundEvent>.broadcast();

  @override
  Stream<InboundEvent> get events => controller.stream;
}

/// End-to-end scenarios for relay → InboundBus → real handlers → Isar.
///
/// Only the WebSocket session is faked. Events are genuinely signed and go
/// through the real verifier, so tampering is caught by the real crypto.
void main() {
  late Isar isar;
  late _FakeSession session;
  late InboundBus bus;
  late StreamSubscription<InboundEvent> sub;
  late Keychain me;
  late Keychain alice;

  Future<void> boot({String? active}) async {
    bus = InboundBus(
      isar: isar,
      handlers: [
        Kind1NoteHandler(activePubkey: active ?? me.public),
        Kind0ProfileHandler(),
        Kind1059DmHandler(),
        Kind9021To9025Handler(activePubkey: active ?? me.public),
      ],
      missingProfileTracker: MissingProfileTracker(isar),
    );
    await bus.init();
    sub = bus.attach(session);
  }

  Map<String, dynamic> signed(
    Keychain who, {
    int kind = 1,
    String content = 'hi',
    List<List<String>> tags = const [],
  }) => Event.from(
    kind: kind,
    tags: tags,
    content: content,
    privkey: who.private,
  ).toJson();

  Future<void> deliver(Map<String, dynamic> raw) async {
    session.controller.add(InboundEvent('sub', raw));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  /// Polls for an async side effect that the bus does not await.
  Future<void> eventually(Future<bool> Function() cond) async {
    for (var i = 0; i < 60; i++) {
      if (await cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  setUp(() async {
    isar = await openTestIsar();
    session = _FakeSession();
    me = Keychain.generate();
    alice = Keychain.generate();
  });

  tearDown(() async {
    await sub.cancel();
    await bus.dispose();
    await session.controller.close();
    await isar.close(deleteFromDisk: true);
  });

  test(
    'a reply thread lands as notes, relation edge and unread rows',
    () async {
      await boot();
      final root = signed(alice, content: 'root post');
      final reply = signed(
        alice,
        content: 'a reply',
        tags: [
          ['e', root['id'] as String, '', 'root'],
          ['e', root['id'] as String, '', 'reply'],
        ],
      );

      await deliver(root);
      await deliver(reply);

      expect(await isar.noteModels.count(), 2);
      final stored = await isar.noteModels
          .where()
          .eventIdEqualTo(reply['id'] as String)
          .findFirst();
      expect(stored!.rootEventId, root['id']);
      expect(stored.replyToEventId, root['id']);
      final edges = await isar.noteRelationModels.where().findAll();
      expect(edges.map((e) => (e.parentId, e.childId)), [
        (root['id'], reply['id']),
      ]);
      expect(await isar.unreadNoteModels.count(), 2);
    },
  );

  test('own notes echoed back are stored but never marked unread', () async {
    await boot();
    await deliver(signed(me, content: 'mine'));
    expect(await isar.noteModels.count(), 1);
    expect(await isar.unreadNoteModels.count(), 0);
  });

  test('relay re-delivery of the same event is idempotent', () async {
    await boot();
    final e = signed(alice, content: 'once');
    await deliver(e);
    await deliver(e);
    await deliver(e);
    expect(await isar.noteModels.count(), 1);
    expect(await isar.unreadNoteModels.count(), 1);
  });

  test('a tampered event is dropped by the real verifier', () async {
    await boot();
    final e = signed(alice, content: 'original');
    e['content'] = 'tampered';
    await deliver(e);
    expect(await isar.noteModels.count(), 0);
    expect(await isar.missingProfilePubkeyModels.count(), 0);
  });

  test(
    'malformed events (wrong types, bad tags) never reach handlers',
    () async {
      await boot();
      final good = signed(alice);
      await deliver({...good, 'created_at': '123'});
      await deliver({
        ...good,
        'tags': ['not-a-list'],
      });
      await deliver({
        ...good,
        'tags': [
          [1, 2],
        ],
      });
      await deliver({'kind': 1});
      expect(await isar.noteModels.count(), 0);
    },
  );

  test('blocked authors and locally deleted notes never resync', () async {
    await boot();
    await isar.writeTxn(() async {
      await isar.blockedUserModels.put(
        BlockedUserModel()
          ..pubkeyHex = alice.public
          ..blockedAt = DateTime(2026),
      );
    });
    final bob = Keychain.generate();
    final bobNote = signed(bob, content: 'deleted by me');
    await isar.writeTxn(
      () => isar.deletedNoteModels.put(
        DeletedNoteModel()
          ..eventId = bobNote['id'] as String
          ..deletedAt = DateTime(2026),
      ),
    );
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    await deliver(signed(alice, content: 'from blocked'));
    await deliver(bobNote);
    await deliver(signed(bob, content: 'fresh from bob'));

    final notes = await isar.noteModels.where().findAll();
    expect(notes.map((n) => n.content), ['fresh from bob']);
  });

  test('profile arrives after its note: missing marker is cleared', () async {
    await boot();
    await deliver(signed(alice, content: 'first'));
    await eventually(
      () async => await isar.missingProfilePubkeyModels.count() == 1,
    );
    expect(
      (await isar.missingProfilePubkeyModels.where().findAll()).map(
        (m) => m.pubkey,
      ),
      [alice.public],
    );

    await deliver(
      signed(
        alice,
        kind: 0,
        content: jsonEncode({'name': 'alice', 'about': 'hi'}),
      ),
    );

    expect(await isar.missingProfilePubkeyModels.count(), 0);
    final profile = await isar.profileModels
        .where()
        .pubkeyEqualTo(alice.public)
        .findFirst();
    expect(profile!.username, 'alice');
  });

  test(
    'gift wraps are queued encrypted and the wrapper key is not tracked',
    () async {
      await boot();
      final wrapper = Keychain.generate();
      await deliver(
        signed(
          wrapper,
          kind: 1059,
          content: 'cipher',
          tags: [
            ['p', me.public],
          ],
        ),
      );

      final queued = await isar.encryptedDmModels.where().findAll();
      expect(queued, hasLength(1));
      expect(queued.single.pTagRef, me.public);
      expect(await isar.noteModels.count(), 0);
      expect(await isar.missingProfilePubkeyModels.count(), 0);
    },
  );

  test('join requests are kept only by the group admin', () async {
    await boot();
    await isar.writeTxn(
      () => isar.privateGroupModels.put(
        PrivateGroupModel()
          ..groupId = 'g1'
          ..mlsGroupId = 'm1'
          ..relays = const []
          ..name = 'G'
          ..description = ''
          ..adminPubkey = me.public,
      ),
    );

    await deliver(
      signed(
        alice,
        kind: 9021,
        content: 'kp',
        tags: [
          ['h', 'g1'],
        ],
      ),
    );
    await deliver(
      signed(
        alice,
        kind: 9023,
        content: 'blob',
        tags: [
          ['h', 'g1'],
        ],
      ),
    );

    expect(await isar.privateGroupJoinRequestModels.count(), 1);
    expect(await isar.encryptedMessageModels.count(), 1);
  });

  test('as a non-admin the same join request is not retained', () async {
    await boot(active: alice.public);
    await isar.writeTxn(
      () => isar.privateGroupModels.put(
        PrivateGroupModel()
          ..groupId = 'g1'
          ..mlsGroupId = 'm1'
          ..relays = const []
          ..name = 'G'
          ..description = ''
          ..adminPubkey = me.public,
      ),
    );

    await deliver(
      signed(
        Keychain.generate(),
        kind: 9021,
        content: 'kp',
        tags: [
          ['h', 'g1'],
        ],
      ),
    );
    expect(await isar.privateGroupJoinRequestModels.count(), 0);
  });
}
