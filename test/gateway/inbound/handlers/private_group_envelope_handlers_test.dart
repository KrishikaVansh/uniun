import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/data/models/dm/encrypted_dm_model.dart';
import 'package:uniun/data/models/encrypted_message_model.dart';
import 'package:uniun/data/models/private_group_join_request_model.dart';
import 'package:uniun/data/models/private_group_model.dart';
import 'package:uniun/gateway/inbound/handlers/kind1059_dm_handler.dart';
import 'package:uniun/gateway/inbound/handlers/kind9002_handler.dart';
import 'package:uniun/gateway/inbound/handlers/kind9021_25_handler.dart';
import 'package:uniun/gateway/inbound/verified_nostr_event.dart';

import '../../../_helpers/isar_test_harness.dart';

const _admin = 'admin-pub';
const _alice = 'alice-pub';

VerifiedNostrEvent _event({
  required String id,
  required int kind,
  String pubkey = _alice,
  String content = '',
  List<List<String>> tags = const [],
  int createdAt = 1_700_000_000,
}) {
  return VerifiedNostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: 'sig',
    raw: {
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': 'sig',
    },
  );
}

PrivateGroupModel _group(String groupId, {String admin = _admin}) {
  return PrivateGroupModel()
    ..groupId = groupId
    ..mlsGroupId = 'mls-$groupId'
    ..relays = ['wss://old']
    ..name = 'Old name'
    ..description = 'Old about'
    ..adminPubkey = admin;
}

