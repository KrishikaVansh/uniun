import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/data/models/dm/dm_conversation_model.dart';
import 'package:uniun/data/repositories/dm_conversation_repository_impl.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';
import '../../_helpers/stub_user_repository.dart';

/// Covers: DmConversationRepositoryImpl get/save/delete with pubkey
/// normalization (npub decode, case-folding, trim), idempotent get-or-create,
/// and listing order.
void main() {
  late Isar isar;
  late DmConversationRepositoryImpl repo;

  setUp(() async {
    isar = await openTestIsar();
    repo = DmConversationRepositoryImpl(
      isar: isar,
      signer: MeshEventSigner(StubUserRepository()..keys = null),
    );
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  group('saveConversation', () {
    test('creates a row keyed by the normalized pubkey', () async {
      final r = await repo.saveConversation(
          aDmConversation(relays: ['wss://r1']));
      expect(r.isRight(), isTrue);
      final e = r.getOrElse(() => throw 'unreachable');
      expect(e.otherPubkey, kSampleTargetPubkeyHex);
      expect(e.relays, ['wss://r1']);

      final rows = await isar.dmConversationModels.where().findAll();
      expect(rows, hasLength(1));
    });

    test('get-or-create: second save returns the existing conversation '
        'and does not overwrite relays', () async {
      final first = await repo.saveConversation(
          aDmConversation(relays: ['wss://original']));
      final second = await repo.saveConversation(
          aDmConversation(relays: ['wss://different']));

      final firstId = first.getOrElse(() => throw 'unreachable').id;
      final e = second.getOrElse(() => throw 'unreachable');
      expect(e.id, firstId);
      expect(e.relays, ['wss://original']);
      expect(await isar.dmConversationModels.count(), 1);
    });

    test('uppercase hex input is folded to lowercase before storing',
        () async {
      await repo.saveConversation(aDmConversation(
          otherPubkey: kSampleTargetPubkeyHex.toUpperCase()));
      final row = (await isar.dmConversationModels.where().findAll()).single;
      expect(row.otherPubkey, kSampleTargetPubkeyHex);
    });

    test('npub input decodes to the same conversation as the hex form',
        () async {
      final npub = Nip19.encodePubkey(kSampleTargetPubkeyHex);
      await repo.saveConversation(aDmConversation());
      final r = await repo.saveConversation(
          aDmConversation(otherPubkey: npub));
      expect(r.isRight(), isTrue);
      expect(await isar.dmConversationModels.count(), 1);
    });

    test('surrounding whitespace is trimmed', () async {
      await repo
          .saveConversation(aDmConversation(otherPubkey: '  $kSampleTargetPubkeyHex\n'));
      final row = (await isar.dmConversationModels.where().findAll()).single;
      expect(row.otherPubkey, kSampleTargetPubkeyHex);
    });

    test('malformed pubkey (short label) → Left', () async {
      final r = await repo.saveConversation(
          aDmConversation(otherPubkey: 'not-a-pubkey'));
      expect(r.isLeft(), isTrue);
      expect(await isar.dmConversationModels.count(), 0);
    });
  });

  group('getConversationByOtherPubkey', () {
    test('finds by hex, npub, and uppercase input alike', () async {
      await seedDmConversation(isar, kSampleTargetPubkeyHex);

      for (final input in [
        kSampleTargetPubkeyHex,
        kSampleTargetPubkeyHex.toUpperCase(),
        Nip19.encodePubkey(kSampleTargetPubkeyHex),
      ]) {
        final r = await repo.getConversationByOtherPubkey(input);
        expect(r.isRight(), isTrue, reason: 'input $input');
        expect(r.getOrElse(() => throw 'unreachable').otherPubkey,
            kSampleTargetPubkeyHex);
      }
    });

    test('unknown pubkey → Left(notFoundFailure)', () async {
      final r =
          await repo.getConversationByOtherPubkey(kSampleEventIdHex);
      expect(r.isLeft(), isTrue);
    });

    test('malformed input → Left (normalizer throws)', () async {
      final r = await repo.getConversationByOtherPubkey('garbage');
      expect(r.isLeft(), isTrue);
    });
  });

  group('getConversations', () {
    test('empty database → Right(empty)', () async {
      final r = await repo.getConversations();
      expect(r.isRight(), isTrue);
      expect(r.getOrElse(() => throw 'unreachable'), isEmpty);
    });

    test('returns all conversations sorted by otherPubkey', () async {
      await seedDmConversation(isar, 'c' * 64);
      await seedDmConversation(isar, 'a' * 64);
      await seedDmConversation(isar, 'b' * 64);

      final r = await repo.getConversations();
      final keys = r
          .getOrElse(() => throw 'unreachable')
          .map((c) => c.otherPubkey)
          .toList();
      expect(keys, ['a' * 64, 'b' * 64, 'c' * 64]);
    });
  });

  group('deleteConversation', () {
    test('tombstones the row instead of deleting it (accepts npub input)',
        () async {
      await seedDmConversation(isar, kSampleTargetPubkeyHex);
      final r = await repo
          .deleteConversation(Nip19.encodePubkey(kSampleTargetPubkeyHex));
      expect(r.isRight(), isTrue);
      // Mesh sync needs the state flip to survive: row stays, removedAt set.
      final row = (await isar.dmConversationModels.where().findAll()).single;
      expect(row.removedAt, isNotNull);
      final listed = await repo.getConversations();
      expect(listed.getOrElse(() => throw 'unreachable'), isEmpty);
    });

    test('re-saving a tombstoned conversation revives it', () async {
      await seedDmConversation(isar, kSampleTargetPubkeyHex);
      await repo.deleteConversation(kSampleTargetPubkeyHex);

      final r = await repo.saveConversation(aDmConversation());
      expect(r.isRight(), isTrue);
      final row = (await isar.dmConversationModels.where().findAll()).single;
      expect(row.removedAt, isNull);
    });

    test('idempotent on unknown pubkey', () async {
      final r = await repo.deleteConversation(kSampleTargetPubkeyHex);
      expect(r.isRight(), isTrue);
    });

    test('malformed input → Left', () async {
      final r = await repo.deleteConversation('garbage');
      expect(r.isLeft(), isTrue);
    });
  });

  group('ensureActive', () {
    late DmConversationRepositoryImpl signing;
    final selfPub = Keychain(kTestPrivHex).public;

    setUp(() {
      signing = DmConversationRepositoryImpl(
        isar: isar,
        signer: MeshEventSigner.fixed(
          privkeyHex: kTestPrivHex,
          pubkeyHex: selfPub,
        ),
      );
    });

    test('creates a signed conversation for a first-time peer', () async {
      final r = await signing.ensureActive(kAlicePub);

      final e = r.getOrElse(() => throw 'unreachable');
      expect(e.otherPubkey, kAlicePub);
      final row = (await isar.dmConversationModels.where().findFirst())!;
      expect(row.id, e.id);
      expect(row.removedAt, isNull);
      final signed = jsonDecode(row.signedNostrEvent!) as Map<String, dynamic>;
      expect(signed['pubkey'], selfPub);
    });

    test('stores the pubkey as given, without normalizing it', () async {
      await signing.ensureActive('MiXeD-Peer');

      final row = (await isar.dmConversationModels.where().findFirst())!;
      expect(row.otherPubkey, 'MiXeD-Peer');
    });

    test('returns an active conversation untouched', () async {
      final first = (await signing.ensureActive(kAlicePub)).getOrElse(() => throw 'x');
      final signedBefore =
          (await isar.dmConversationModels.where().findFirst())!.signedNostrEvent;

      final again = (await signing.ensureActive(kAlicePub)).getOrElse(() => throw 'x');

      expect(again.id, first.id);
      expect(await isar.dmConversationModels.count(), 1);
      expect((await isar.dmConversationModels.where().findFirst())!.signedNostrEvent,
          signedBefore);
    });

    test('reactivates a removed conversation and keeps its id and relays',
        () async {
      final first = (await signing.ensureActive(kAlicePub)).getOrElse(() => throw 'x');
      await isar.writeTxn(() async {
        final row = (await isar.dmConversationModels.where().findFirst())!;
        row.removedAt = DateTime(2026);
        row.relays = ['wss://keep'];
        await isar.dmConversationModels.put(row);
      });

      await signing.ensureActive(kAlicePub);

      final row = (await isar.dmConversationModels.where().findFirst())!;
      expect(row.id, first.id);
      expect(row.removedAt, isNull);
      expect(row.relays, ['wss://keep']);
    });

    test('with no identity the row is still created, unsigned', () async {
      final r = await repo.ensureActive(kAlicePub);

      expect(r.isRight(), isTrue);
      final row = (await isar.dmConversationModels.where().findFirst())!;
      expect(row.signedNostrEvent, isNull);
    });

    test('a signing failure does not stop the conversation being created',
        () async {
      final throwing = DmConversationRepositoryImpl(
        isar: isar,
        signer: MeshEventSigner(_ThrowingUsers()),
      );

      final r = await throwing.ensureActive(kAlicePub);

      expect(r.isRight(), isTrue);
      expect((await isar.dmConversationModels.where().findFirst())!.signedNostrEvent,
          isNull);
    });

    test('a closed database surfaces as Left', () async {
      await isar.close();

      expect((await signing.ensureActive(kAlicePub)).isLeft(), isTrue);
      isar = await openTestIsar();
    });
  });
}

class _ThrowingUsers extends StubUserRepository {
  @override
  Future<({String privkeyHex, String pubkeyHex})?> getActiveKeysHex() =>
      throw StateError('keystore unavailable');
}
