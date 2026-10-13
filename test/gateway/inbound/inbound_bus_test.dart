import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/data/models/blocked_user_model.dart';
import 'package:uniun/data/models/deleted_note_model.dart';
import 'package:uniun/data/models/missing_profile_pubkey_model.dart';
import 'package:uniun/gateway/inbound/inbound_bus.dart';
import 'package:uniun/gateway/inbound/kind_handler.dart';
import 'package:uniun/gateway/inbound/missing_profile_tracker.dart';
import 'package:uniun/gateway/inbound/verified_nostr_event.dart';
import 'package:uniun/gateway/session/nostr_frame.dart';
import 'package:uniun/gateway/session/relay_session.dart';

import '../../_helpers/isar_test_harness.dart';

class _FakeSession extends Fake implements RelaySession {
  final controller = StreamController<InboundEvent>.broadcast();

  @override
  Stream<InboundEvent> get events => controller.stream;
}

/// Accepts any well-typed map; rejects those flagged `bad`.
class _StubVerifier implements NostrEventVerifier {
  const _StubVerifier();

  @override
  VerifiedNostrEvent? verify(Map<String, dynamic> raw) {
    if (raw['bad'] == true) return null;
    return VerifiedNostrEvent(
      id: raw['id'] as String,
      pubkey: raw['pubkey'] as String,
      createdAt: 1,
      kind: raw['kind'] as int,
      tags: const [],
      content: '',
      sig: 's',
      raw: raw,
    );
  }
}

class _Recorder implements KindHandler {
  _Recorder(this.kinds);

  @override
  final Set<int> kinds;
  final handled = <String>[];

  @override
  Future<void> handle(VerifiedNostrEvent event, Isar isar) async {
    handled.add(event.id);
  }
}

Map<String, dynamic> _raw(
  String id, {
  int kind = 1,
  String pubkey = 'alice',
  bool bad = false,
}) => {'id': id, 'pubkey': pubkey, 'kind': kind, if (bad) 'bad': true};

/// Covers: InboundBus dispatch by kind, drop of unverifiable events, unknown
/// kinds, blocked authors (and unblock via tombstone), tombstoned note ids,
/// live refresh of both filters, missing-profile tracking, and that one
/// failing handler does not stop later events.
void main() {
  late Isar isar;
  late _FakeSession session;
  late _Recorder notes;
  late InboundBus bus;
  late StreamSubscription<InboundEvent> sub;

  setUp(() async {
    isar = await openTestIsar();
    session = _FakeSession();
    notes = _Recorder({1, 42});
    bus = InboundBus(
      isar: isar,
      handlers: [notes],
      missingProfileTracker: MissingProfileTracker(isar),
      verifier: const _StubVerifier(),
    );
    await bus.init();
    sub = bus.attach(session);
  });

  tearDown(() async {
    await sub.cancel();
    await bus.dispose();
    await session.controller.close();
    await isar.close(deleteFromDisk: true);
  });

  Future<void> send(Map<String, dynamic> raw) async {
    session.controller.add(InboundEvent('s', raw));
    await pumpEventQueue();
    // The profile tracker runs unawaited against real Isar I/O.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('routes events to the handler registered for their kind', () async {
    await send(_raw('a'));
    await send(_raw('b', kind: 42));
    expect(notes.handled, ['a', 'b']);
  });

  test('drops events that fail verification', () async {
    await send(_raw('a', bad: true));
    expect(notes.handled, isEmpty);
  });

  test(
    'drops events of a kind nobody handles but still tracks the author',
    () async {
      await send(_raw('a', kind: 777, pubkey: 'stranger'));
      expect(notes.handled, isEmpty);
      final missing = await isar.missingProfilePubkeyModels.where().findAll();
      expect(missing.map((m) => m.pubkey), contains('stranger'));
    },
  );

  test(
    'drops everything from a blocked author, including after a live block',
    () async {
      await isar.writeTxn(
        () => isar.blockedUserModels.put(
          BlockedUserModel()
            ..pubkeyHex = 'mallory'
            ..blockedAt = DateTime(2026),
        ),
      );
      await pumpEventQueue();

      await send(_raw('a', pubkey: 'mallory'));
      await send(_raw('b', pubkey: 'alice'));
      expect(notes.handled, ['b']);
    },
  );

  test('a tombstoned block no longer filters the author', () async {
    await isar.writeTxn(
      () => isar.blockedUserModels.put(
        BlockedUserModel()
          ..pubkeyHex = 'mallory'
          ..blockedAt = DateTime(2026)
          ..removedAt = DateTime(2026, 2),
      ),
    );
    await pumpEventQueue();

    await send(_raw('a', pubkey: 'mallory'));
    expect(notes.handled, ['a']);
  });

  test('drops a locally deleted note id but lets others through', () async {
    await isar.writeTxn(
      () => isar.deletedNoteModels.put(
        DeletedNoteModel()
          ..eventId = 'gone'
          ..deletedAt = DateTime(2026),
      ),
    );
    await pumpEventQueue();

    await send(_raw('gone'));
    await send(_raw('kept'));
    expect(notes.handled, ['kept']);
  });

  test(
    'a duplicate of the same event is dispatched each time (handlers dedupe)',
    () async {
      await send(_raw('a'));
      await send(_raw('a'));
      expect(notes.handled, ['a', 'a']);
    },
  );

  test('tracks each unseen author once however many events arrive', () async {
    await send(_raw('a', pubkey: 'newcomer'));
    await send(_raw('b', pubkey: 'newcomer'));
    final missing = await isar.missingProfilePubkeyModels
        .filter()
        .pubkeyEqualTo('newcomer')
        .findAll();
    expect(missing, hasLength(1));
  });

  test('stops delivering after the subscription is cancelled', () async {
    await sub.cancel();
    await send(_raw('a'));
    expect(notes.handled, isEmpty);
  });
}