/// Covers: Kind 9002 metadata update (field mapping, missing fields keep old
/// values, unknown group and malformed JSON are no-ops), Kind 1059 envelope
/// storage (missing p tag dropped, duplicate delivery idempotent), and Kinds
/// 9021–9025 (admin-only join requests, verbatim envelopes, missing h tag).
void main() {
  late Isar isar;

  setUp(() async {
    isar = await openTestIsar();
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  group('Kind9002Handler', () {
    final handler = Kind9002Handler();

    test('declares kind 9002', () {
      expect(handler.kinds, {9002});
    });

    test(
      'updates name, about, relays and admin on the matching group',
      () async {
        await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));

        await handler.handle(
          _event(
            id: 'g1',
            kind: 9002,
            pubkey: 'new-admin',
            content: jsonEncode({
              'name': 'New 名前 🚀',
              'about': 'New about',
              'relays': ['wss://a', 'wss://b'],
            }),
          ),
          isar,
        );

        final g = await isar.privateGroupModels
            .where()
            .groupIdEqualTo('g1')
            .findFirst();
        expect(g!.name, 'New 名前 🚀');
        expect(g.description, 'New about');
        expect(g.adminPubkey, 'new-admin');
        expect(g.relays, ['wss://a', 'wss://b']);
      },
    );

    test(
      'keeps old name, about and relays when the metadata omits them',
      () async {
        await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));

        await handler.handle(
          _event(id: 'g1', kind: 9002, content: jsonEncode({'relays': []})),
          isar,
        );

        final g = await isar.privateGroupModels
            .where()
            .groupIdEqualTo('g1')
            .findFirst();
        expect(g!.name, 'Old name');
        expect(g.description, 'Old about');
        expect(g.relays, ['wss://old']);
      },
    );

    test('ignores metadata for a group that is not stored locally', () async {
      await handler.handle(
        _event(id: 'ghost', kind: 9002, content: jsonEncode({'name': 'x'})),
        isar,
      );
      expect(await isar.privateGroupModels.count(), 0);
    });

    test('ignores malformed and non-object JSON content', () async {
      await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));

      await handler.handle(
        _event(id: 'g1', kind: 9002, content: '{not json'),
        isar,
      );
      await handler.handle(
        _event(id: 'g1', kind: 9002, content: '[1,2]'),
        isar,
      );

      final g = await isar.privateGroupModels
          .where()
          .groupIdEqualTo('g1')
          .findFirst();
      expect(g!.name, 'Old name');
      expect(g.adminPubkey, _admin);
    });
  });

  group('Kind1059DmHandler', () {
    final handler = Kind1059DmHandler();

    test('declares kind 1059', () {
      expect(handler.kinds, {1059});
    });

    test('stores the encrypted envelope addressed by its p tag', () async {
      await handler.handle(
        _event(
          id: 'w1',
          kind: 1059,
          content: 'ciphertext',
          tags: [
            ['p', 'bob-pub'],
          ],
        ),
        isar,
      );

      final row = await isar.encryptedDmModels
          .where()
          .eventIdEqualTo('w1')
          .findFirst();
      expect(row, isNotNull);
      expect(row!.pTagRef, 'bob-pub');
      expect(row.authorPubkey, _alice);
      expect(row.content, 'ciphertext');
      expect(row.kind, 1059);
      expect(row.created.millisecondsSinceEpoch, 1_700_000_000 * 1000);
    });

    test('drops a gift wrap with no p tag', () async {
      await handler.handle(_event(id: 'w2', kind: 1059, content: 'x'), isar);
      expect(await isar.encryptedDmModels.count(), 0);
    });

    test('is idempotent when the same wrap is delivered twice', () async {
      final e = _event(
        id: 'w3',
        kind: 1059,
        content: 'x',
        tags: [
          ['p', 'bob-pub'],
        ],
      );
      await handler.handle(e, isar);
      await handler.handle(e, isar);
      expect(await isar.encryptedDmModels.count(), 1);
    });

    test('swallows a write failure on a closed database', () async {
      final closed = await openTestIsar();
      await closed.close(deleteFromDisk: true);
      await expectLater(
        handler.handle(
          _event(
            id: 'w4',
            kind: 1059,
            tags: [
              ['p', 'bob-pub'],
            ],
          ),
          closed,
        ),
        completes,
      );
    });
  });

  group('Kind9021To9025Handler', () {
    test('declares kinds 9021 to 9025', () {
      expect(Kind9021To9025Handler().kinds, {9021, 9022, 9023, 9024, 9025});
    });

    test('admin stores a join request once, even if re-delivered', () async {
      await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));
      final handler = Kind9021To9025Handler(activePubkey: _admin);
      final e = _event(
        id: 'j1',
        kind: 9021,
        content: 'kp-b64',
        tags: [
          ['h', 'g1'],
        ],
      );

      await handler.handle(e, isar);
      await handler.handle(e, isar);

      final rows = await isar.privateGroupJoinRequestModels.where().findAll();
      expect(rows, hasLength(1));
      expect(rows.single.senderPubkey, _alice);
      expect(rows.single.keyPackageB64, 'kp-b64');
      expect(rows.single.groupId, 'g1');
    });

    test('a non-admin member does not retain join requests', () async {
      await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));
      final handler = Kind9021To9025Handler(activePubkey: 'someone-else');

      await handler.handle(
        _event(
          id: 'j1',
          kind: 9021,
          tags: [
            ['h', 'g1'],
          ],
        ),
        isar,
      );
      expect(await isar.privateGroupJoinRequestModels.count(), 0);
    });

    test('no active identity or unknown group stores nothing', () async {
      await isar.writeTxn(() => isar.privateGroupModels.put(_group('g1')));
      final e1 = _event(
        id: 'j1',
        kind: 9021,
        tags: [
          ['h', 'g1'],
        ],
      );
      final e2 = _event(
        id: 'j2',
        kind: 9021,
        tags: [
          ['h', 'unknown'],
        ],
      );

      await Kind9021To9025Handler().handle(e1, isar);
      await Kind9021To9025Handler(activePubkey: _admin).handle(e2, isar);

      expect(await isar.privateGroupJoinRequestModels.count(), 0);
    });

    test('stores kinds 9022-9025 verbatim and idempotently', () async {
      final handler = Kind9021To9025Handler(activePubkey: _admin);
      for (final k in [9022, 9023, 9024, 9025]) {
        final e = _event(
          id: 'm$k',
          kind: k,
          content: 'blob-$k',
          tags: [
            ['h', 'g1'],
          ],
        );
        await handler.handle(e, isar);
        await handler.handle(e, isar);
      }

      final rows = await isar.encryptedMessageModels.where().findAll();
      expect(rows, hasLength(4));
      final r = rows.firstWhere((m) => m.kind == 9024);
      expect(r.encryptedPayload, 'blob-9024');
      expect(r.groupId, 'g1');
      expect(r.senderPubkey, _alice);
    });

    test('events without an h tag are dropped', () async {
      final handler = Kind9021To9025Handler(activePubkey: _admin);
      await handler.handle(_event(id: 'x1', kind: 9023, content: 'c'), isar);
      await handler.handle(_event(id: 'x2', kind: 9021, content: 'c'), isar);
      expect(await isar.encryptedMessageModels.count(), 0);
      expect(await isar.privateGroupJoinRequestModels.count(), 0);
    });

    test(
      'closed database is swallowed for envelopes and join requests',
      () async {
        final handler = Kind9021To9025Handler(activePubkey: _admin);
        final closed = await openTestIsar();
        await closed.close(deleteFromDisk: true);
        await expectLater(
          handler.handle(
            _event(
              id: 'c1',
              kind: 9023,
              tags: [
                ['h', 'g1'],
              ],
            ),
            closed,
          ),
          completes,
        );
      },
    );
  });
}
