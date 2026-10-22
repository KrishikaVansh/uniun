import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/entities/followed_note/thread_unread_marker.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/repositories/note_resolver_repository.dart';
import 'package:uniun/domain/usecases/draft_usecases.dart';
import 'package:uniun/domain/usecases/followed_note_usecases.dart';
import 'package:uniun/domain/usecases/post_reply_usecase.dart';
import 'package:uniun/domain/usecases/profile_usecases.dart';
import 'package:uniun/domain/usecases/saved_note_usecases.dart';
import 'package:uniun/domain/usecases/unread_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/thread/bloc/thread_bloc.dart';

import '../../../_helpers/fixtures.dart';

class _MockResolver extends Mock implements NoteResolverRepository {}

class _MockPostReply extends Mock implements PostReplyUseCase {}

class _MockGetProfile extends Mock implements GetProfileUseCase {}

class _MockGetAllSaved extends Mock implements GetAllSavedNotesUseCase {}

class _MockGetSavedReplies extends Mock implements GetSavedRepliesUseCase {}

class _MockGetSavedReferences extends Mock
    implements GetSavedReferencesUseCase {}

class _MockMarkSeen extends Mock implements MarkUnreadSeenUseCase {}

class _MockWatchMarkers extends Mock
    implements WatchThreadUnreadMarkersUseCase {}

class _MockGetDraft extends Mock implements GetDraftByIdUseCase {}

class _MockGetDraftReplies extends Mock implements GetDraftRepliesUseCase {}

class _MockSaveDraft extends Mock implements SaveDraftUseCase {}

class _MockGetActiveUser extends Mock implements GetActiveUserUseCase {}

