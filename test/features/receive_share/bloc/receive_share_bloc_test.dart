import 'package:bloc_test/bloc_test.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:uniun/common/widgets/composer/media_pick_helper.dart';
import 'package:uniun/common/widgets/composer/uniun_composer.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/inputs/share_note_input.dart';
import 'package:uniun/domain/usecases/create_group_message_usecase.dart';
import 'package:uniun/domain/usecases/dm_usecases.dart';
import 'package:uniun/domain/usecases/draft_usecases.dart';
import 'package:uniun/domain/usecases/get_groups_usecase.dart';
import 'package:uniun/domain/usecases/media_usecases.dart';
import 'package:uniun/domain/usecases/note_usecases.dart';
import 'package:uniun/domain/usecases/private_group_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/receive_share/bloc/receive_share_bloc.dart';
import 'package:uniun/features/receive_share/widgets/shared_incoming.dart';

import '../../../_helpers/fixtures.dart';

class _MockGetGroups extends Mock implements GetGroupsUseCase {}

class _MockGetPrivateGroups extends Mock implements GetPrivateGroupsUsecase {}

class _MockGetDms extends Mock implements GetDmConversationsUseCase {}

class _MockGetActiveUser extends Mock implements GetActiveUserUseCase {}

class _MockGetKeys extends Mock implements GetActiveUserKeysUseCase {}

class _MockUploadMedia extends Mock implements UploadMediaUseCase {}

class _MockSaveLocalMedia extends Mock implements SaveLocalMediaUseCase {}

class _MockPublishNote extends Mock implements PublishNoteUseCase {}

class _MockPublishMediaNote extends Mock implements PublishMediaNoteUseCase {}

class _MockPublishGroup extends Mock implements CreateGroupMessageUseCase {}

class _MockPublishDm extends Mock implements SendDmUseCase {}

class _MockPublishPrivate extends Mock
    implements SendPrivateGroupMessageUsecase {}

class _MockSaveDraft extends Mock implements SaveDraftUseCase {}

const _validPrivkeyHex =
    '1111111111111111111111111111111111111111111111111111111111111111';

PickedMedia _aPickedMedia({String sha256 = 'sha-1'}) => PickedMedia(
      bytes: Uint8List.fromList([1, 2, 3]),
      mime: 'image/jpeg',
      filename: 'a.jpg',
      sha256: sha256,
    );

