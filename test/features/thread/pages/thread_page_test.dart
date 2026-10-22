import 'package:bloc_test/bloc_test.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/note_card/cubit/note_card_cubit.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/router/app_routes.dart';
import 'package:uniun/domain/entities/followed_note/thread_unread_marker.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_cubit.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_state.dart';
import 'package:uniun/features/thread/bloc/thread_bloc.dart';
import 'package:uniun/features/thread/pages/thread_page.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockThreadBloc extends MockBloc<ThreadEvent, ThreadState>
    implements ThreadBloc {}

class _MockNoteCardCubit extends MockCubit<NoteCardState>
    implements NoteCardCubit {}

class _MockComposerChat extends MockCubit<ComposerChatState>
    implements ComposerChatCubit {}

class _MockActiveProfile extends Mock implements GetActiveUserProfileUseCase {}

/// Covers: ThreadPage passing the bloc's unread markers to the thread view,
/// and the loading state.
void main() {
  late _MockThreadBloc bloc;

  setUpAll(() => registerFallbackValue(const LoadThreadEvent('x')));

  setUp(() async {
    bloc = _MockThreadBloc();
    final card = _MockNoteCardCubit();
    when(() => card.state).thenReturn(const NoteCardState());
    when(() => card.note).thenReturn(aNote(id: 'x'));
    final chat = _MockComposerChat();
    when(() => chat.state).thenReturn(const ComposerChatState());
    when(() => chat.close()).thenAnswer((_) async {});
    final profile = _MockActiveProfile();
    when(
      () => profile.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));
    await GetIt.instance.reset();
    GetIt.instance
      ..registerFactory<ThreadBloc>(() => bloc)
      ..registerFactoryParam<NoteCardCubit, NoteEntity, void>((_, __) => card)
      ..registerFactory<ComposerChatCubit>(() => chat)
      ..registerFactory<GetActiveUserProfileUseCase>(() => profile);
  });

  tearDown(() => GetIt.instance.reset());

  Widget host() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const ThreadPage(noteId: 'root'),
  );

  testWidgets('a loaded thread shows the unread markers from the bloc', (
    t,
  ) async {
    when(() => bloc.state).thenReturn(
      ThreadState(
        status: ThreadStatus.loaded,
        root: aNote(id: 'root'),
        replies: [
          aNote(id: 'r1'),
          aNote(id: 'r2'),
        ],
        unreadMarkers: const {
          'r1': ThreadUnreadMarker(unread: false, unreadInside: true),
        },
      ),
    );

    await t.pumpWidget(host());
    await t.pump();

    expect(find.text('New reply inside'), findsOneWidget);
  });

  testWidgets('the thread is requested on open', (t) async {
    when(() => bloc.state).thenReturn(const ThreadState());

    await t.pumpWidget(host());

    verify(() => bloc.add(any(that: isA<LoadThreadEvent>()))).called(1);
  });

  testWidgets('while loading no markers are drawn', (t) async {
    when(
      () => bloc.state,
    ).thenReturn(const ThreadState(status: ThreadStatus.loading));

    await t.pumpWidget(host());

    expect(find.text('New'), findsNothing);
  });

  group('opening a thread from a thread', () {
    /// The thread page at `/`, with stub pages for both thread routes that show
    /// which route and id they were opened with and can pop back.
    Widget routed({required bool isDraft}) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => ThreadPage(noteId: 'root', isDraft: isDraft),
          ),
          GoRoute(
            name: AppRoutes.thread,
            path: '/thread/:noteId',
            builder: (ctx, s) => Scaffold(
              body: TextButton(
                onPressed: () => ctx.pop(),
                child: Text('note ${s.pathParameters['noteId']}'),
              ),
            ),
          ),
          GoRoute(
            name: AppRoutes.draftThread,
            path: '/draft-thread/:draftId',
            builder: (ctx, s) => Scaffold(
              body: TextButton(
                onPressed: () => ctx.pop(),
                child: Text('draft ${s.pathParameters['draftId']}'),
              ),
            ),
          ),
        ],
      );
      return MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      );
    }

    void draftThreadState() => when(() => bloc.state).thenReturn(
      ThreadState(
        status: ThreadStatus.loaded,
        root: aNote(id: 'root', content: 'draft root'),
        parentNotes: [aNote(id: 'published-parent', content: 'the parent')],
        replies: [aNote(id: 'reply-draft', content: 'draft reply')],
        draftIds: const {'root', 'reply-draft'},
      ),
    );

    testWidgets('the page asks the bloc for a draft thread when opened on one',
        (t) async {
      draftThreadState();

      await t.pumpWidget(routed(isDraft: true));
      await t.pump();

      final load = verify(() => bloc.add(captureAny())).captured
          .whereType<LoadThreadEvent>()
          .single;
      expect(load.noteId, 'root');
      expect(load.draft, isTrue);
    });

    testWidgets('a draft reply opens the draft thread', (t) async {
      draftThreadState();
      await t.pumpWidget(routed(isDraft: true));
      await t.pump();

      await t.tap(find.textContaining('draft reply'));
      await t.pumpAndSettle();

      expect(find.text('draft reply-draft'), findsOneWidget);
    });

    testWidgets('a published parent opens the normal thread', (t) async {
      draftThreadState();
      await t.pumpWidget(routed(isDraft: true));
      await t.pump();

      await t.tap(find.textContaining('the parent'));
      await t.pumpAndSettle();

      expect(find.text('note published-parent'), findsOneWidget);
    });

    testWidgets('coming back reloads the draft thread as a draft thread',
        (t) async {
      draftThreadState();
      await t.pumpWidget(routed(isDraft: true));
      await t.pump();
      await t.tap(find.textContaining('draft reply'));
      await t.pumpAndSettle();

      await t.tap(find.text('draft reply-draft'));
      await t.pumpAndSettle();

      final loads = verify(() => bloc.add(captureAny())).captured
          .whereType<LoadThreadEvent>()
          .toList();
      expect(loads.last.noteId, 'root');
      expect(loads.last.draft, isTrue);
    });

    testWidgets('a normal thread is not requested as a draft thread',
        (t) async {
      when(() => bloc.state).thenReturn(ThreadState(
        status: ThreadStatus.loaded,
        root: aNote(id: 'root'),
        replies: [aNote(id: 'r1', content: 'a reply')],
      ));

      await t.pumpWidget(routed(isDraft: false));
      await t.pump();
      await t.tap(find.textContaining('a reply'));
      await t.pumpAndSettle();

      expect(find.text('note r1'), findsOneWidget);
      await t.tap(find.text('note r1'));
      await t.pumpAndSettle();
      final loads = verify(() => bloc.add(captureAny())).captured
          .whereType<LoadThreadEvent>()
          .toList();
      expect(loads.every((l) => !l.draft), isTrue);
    });
  });
}