/// Covers: ThreadBloc's normal-mode load (root resolution failure, parent
/// chain via the reply marker, mention resolution, replies, profile
/// hydration across every visible author), savedOnly-mode load (root/
/// references/replies all sourced from the saved-note edge table, note-not-
/// found), the loading-placeholder suppression once already loaded, and
/// post's guards + savedOnly's feed-sourceOverride + success reload +
/// failure.
void main() {
  late _MockResolver resolver;
  late _MockPostReply postReply;
  late _MockGetProfile getProfile;
  late _MockGetAllSaved getAllSaved;
  late _MockGetSavedReplies getSavedReplies;
  late _MockGetSavedReferences getSavedReferences;
  late _MockMarkSeen markSeen;
  late _MockWatchMarkers watchMarkers;
  late _MockGetDraft getDraft;
  late _MockGetDraftReplies getDraftReplies;
  late _MockSaveDraft saveDraft;
  late _MockGetActiveUser getActiveUser;

  ThreadBloc build() => ThreadBloc(
        resolver,
        postReply,
        getProfile,
        getAllSaved,
        getSavedReplies,
        getSavedReferences,
        markSeen,
        watchMarkers,
        getDraft,
        getDraftReplies,
        saveDraft,
        getActiveUser,
      );

  setUpAll(() {
    registerFallbackValue(PostReplyParams(root: aNote(), content: ''));
    registerFallbackValue(aDraft());
  });

  setUp(() {
    resolver = _MockResolver();
    postReply = _MockPostReply();
    getProfile = _MockGetProfile();
    getAllSaved = _MockGetAllSaved();
    getSavedReplies = _MockGetSavedReplies();
    getSavedReferences = _MockGetSavedReferences();
    markSeen = _MockMarkSeen();
    watchMarkers = _MockWatchMarkers();
    getDraft = _MockGetDraft();
    getDraftReplies = _MockGetDraftReplies();
    saveDraft = _MockSaveDraft();
    getActiveUser = _MockGetActiveUser();
    when(() => getActiveUser.call())
        .thenAnswer((_) async => Right(aUserKey(pubkeyHex: kSelfPub)));
    when(() => getDraftReplies.call(any()))
        .thenAnswer((_) async => const Right([]));
    when(() => markSeen.call(any()))
        .thenAnswer((_) async => const Right(unit));
    when(() => watchMarkers.call(any()))
        .thenAnswer((_) => const Stream.empty());

    when(() => getAllSaved.call()).thenAnswer((_) async => const Right([]));
    when(() => getProfile.call(any()))
        .thenAnswer((_) async => const Left(Failure.errorFailure('not found')));
    when(() => resolver.resolveNoteById(any())).thenAnswer((_) async => const Right(null));
    when(() => resolver.resolveMany(any())).thenAnswer((_) async => const Right([]));
    when(() => resolver.resolveReplies(any())).thenAnswer((_) async => const Right([]));
    when(() => getSavedReferences.call(any())).thenAnswer((_) async => const Right([]));
    when(() => getSavedReplies.call(any())).thenAnswer((_) async => const Right([]));
  });

  group('LoadThreadEvent (normal mode)', () {
    test('a resolution failure surfaces an error', () async {
      when(() => resolver.resolveById('n1'))
          .thenAnswer((_) async => const Left(Failure.errorFailure('not found')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('n1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.error);
      expect(bloc.state.errorMessage, isNotNull);
      await bloc.close();
    });

    test('resolves the parent via the reply marker and mentions via '
        'eTagRefs minus root/reply markers', () async {
      final root = aNote(
        id: 'root-1',
        replyToEventId: 'parent-1',
        eTagRefs: ['parent-1', 'mention-1'],
      );
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(root));
      when(() => resolver.resolveNoteById('parent-1'))
          .thenAnswer((_) async => Right(aNote(id: 'parent-1')));
      when(() => resolver.resolveMany(['mention-1']))
          .thenAnswer((_) async => Right([aNote(id: 'mention-1')]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.parentNotes.map((n) => n.id), ['parent-1']);
      expect(bloc.state.mentionedNotes.map((n) => n.id), ['mention-1']);
      await bloc.close();
    });

    test('loads replies and hydrates a profile per distinct visible author',
        () async {
      final root = aNote(id: 'root-1', authorPubkey: 'alice');
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(root));
      when(() => resolver.resolveReplies('root-1')).thenAnswer(
          (_) async => Right([aNote(id: 'reply-1', authorPubkey: 'bob')]));
      when(() => getProfile.call('alice')).thenAnswer((_) async => Right(aProfile(pubkey: 'alice')));
      when(() => getProfile.call('bob')).thenAnswer((_) async => Right(aProfile(pubkey: 'bob')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.replies.map((n) => n.id), ['reply-1']);
      expect(bloc.state.profiles.keys, containsAll(['alice', 'bob']));
      await bloc.close();
    });

    test('the saved-ids set is populated even in normal mode, for '
        'bookmark marking', () async {
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(aNote(id: 'root-1')));
      when(() => getAllSaved.call()).thenAnswer((_) async => Right([aSavedNote(eventId: 'saved-1')]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.savedOnlyIds, {'saved-1'});
      expect(bloc.state.savedOnly, isFalse);
      await bloc.close();
    });

    test('a reload once already loaded does not show the loading '
        'placeholder', () async {
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(aNote(id: 'root-1')));
      final bloc = build();
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.status, ThreadStatus.loaded);

      final states = <ThreadState>[];
      final sub = bloc.stream.listen(states.add);
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(states.any((s) => s.status == ThreadStatus.loading), isFalse);
      await sub.cancel();
      await bloc.close();
    });
  });

  group('unread handling', () {
    test('opening a thread marks that note read', () async {
      when(() => resolver.resolveById('root-1'))
          .thenAnswer((_) async => Right(aNote(id: 'root-1')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(() => markSeen.call('root-1')).called(1);
      await bloc.close();
    });

    test('replies are not marked read just by being listed', () async {
      when(() => resolver.resolveById('root-1'))
          .thenAnswer((_) async => Right(aNote(id: 'root-1')));
      when(() => resolver.resolveReplies('root-1')).thenAnswer(
          (_) async => Right([aNote(id: 'reply-1'), aNote(id: 'reply-2')]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyNever(() => markSeen.call('reply-1'));
      verifyNever(() => markSeen.call('reply-2'));
      await bloc.close();
    });

    test('saved-only mode does not mark anything read', () async {
      final bloc = build();

      bloc.add(const LoadThreadEvent('n1', savedOnly: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyNever(() => markSeen.call(any()));
      await bloc.close();
    });

    test('markers are watched for the root and every reply', () async {
      when(() => resolver.resolveById('root-1'))
          .thenAnswer((_) async => Right(aNote(id: 'root-1')));
      when(() => resolver.resolveReplies('root-1')).thenAnswer(
          (_) async => Right([aNote(id: 'reply-1'), aNote(id: 'reply-2')]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(() => watchMarkers.call(['root-1', 'reply-1', 'reply-2']))
          .called(1);
      await bloc.close();
    });

    test('marker updates reach the state, and an empty update clears them',
        () async {
      final controller = StreamController<Map<String, ThreadUnreadMarker>>();
      when(() => watchMarkers.call(any())).thenAnswer((_) => controller.stream);
      when(() => resolver.resolveById('root-1'))
          .thenAnswer((_) async => Right(aNote(id: 'root-1')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controller.add({
        'reply-1': const ThreadUnreadMarker(unread: true, unreadInside: false),
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.unreadMarkers.keys, ['reply-1']);

      controller.add(const {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bloc.state.unreadMarkers, isEmpty);

      await bloc.close();
      await controller.close();
    });

    test('a reload replaces the old marker subscription', () async {
      var listeners = 0;
      when(() => watchMarkers.call(any())).thenAnswer((_) {
        return Stream<Map<String, ThreadUnreadMarker>>.multi((c) {
          listeners++;
          c.onCancel = () => listeners--;
        });
      });
      when(() => resolver.resolveById('root-1'))
          .thenAnswer((_) async => Right(aNote(id: 'root-1')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(listeners, 1);

      await bloc.close();
      expect(listeners, 0);
    });
  });

  group('LoadThreadEvent (savedOnly mode)', () {
    test('note not found in the saved set surfaces an error', () async {
      final bloc = build();

      bloc.add(const LoadThreadEvent('missing', savedOnly: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.error);
      verifyZeroInteractions(resolver);
      await bloc.close();
    });

    test('resolves root/references/replies entirely from the saved-note '
        'edge table', () async {
      when(() => getAllSaved.call()).thenAnswer((_) async => Right([aSavedNote(eventId: 'root-1')]));
      when(() => getSavedReferences.call('root-1'))
          .thenAnswer((_) async => Right([aSavedNote(eventId: 'ref-1')]));
      when(() => getSavedReplies.call('root-1'))
          .thenAnswer((_) async => Right([aSavedNote(eventId: 'reply-1')]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1', savedOnly: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.savedOnly, isTrue);
      expect(bloc.state.root?.id, 'root-1');
      expect(bloc.state.rootNote?.id, 'root-1'); // alias getter
      expect(bloc.state.mentionedNotes.map((n) => n.id), ['ref-1']);
      expect(bloc.state.replies.map((n) => n.id), ['reply-1']);
      verifyZeroInteractions(resolver);
      await bloc.close();
    });

    test('saved replies are sorted chronologically ascending', () async {
      when(() => getAllSaved.call()).thenAnswer((_) async => Right([aSavedNote(eventId: 'root-1')]));
      when(() => getSavedReplies.call('root-1')).thenAnswer((_) async => Right([
            aSavedNote(eventId: 'newer', created: DateTime(2026, 1, 2)),
            aSavedNote(eventId: 'older', created: DateTime(2026, 1, 1)),
          ]));
      final bloc = build();

      bloc.add(const LoadThreadEvent('root-1', savedOnly: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.replies.map((n) => n.id), ['older', 'newer']);
      await bloc.close();
    });
  });

  group('PostReplyEvent', () {
    test('empty content and no attachments with a loaded root is a no-op',
        () async {
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(aNote(id: 'root-1')));
      final bloc = build();
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bloc.add(const PostReplyEvent('   '));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyZeroInteractions(postReply);
      await bloc.close();
    });

    test('no root loaded yet is a no-op', () async {
      final bloc = build();

      bloc.add(const PostReplyEvent('hi'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyZeroInteractions(postReply);
      await bloc.close();
    });

    test('success clears postStatus and reloads the thread', () async {
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(aNote(id: 'root-1')));
      when(() => postReply.call(any())).thenAnswer((_) async => const Right(unit));
      final bloc = build();
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bloc.add(const PostReplyEvent('a reply'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.postStatus, ThreadPostStatus.idle);
      verify(() => resolver.resolveById('root-1')).called(2); // initial load + reload
      await bloc.close();
    });

    test('savedOnly mode forces sourceOverride to feed', () async {
      when(() => getAllSaved.call()).thenAnswer((_) async => Right([aSavedNote(eventId: 'root-1')]));
      when(() => postReply.call(any())).thenAnswer((_) async => const Right(unit));
      final bloc = build();
      bloc.add(const LoadThreadEvent('root-1', savedOnly: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bloc.add(const PostReplyEvent('a reply'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final params = verify(() => postReply.call(captureAny())).captured.single as PostReplyParams;
      expect(params.sourceOverride, NoteSource.feed);
      await bloc.close();
    });

    test('a failure surfaces an error without reloading', () async {
      when(() => resolver.resolveById('root-1')).thenAnswer((_) async => Right(aNote(id: 'root-1')));
      when(() => postReply.call(any()))
          .thenAnswer((_) async => const Left(Failure.errorFailure('relay down')));
      final bloc = build();
      bloc.add(const LoadThreadEvent('root-1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      bloc.add(const PostReplyEvent('a reply'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.postStatus, ThreadPostStatus.error);
      expect(bloc.state.errorMessage, isNotNull);
      verify(() => resolver.resolveById('root-1')).called(1); // no reload
      await bloc.close();
    });
  });

  group('a thread opened on a draft', () {
    Future<ThreadBloc> loaded(
      DraftEntity draft, {
      List<DraftEntity> replies = const [],
    }) async {
      when(() => getDraft.call(draft.draftId))
          .thenAnswer((_) async => Right(draft));
      when(() => getDraftReplies.call(draft.draftId))
          .thenAnswer((_) async => Right(replies));
      final bloc = build();
      bloc.add(LoadThreadEvent(draft.draftId, draft: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return bloc;
    }

    test('the draft is the root, authored by the active user, and its replies '
        'are the drafts that reference it', () async {
      final bloc = await loaded(
        aDraft(draftId: 'd1', content: 'नमस्ते 🌍'),
        replies: [aDraft(draftId: 'd2', draftRefIds: ['d1'])],
      );

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.root!.id, 'd1');
      expect(bloc.state.root!.content, 'नमस्ते 🌍');
      expect(bloc.state.root!.authorPubkey, kSelfPub);
      expect(bloc.state.replies.map((r) => r.id), ['d2']);
      expect(bloc.state.draftIds, {'d1', 'd2'});
      verifyNever(() => resolver.resolveById(any()));
      await bloc.close();
    });

    test('nothing is marked read and no unread markers are watched',
        () async {
      final bloc = await loaded(aDraft(draftId: 'd1'));

      verifyNever(() => markSeen.call(any()));
      verifyNever(() => watchMarkers.call(any()));
      await bloc.close();
    });

    test('a draft written as a reply shows its published parent and its '
        'mentions above it', () async {
      when(() => resolver.resolveNoteById('parent-1'))
          .thenAnswer((_) async => Right(aNote(id: 'parent-1')));
      when(() => resolver.resolveMany(['mention-1']))
          .thenAnswer((_) async => Right([aNote(id: 'mention-1')]));
      final bloc = await loaded(aDraft(
        draftId: 'd1',
        rootEventId: 'parent-1',
        replyToEventId: 'parent-1',
        eTagRefs: ['parent-1', 'mention-1'],
      ));

      expect(bloc.state.parentNotes.map((n) => n.id), ['parent-1']);
      expect(bloc.state.mentionedNotes.map((n) => n.id), ['mention-1']);
      await bloc.close();
    });

    test('a parent that is no longer stored is simply left out', () async {
      final bloc = await loaded(
          aDraft(draftId: 'd1', replyToEventId: 'gone', eTagRefs: ['gone']));

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.parentNotes, isEmpty);
      await bloc.close();
    });

    test('profiles are loaded for the author when one exists', () async {
      when(() => getProfile.call(kSelfPub))
          .thenAnswer((_) async => Right(aProfile(pubkey: kSelfPub)));
      final bloc = await loaded(aDraft(draftId: 'd1'));

      expect(bloc.state.profiles.keys, [kSelfPub]);
      await bloc.close();
    });

    test('with no active user the draft still opens, with no author profile',
        () async {
      when(() => getActiveUser.call()).thenAnswer(
          (_) async => const Left(Failure.errorFailure('signed out')));
      final bloc = await loaded(aDraft(draftId: 'd1'));

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.root!.authorPubkey, isEmpty);
      verifyNever(() => getProfile.call(any()));
      await bloc.close();
    });

    test('failing to read the replies shows the draft with none', () async {
      when(() => getDraft.call('d1'))
          .thenAnswer((_) async => Right(aDraft(draftId: 'd1')));
      when(() => getDraftReplies.call('d1')).thenAnswer(
          (_) async => const Left(Failure.errorFailure('read failed')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('d1', draft: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.loaded);
      expect(bloc.state.replies, isEmpty);
      await bloc.close();
    });

    test('a draft that no longer exists surfaces an error', () async {
      when(() => getDraft.call('gone')).thenAnswer(
          (_) async => const Left(Failure.notFoundFailure('no draft')));
      final bloc = build();

      bloc.add(const LoadThreadEvent('gone', draft: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.status, ThreadStatus.error);
      expect(bloc.state.errorMessage, 'no draft');
      await bloc.close();
    });

    test('a reload once loaded keeps the thread on screen', () async {
      final bloc = await loaded(aDraft(draftId: 'd1'));
      final states = <ThreadStatus>[];
      final sub = bloc.stream.listen((s) => states.add(s.status));

      bloc.add(const LoadThreadEvent('d1', draft: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(states, isNot(contains(ThreadStatus.loading)));
      await sub.cancel();
      await bloc.close();
    });

    test('replying saves a new draft that references this one, with its '
        'hashtags, and reloads', () async {
      when(() => saveDraft.call(any())).thenAnswer(
          (i) async => Right(i.positionalArguments.first as DraftEntity));
      final bloc = await loaded(aDraft(draftId: 'd1'));

      bloc.add(const PostReplyEvent('  agreed #plans  '));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final saved = verify(() => saveDraft.call(captureAny())).captured.single
          as DraftEntity;
      expect(saved.content, 'agreed #plans');
      expect(saved.draftRefIds, ['d1']);
      expect(saved.tTags, ['plans']);
      expect(saved.draftId, isNot('d1'));
      expect(saved.rootEventId, isNull);
      verifyNever(() => postReply.call(any()));
      verify(() => getDraft.call('d1')).called(2); // load + reload
      expect(bloc.state.postStatus, ThreadPostStatus.idle);
      await bloc.close();
    });

    test('a reply with only attachments is not saved', () async {
      final bloc = await loaded(aDraft(draftId: 'd1'));

      bloc.add(PostReplyEvent('  ', attachments: [aMediaBlob()]));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verifyNever(() => saveDraft.call(any()));
      await bloc.close();
    });

    test('a failed save surfaces an error and does not reload', () async {
      when(() => saveDraft.call(any())).thenAnswer(
          (_) async => const Left(Failure.errorFailure('disk full')));
      final bloc = await loaded(aDraft(draftId: 'd1'));

      bloc.add(const PostReplyEvent('hello'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(bloc.state.postStatus, ThreadPostStatus.error);
      expect(bloc.state.errorMessage, 'disk full');
      verify(() => getDraft.call('d1')).called(1);
      await bloc.close();
    });
  });
}
