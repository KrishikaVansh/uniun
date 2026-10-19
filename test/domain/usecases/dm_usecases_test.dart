import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/repositories/dm_conversation_repository_impl.dart';
import 'package:uniun/data/repositories/event_queue_repository_impl.dart';
import 'package:uniun/data/repositories/nip17_repository_impl.dart';
import 'package:uniun/data/repositories/note_relation_repository_impl.dart';
import 'package:uniun/data/repositories/profile_repository_impl.dart';
import 'package:uniun/domain/entities/dm/dm_conversation_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/repositories/dm_conversation_repository.dart';
import 'package:uniun/domain/repositories/dm_message_repository.dart';
import 'package:uniun/domain/usecases/dm_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_test_harness.dart';

class _MockDmConversationRepository extends Mock
    implements DmConversationRepository {}

class _MockDmMessageRepository extends Mock implements DmMessageRepository {}

class _MockGetActiveUserKeys extends Mock
    implements GetActiveUserKeysUseCase {}

/// A syntactically valid 32-byte-hex secp256k1 scalar — required by
/// SendDmUseCase's own `^[0-9a-fA-F]{64}$` guard before it will attempt to
/// encrypt/sign anything.
const _validPrivkeyHex =
    '1111111111111111111111111111111111111111111111111111111111111111';

/// The use case wired to real repositories over [isar]; only the conversation
/// store is mocked.
SendDmUseCase _sendDm(
  Isar isar,
  GetActiveUserKeysUseCase getKeys,
  DmConversationRepository convRepo,
) =>
    SendDmUseCase(
      Nip17RepositoryImpl(
        isar: isar,
        relations: NoteRelationRepositoryImpl(isar: isar),
        conversations: convRepo,
      ),
      EventQueueRepositoryImpl(isar: isar),
      ProfileRepositoryImpl(isar: isar),
      getKeys,
      convRepo,
    );

GetDmUseCase _getDm(Isar isar, GetActiveUserKeysUseCase getKeys) => GetDmUseCase(
      Nip17RepositoryImpl(
        isar: isar,
        relations: NoteRelationRepositoryImpl(isar: isar),
        conversations: DmConversationRepositoryImpl(
          isar: isar,
          signer: MeshEventSigner.fixed(
            privkeyHex: _validPrivkeyHex,
            pubkeyHex: Keychain(_validPrivkeyHex).public,
          ),
        ),
      ),
      EventQueueRepositoryImpl(isar: isar),
      ProfileRepositoryImpl(isar: isar),
      getKeys,
    );