/// Covers: ReceiveShareBloc's init (text prefill, destination fan-out
/// degrading independently, skipping a shared file that no longer exists
/// on disk), composer field reducers, the draft-save path (empty-content
/// guard, media staging + its failure path, success), and submit across
/// every ShareDestination variant plus its guards (already-submitting,
/// nothing-to-share, key-fetch failure, upload failure, publish exception).
void main() {
  late _MockGetGroups getGroups;
  late _MockGetPrivateGroups getPrivateGroups;
  late _MockGetDms getDms;
  late _MockGetActiveUser getActiveUser;
  late _MockGetKeys getKeys;
  late _MockUploadMedia uploadMedia;
  late _MockSaveLocalMedia saveLocalMedia;
  late _MockPublishNote publishNote;
  late _MockPublishMediaNote publishMediaNote;
  late _MockPublishGroup publishGroup;
  late _MockPublishDm publishDm;
  late _MockPublishPrivate publishPrivate;
  late _MockSaveDraft saveDraft;

  setUpAll(() {
    registerFallbackValue(UploadMediaInput(bytes: Uint8List(0), mime: 'image/jpeg'));
    registerFallbackValue(SaveLocalMediaInput(bytes: Uint8List(0), mime: 'image/jpeg'));
    registerFallbackValue(aNote());
    registerFallbackValue(PublishMediaNoteInput(note: aNote(), attachments: const []));
    registerFallbackValue(const CreateGroupMessageInput(groupId: '', content: '', privateKey: ''));
    registerFallbackValue(SendDmParams(otherPubkey: '', content: ''));
    registerFallbackValue(DraftEntity(
      draftId: '',
      content: '',
      eTagRefs: const [],
      pTagRefs: const [],
      tTags: const [],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ));
  });

  ReceiveShareBloc build() => ReceiveShareBloc(
        getGroups,
        getPrivateGroups,
        getDms,
        getActiveUser,
        getKeys,
        uploadMedia,
        saveLocalMedia,
        publishNote,
        publishMediaNote,
        publishGroup,
        publishDm,
        publishPrivate,
        saveDraft,
      );

  setUp(() {
    getGroups = _MockGetGroups();
    getPrivateGroups = _MockGetPrivateGroups();
    getDms = _MockGetDms();
    getActiveUser = _MockGetActiveUser();
    getKeys = _MockGetKeys();
    uploadMedia = _MockUploadMedia();
    saveLocalMedia = _MockSaveLocalMedia();
    publishNote = _MockPublishNote();
    publishMediaNote = _MockPublishMediaNote();
    publishGroup = _MockPublishGroup();
    publishDm = _MockPublishDm();
    publishPrivate = _MockPublishPrivate();
    saveDraft = _MockSaveDraft();

    when(() => getActiveUser()).thenAnswer((_) async => Right(aUserKey(pubkeyHex: 'self-pub')));
    when(() => getGroups()).thenAnswer((_) async => const Right([]));
    when(() => getPrivateGroups.execute()).thenAnswer((_) => Stream.value(const []));
    when(() => getDms()).thenAnswer((_) async => const Right([]));
  });

  group('InitReceiveShare', () {
    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'prefills content from the shared text and loads destinations',
      build: build,
      act: (b) => b.add(const ReceiveShareEvent.init(
        SharedIncoming(text: 'shared text', files: []),
      )),
      expect: () => [
        isA<ReceiveShareState>()
            .having((s) => s.loading, 'loading', true)
            .having((s) => s.content, 'content', 'shared text'),
        isA<ReceiveShareState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.authorPubkey, 'authorPubkey', 'self-pub')
            .having((s) => s.ingesting, 'ingesting', false),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'destination lists degrade to empty independently on failure',
      build: () {
        when(() => getGroups()).thenAnswer((_) async => const Left(Failure.errorFailure('boom')));
        when(() => getPrivateGroups.execute()).thenAnswer((_) => Stream.error(Exception('boom')));
        when(() => getDms()).thenAnswer((_) async => Right([aDmConversation(id: 1)]));
        return build();
      },
      act: (b) => b.add(const ReceiveShareEvent.init(SharedIncoming(text: null, files: []))),
      expect: () => [
        isA<ReceiveShareState>(),
        isA<ReceiveShareState>()
            .having((s) => s.publicGroups, 'publicGroups', isEmpty)
            .having((s) => s.privateGroups, 'privateGroups', isEmpty)
            .having((s) => s.dmConversations, 'dmConversations', hasLength(1)),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a shared file that no longer exists on disk is silently skipped, '
      'ingesting still flips back to false',
      build: build,
      act: (b) => b.add(ReceiveShareEvent.init(SharedIncoming(
        text: null,
        files: [
          SharedMediaFile(
            path: '/nonexistent/path/to/file.jpg',
            type: SharedMediaType.image,
          ),
        ],
      ))),
      wait: const Duration(milliseconds: 50),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.loading, 'loading', true),
        isA<ReceiveShareState>().having((s) => s.ingesting, 'ingesting', true),
        isA<ReceiveShareState>().having((s) => s.ingesting, 'ingesting', false),
      ],
      verify: (b) {
        expect(b.state.pending, isEmpty);
      },
    );

    // Not covered: a shared file that DOES exist on disk and successfully
    // ingests — `sharedFileToPicked` routes image bytes through
    // `ImageCompressor` (flutter_image_compress), a real native plugin with
    // no fake in this environment. Same category of ceiling as
    // FlutterEdgeAiGateway/SystemInfoPlus elsewhere in this repo's test
    // suite — the nonexistent-file branch above already proves the loop's
    // skip/continue wiring; only the compression step itself is untestable
    // here.
  });

  group('composer field reducers', () {
    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'contentChanged updates content',
      build: build,
      act: (b) => b.add(const ReceiveShareEvent.contentChanged('hi')),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.content, 'content', 'hi'),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'attachMedia appends, ignoring a duplicate sha256',
      build: build,
      act: (b) {
        b.add(ReceiveShareEvent.attachMedia(_aPickedMedia(sha256: 'a')));
        b.add(ReceiveShareEvent.attachMedia(_aPickedMedia(sha256: 'a')));
      },
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.pending, 'pending', hasLength(1)),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'removeMedia drops only the matching sha256',
      build: build,
      seed: () => ReceiveShareState(pending: [_aPickedMedia(sha256: 'a'), _aPickedMedia(sha256: 'b')]),
      act: (b) => b.add(const ReceiveShareEvent.removeMedia('a')),
      expect: () => [
        isA<ReceiveShareState>()
            .having((s) => s.pending.map((m) => m.sha256), 'pending', ['b']),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'setReferences replaces the list, removeReference drops one id',
      build: build,
      act: (b) {
        b.add(const ReceiveShareEvent.setReferences(
          [ComposerReference(id: 'r1', label: 'R1'), ComposerReference(id: 'r2', label: 'R2')],
        ));
        b.add(const ReceiveShareEvent.removeReference('r1'));
      },
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.references, 'references', hasLength(2)),
        isA<ReceiveShareState>()
            .having((s) => s.references.map((r) => r.id), 'references', ['r2']),
      ],
    );
  });

  group('SaveReceiveDraft', () {
    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'empty content and no media surfaces draft-needs-text without '
      'calling the use case',
      build: build,
      act: (b) => b.add(const ReceiveShareEvent.saveToDraft()),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.error, 'error', 'draft-needs-text'),
      ],
      verify: (_) {
        verifyZeroInteractions(saveDraft);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'stages pending media then saves a draft with hashtags extracted',
      build: () {
        when(() => saveLocalMedia(any())).thenAnswer((invocation) async {
          final input = invocation.positionalArguments.first as SaveLocalMediaInput;
          return Right(MediaBlobEntity(sha256: 'staged', mime: input.mime, sizeBytes: input.bytes.length));
        });
        when(() => saveDraft.call(any())).thenAnswer((i) async => Right(i.positionalArguments.first as DraftEntity));
        return build();
      },
      seed: () => ReceiveShareState(content: 'hello #dart #flutter', pending: [_aPickedMedia()]),
      act: (b) => b.add(const ReceiveShareEvent.saveToDraft()),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.draftSaved, 'draftSaved', true),
      ],
      verify: (_) {
        final draft = verify(() => saveDraft.call(captureAny())).captured.single as DraftEntity;
        expect(draft.content, 'hello #dart #flutter');
        expect(draft.tTags, containsAll(['dart', 'flutter']));
        expect(draft.attachments, hasLength(1));
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a media staging failure aborts before saveDraft is called',
      build: () {
        when(() => saveLocalMedia(any()))
            .thenAnswer((_) async => const Left(Failure.errorFailure('disk full')));
        return build();
      },
      seed: () => ReceiveShareState(content: 'hello', pending: [_aPickedMedia()]),
      act: (b) => b.add(const ReceiveShareEvent.saveToDraft()),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.error, 'error', isNotNull),
      ],
      verify: (_) {
        verifyZeroInteractions(saveDraft);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a saveDraft repository failure surfaces the error',
      build: () {
        when(() => saveDraft.call(any()))
            .thenAnswer((_) async => const Left(Failure.errorFailure('isar write failed')));
        return build();
      },
      seed: () => ReceiveShareState(content: 'hello'),
      act: (b) => b.add(const ReceiveShareEvent.saveToDraft()),
      expect: () => [
        isA<ReceiveShareState>()
            .having((s) => s.error, 'error', isNotNull)
            .having((s) => s.draftSaved, 'draftSaved', false),
      ],
    );
  });

  group('SubmitReceiveShare', () {
    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a second submit while one is in flight is a no-op',
      build: build,
      seed: () => const ReceiveShareState(submitting: true, content: 'hi'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => <ReceiveShareState>[],
      verify: (_) {
        verifyZeroInteractions(getKeys);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'empty content and no pending media surfaces nothing-to-share',
      build: build,
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.error, 'error', 'nothing-to-share'),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a key-fetch failure surfaces the error before any upload attempt',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Left(Failure.errorFailure('no active user')));
        return build();
      },
      seed: () => const ReceiveShareState(content: 'hi'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.submitting, 'submitting', true),
        isA<ReceiveShareState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.error, 'error', isNotNull),
      ],
      verify: (_) {
        verifyZeroInteractions(uploadMedia);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'an upload failure aborts, keeping the pending picks',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => uploadMedia(any())).thenAnswer((_) async => const Left(Failure.errorFailure('upload failed')));
        return build();
      },
      seed: () => ReceiveShareState(content: 'hi', pending: [_aPickedMedia()]),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.submitting, 'submitting', true),
        isA<ReceiveShareState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.error, 'error', isNotNull)
            .having((s) => s.pending, 'pending', hasLength(1)),
      ],
      verify: (_) {
        verifyZeroInteractions(publishNote);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'feed destination, no attachments: publishes via PublishNoteUseCase',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => publishNote.call(any())).thenAnswer((i) async => Right(i.positionalArguments.first as NoteEntity));
        return build();
      },
      seed: () => const ReceiveShareState(content: 'hello #dart'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.submitting, 'submitting', true),
        isA<ReceiveShareState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.submitted, 'submitted', true),
      ],
      verify: (_) {
        final note = verify(() => publishNote.call(captureAny())).captured.single as NoteEntity;
        expect(note.content, 'hello #dart');
        expect(note.tTags, ['dart']);
        verifyZeroInteractions(publishMediaNote);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'feed destination with attachments routes through PublishMediaNoteUseCase',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => uploadMedia(any())).thenAnswer((invocation) async {
          final input = invocation.positionalArguments.first as UploadMediaInput;
          return Right(MediaBlobEntity(sha256: 'up', mime: input.mime, sizeBytes: input.bytes.length));
        });
        when(() => publishMediaNote.call(any()))
            .thenAnswer((i) async => Right((i.positionalArguments.first as PublishMediaNoteInput).note));
        return build();
      },
      seed: () => ReceiveShareState(content: 'a photo', pending: [_aPickedMedia()]),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.submitting, 'submitting', true),
        isA<ReceiveShareState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.submitted, 'submitted', true),
      ],
      verify: (_) {
        verifyZeroInteractions(publishNote);
        verify(() => publishMediaNote.call(any())).called(1);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'a feed publish failure is caught and surfaces as an error',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => publishNote.call(any()))
            .thenAnswer((_) async => const Left(Failure.errorFailure('isar write failed')));
        return build();
      },
      seed: () => const ReceiveShareState(content: 'hello'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.feed())),
      expect: () => [
        isA<ReceiveShareState>().having((s) => s.submitting, 'submitting', true),
        isA<ReceiveShareState>()
            .having((s) => s.submitting, 'submitting', false)
            .having((s) => s.submitted, 'submitted', false)
            .having((s) => s.error, 'error', isNotNull),
      ],
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'public-group destination forwards to CreateGroupMessageUseCase',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => publishGroup.call(any())).thenAnswer((_) async => Right(aGroupMessage(groupId: 'g1')));
        return build();
      },
      seed: () => const ReceiveShareState(content: 'group share'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.publicGroup(groupId: 'g1'))),
      verify: (_) {
        final input = verify(() => publishGroup.call(captureAny())).captured.single as CreateGroupMessageInput;
        expect(input.groupId, 'g1');
        expect(input.content, 'group share');
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'private-group destination forwards to SendPrivateGroupMessageUsecase',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => publishPrivate.execute(
              groupId: any(named: 'groupId'),
              content: any(named: 'content'),
              authorPubkey: any(named: 'authorPubkey'),
              privkeyHex: any(named: 'privkeyHex'),
              mentionRefs: any(named: 'mentionRefs'),
              attachments: any(named: 'attachments'),
            )).thenAnswer((_) async {});
        return build();
      },
      seed: () => const ReceiveShareState(content: 'secret share'),
      act: (b) => b.add(const ReceiveShareEvent.submit(ShareDestination.privateGroup(groupId: 'pg1'))),
      verify: (_) {
        verify(() => publishPrivate.execute(
              groupId: 'pg1',
              content: 'secret share',
              authorPubkey: 'self-pub',
              privkeyHex: _validPrivkeyHex,
              mentionRefs: const [],
              attachments: const [],
            )).called(1);
      },
    );

    blocTest<ReceiveShareBloc, ReceiveShareState>(
      'DM destination forwards to SendDmUseCase with an image type when '
      'attachments are present',
      build: () {
        when(() => getKeys())
            .thenAnswer((_) async => const Right(UserSigningKeys(privkeyHex: _validPrivkeyHex, pubkeyHex: 'self-pub')));
        when(() => uploadMedia(any())).thenAnswer((invocation) async {
          final input = invocation.positionalArguments.first as UploadMediaInput;
          return Right(MediaBlobEntity(sha256: 'up', mime: input.mime, sizeBytes: input.bytes.length));
        });
        when(() => publishDm.call(any())).thenAnswer((_) async => const Right(unit));
        return build();
      },
      seed: () => ReceiveShareState(content: 'a dm photo', pending: [_aPickedMedia()]),
      act: (b) =>
          b.add(const ReceiveShareEvent.submit(ShareDestination.dm(otherPubkeyHex: 'peer'))),
      verify: (_) {
        final params = verify(() => publishDm.call(captureAny())).captured.single as SendDmParams;
        expect(params.otherPubkey, 'peer');
        expect(params.type.name, 'image');
      },
    );
  });
}