void main() {
  setUpAll(() {
    registerFallbackValue(aDmConversation());
  });

  group('GetDmConversationsUseCase', () {
    test('delegates to getConversations', () async {
      final repo = _MockDmConversationRepository();
      when(() => repo.getConversations())
          .thenAnswer((_) async => Right([aDmConversation()]));

      final result = await GetDmConversationsUseCase(repo).call();

      expect(result.getOrElse(() => []), hasLength(1));
    });
  });

  group('CreateDmConversationUseCase', () {
    test('normalizes the other pubkey then saves a new conversation',
        () async {
      final repo = _MockDmConversationRepository();
      when(() => repo.saveConversation(any())).thenAnswer(
          (i) async => Right(i.positionalArguments.first as DmConversationEntity));

      final result = await CreateDmConversationUseCase(repo).call(
        CreateDmParams(otherPubkey: kSampleTargetPubkeyHex, relays: const []),
      );

      expect(result.isRight(), isTrue);
      final captured =
          verify(() => repo.saveConversation(captureAny())).captured.single
              as DmConversationEntity;
      expect(captured.otherPubkey, kSampleTargetPubkeyHex);
    });

    test('a malformed pubkey is caught and surfaced as Left, not a throw',
        () async {
      final repo = _MockDmConversationRepository();

      final result = await CreateDmConversationUseCase(repo)
          .call(CreateDmParams(otherPubkey: 'not-a-pubkey', relays: const []));

      expect(result.isLeft(), isTrue);
      verifyZeroInteractions(repo);
    });
  });

  group('FetchDmUseCase', () {
    late _MockDmConversationRepository convRepo;
    late _MockDmMessageRepository msgRepo;

    setUp(() {
      convRepo = _MockDmConversationRepository();
      msgRepo = _MockDmMessageRepository();
    });

    test('no conversation yet degrades to an empty list, not a failure',
        () async {
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => const Left(Failure.errorFailure('not found')));

      final result = await FetchDmUseCase(convRepo, msgRepo).call(kSampleTargetPubkeyHex);

      expect(result, const Right<Failure, List<NoteEntity>>([]));
      verifyZeroInteractions(msgRepo);
    });

    test('sorts messages newest-first regardless of repository order',
        () async {
      final conv = aDmConversation(id: 7);
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => Right(conv));
      final older = aDmText(conversationId: 7, id: 'older', content: 'first')
          .copyWith(created: DateTime(2026, 1, 1));
      final newer = aDmText(conversationId: 7, id: 'newer', content: 'second')
          .copyWith(created: DateTime(2026, 1, 2));
      when(() => msgRepo.getMessages(7, limit: 100))
          .thenAnswer((_) async => Right([older, newer]));

      final result = await FetchDmUseCase(convRepo, msgRepo).call(kSampleTargetPubkeyHex);

      final ids = result.getOrElse(() => []).map((n) => n.id).toList();
      expect(ids, ['newer', 'older']);
    });

    test('a message-fetch failure surfaces as Left', () async {
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => Right(aDmConversation(id: 1)));
      when(() => msgRepo.getMessages(1, limit: 100)).thenAnswer(
          (_) async => const Left(Failure.errorFailure('isar read failed')));

      final result = await FetchDmUseCase(convRepo, msgRepo).call(kSampleTargetPubkeyHex);

      expect(result.isLeft(), isTrue);
    });

    test('a malformed pubkey is caught and surfaced as Left', () async {
      final result = await FetchDmUseCase(convRepo, msgRepo).call('not-a-pubkey');

      expect(result.isLeft(), isTrue);
      verifyZeroInteractions(convRepo);
    });
  });

  group('SendDmUseCase (real Isar + real NIP-17 encryption)', () {
    late Isar isar;
    late _MockDmConversationRepository convRepo;
    late _MockGetActiveUserKeys getKeys;

    setUp(() async {
      isar = await openTestIsar();
      convRepo = _MockDmConversationRepository();
      getKeys = _MockGetActiveUserKeys();
    });

    tearDown(() async {
      await isar.close(deleteFromDisk: true);
    });

    test('a key-fetch failure short-circuits before any Isar write',
        () async {
      const failure = Failure.errorFailure('no active user');
      when(() => getKeys.call()).thenAnswer((_) async => const Left(failure));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(otherPubkey: kSampleTargetPubkeyHex, content: 'hi'),
      );

      expect(result, const Left<Failure, Unit>(failure));
      expect(await isar.noteModels.count(), 0);
    });

    test('an invalid-length privkey is rejected before any Isar write',
        () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: 'too-short', pubkeyHex: 'self-pub'),
          ));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(otherPubkey: kSampleTargetPubkeyHex, content: 'hi'),
      );

      expect(result.isLeft(), isTrue);
      expect(await isar.noteModels.count(), 0);
    });

    test('a malformed destination pubkey is caught as Left', () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub'),
          ));

      final result = await _sendDm(isar, getKeys, convRepo)
          .call(SendDmParams(otherPubkey: 'not-a-pubkey', content: 'hi'));

      expect(result.isLeft(), isTrue);
    });

    test('happy path: auto-creates the conversation, persists a local '
        'Kind-14 rumor, and enqueues the Kind-1059 gift wrap', () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub'),
          ));
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => const Left(Failure.errorFailure('no conversation yet')));
      when(() => convRepo.saveConversation(any())).thenAnswer(
          (i) async => Right(i.positionalArguments.first as DmConversationEntity));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(otherPubkey: kSampleTargetPubkeyHex, content: 'hello there'),
      );

      expect(result, const Right<Failure, Unit>(unit));
      verify(() => convRepo.saveConversation(any())).called(1);

      final localMessages = await isar.noteModels.where().findAll();
      expect(localMessages, hasLength(1));
      expect(localMessages.single.content, 'hello there');
      expect(localMessages.single.sig, isEmpty); // deniable, per NIP-17

      final queued = await isar.eventQueueModels.where().findAll();
      expect(queued, hasLength(1));
      expect(queued.single.kind, 1059);
      expect(queued.single.pTagRefs, [kSampleTargetPubkeyHex]);
    });

    test('reuses an existing conversation instead of creating a new one',
        () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub'),
          ));
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => Right(aDmConversation(id: 42, otherPubkey: kSampleTargetPubkeyHex)));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(otherPubkey: kSampleTargetPubkeyHex, content: 'hi again'),
      );

      expect(result, const Right<Failure, Unit>(unit));
      verifyNever(() => convRepo.saveConversation(any()));
      final localMessages = await isar.noteModels.where().findAll();
      expect(localMessages.single.conversationId, 42);
    });

    test('an nsec1-prefixed privkeyHex is decoded before use', () async {
      when(() => getKeys.call()).thenAnswer((_) async => Right(
            UserSigningKeys(
              privkeyHex: Nip19.encodePrivkey(_validPrivkeyHex),
              pubkeyHex: 'self-pub',
            ),
          ));
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => Right(aDmConversation(id: 1, otherPubkey: kSampleTargetPubkeyHex)));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(otherPubkey: kSampleTargetPubkeyHex, content: 'hi'),
      );

      expect(result, const Right<Failure, Unit>(unit));
    });

    test('attachments are carried into the local NoteModel as '
        'MediaAttachment rows', () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub'),
          ));
      when(() => convRepo.getConversationByOtherPubkey(kSampleTargetPubkeyHex))
          .thenAnswer((_) async => Right(aDmConversation(id: 1, otherPubkey: kSampleTargetPubkeyHex)));

      final result = await _sendDm(isar, getKeys, convRepo).call(
        SendDmParams(
          otherPubkey: kSampleTargetPubkeyHex,
          content: 'a photo',
          attachments: [aMediaBlob(sha256: 'sha-abc', mime: 'image/png')],
        ),
      );

      expect(result, const Right<Failure, Unit>(unit));
      final localMessages = await isar.noteModels.where().findAll();
      expect(localMessages.single.attachments, hasLength(1));
      expect(localMessages.single.attachments.single.sha256, 'sha-abc');
      expect(localMessages.single.attachments.single.mime, 'image/png');
    });
  });

  group('GetDmUseCase (real Isar)', () {
    late Isar isar;
    late _MockGetActiveUserKeys getKeys;

    setUp(() async {
      isar = await openTestIsar();
      getKeys = _MockGetActiveUserKeys();
    });

    tearDown(() async {
      await isar.close(deleteFromDisk: true);
    });

    test('an empty inbound queue drains cleanly to Right(unit)', () async {
      when(() => getKeys.call()).thenAnswer((_) async => const Right(
            UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub'),
          ));

      final result = await _getDm(isar, getKeys).call();

      expect(result, const Right<Failure, Unit>(unit));
    });

    test('a key-fetch failure surfaces as Left', () async {
      const failure = Failure.errorFailure('no active user');
      when(() => getKeys.call()).thenAnswer((_) async => const Left(failure));

      final result = await _getDm(isar, getKeys).call();

      expect(result, const Left<Failure, Unit>(failure));
    });
  });
}
