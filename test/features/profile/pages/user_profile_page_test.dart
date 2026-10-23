import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/note_card/cubit/note_card_cubit.dart';
import 'package:uniun/core/router/app_routes.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/features/profile/bloc/user_profile_bloc.dart';
import 'package:uniun/features/profile/pages/user_profile_page.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockProfileBloc extends MockBloc<UserProfileEvent, UserProfileState>
    implements UserProfileBloc {}

class _MockNoteCardCubit extends MockCubit<NoteCardState>
    implements NoteCardCubit {}

/// Covers: the empty-args pop, loading, header (name fallbacks, nip05, about,
/// short npub + copy), self vs other actions, follow/following/busy, message
/// navigation, the notes list and its empty label, tap-through to a thread.
void main() {
  final hex = 'ab' * 32;
  late _MockProfileBloc bloc;

  setUpAll(() {
    registerFallbackValue(const ToggleFollowEvent());
    registerFallbackValue(const LoadUserProfileEvent('x'));
  });

  setUp(() async {
    bloc = _MockProfileBloc();
    final card = _MockNoteCardCubit();
    when(() => card.state).thenReturn(const NoteCardState());
    when(() => card.note).thenReturn(aNote(id: 'n1'));
    await GetIt.instance.reset();
    GetIt.instance
      ..registerFactory<UserProfileBloc>(() => bloc)
      ..registerFactoryParam<NoteCardCubit, NoteEntity, void>((_, __) => card);
  });

  tearDown(() => GetIt.instance.reset());

  Widget host({UserProfileArgs? args, List<Page<void>>? extra}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => UserProfilePage(
            args: args ?? UserProfileArgs(pubkeyHex: hex),
          ),
        ),
        GoRoute(
          name: AppRoutes.createDm,
          path: '/dm',
          builder: (_, s) => Scaffold(body: Text('dm ${s.extra}')),
        ),
        GoRoute(
          name: AppRoutes.thread,
          path: '/thread/:noteId',
          builder: (_, s) =>
              Scaffold(body: Text('thread ${s.pathParameters['noteId']}')),
        ),
        GoRoute(
          name: AppRoutes.home,
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('home')),
        ),
      ],
    );
    return MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }

  void stub(UserProfileState s) => when(() => bloc.state).thenReturn(s);

  testWidgets('loading shows a spinner and no header', (t) async {
    stub(UserProfileState(pubkeyHex: hex, loading: true));

    await t.pumpWidget(host());
    await t.pump();

    expect(find.text('Notes'.toUpperCase()), findsNothing);
    expect(find.byType(CustomScrollView), findsNothing);
  });

  testWidgets('opening requests the profile with the hint name', (t) async {
    stub(UserProfileState(pubkeyHex: hex, loading: true));

    await t.pumpWidget(
      host(args: UserProfileArgs(pubkeyHex: hex, hintName: 'Hint')),
    );

    final e =
        verify(() => bloc.add(captureAny())).captured.single
            as LoadUserProfileEvent;
    expect(e.pubkeyHex, hex);
    expect(e.hintName, 'Hint');
  });

  testWidgets('args with an empty pubkey render an empty page', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UserProfilePage(args: UserProfileArgs(pubkeyHex: '')),
      ),
    );
    await t.pump();

    expect(find.byType(Scaffold), findsOneWidget);
    verifyNever(() => bloc.add(any()));
  });

  testWidgets('null args render an empty page', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UserProfilePage(args: null),
      ),
    );
    await t.pump();

    expect(find.byType(CustomScrollView), findsNothing);
  });

  group('header', () {
    testWidgets('shows name, verified handle, about and the short npub', (
      t,
    ) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          profile: aProfile(
            pubkey: hex,
            name: 'नमस्ते 🌍',
            nip05: ' a@b.com ',
            about: ' about me ',
          ),
        ),
      );

      await t.pumpWidget(host());
      await t.pump();

      // The name appears in the app bar and in the header.
      expect(find.text('नमस्ते 🌍'), findsNWidgets(2));
      expect(find.text('a@b.com'), findsOneWidget);
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
      expect(find.text('about me'), findsOneWidget);
      expect(find.textContaining('npub1'), findsOneWidget);
      expect(find.textContaining('…'), findsOneWidget);
    });

    testWidgets('no nip05 and no about draw neither', (t) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          profile: aProfile(pubkey: hex, nip05: '  ', about: '  '),
        ),
      );

      await t.pumpWidget(host());
      await t.pump();

      expect(find.byIcon(Icons.verified_rounded), findsNothing);
    });

    testWidgets('name falls back to username, then hint, then short hex', (
      t,
    ) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          profile: aProfile(pubkey: hex, name: ' ', username: 'alice_u'),
        ),
      );
      await t.pumpWidget(host());
      await t.pump();
      expect(find.text('alice_u'), findsNWidgets(2));

      stub(
        UserProfileState(
          pubkeyHex: hex,
          hintName: ' Hinted ',
          profile: aProfile(pubkey: hex, name: null),
        ),
      );
      await t.pumpWidget(host());
      await t.pump();
      expect(find.text('Hinted'), findsNWidgets(2));

      stub(UserProfileState(pubkeyHex: hex));
      await t.pumpWidget(host());
      await t.pump();
      expect(find.text('${hex.substring(0, 12)}…'), findsNWidgets(2));
    });

    testWidgets('a short hex is shown whole as the fallback name', (t) async {
      stub(const UserProfileState(pubkeyHex: 'abcd'));

      await t.pumpWidget(host());
      await t.pump();

      expect(find.text('abcd'), findsWidgets);
    });

    testWidgets('copying the npub puts it on the clipboard', (t) async {
      final copied = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copied.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      stub(UserProfileState(pubkeyHex: hex, profile: aProfile(pubkey: hex)));

      await t.pumpWidget(host());
      await t.pump();
      await t.tap(find.byIcon(Icons.content_copy_rounded));
      await t.pump();

      expect(
        ((copied.single.arguments as Map)['text'] as String),
        startsWith('npub1'),
      );
      expect(find.text('npub copied'), findsOneWidget);
    });

    testWidgets('the back button goes home when nothing is below', (t) async {
      stub(UserProfileState(pubkeyHex: hex, profile: aProfile(pubkey: hex)));

      await t.pumpWidget(host());
      await t.pump();
      await t.tap(find.byIcon(Icons.arrow_back_ios_new).first);
      await t.pumpAndSettle();

      expect(find.text('home'), findsOneWidget);
    });
  });

  group('actions', () {
    testWidgets('your own profile has no follow or message buttons', (
      t,
    ) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          isSelf: true,
          profile: aProfile(pubkey: hex),
        ),
      );

      await t.pumpWidget(host());
      await t.pump();

      expect(find.text('Follow'), findsNothing);
      expect(find.text('Message'), findsNothing);
    });

    testWidgets('Follow sends the toggle event', (t) async {
      stub(UserProfileState(pubkeyHex: hex, profile: aProfile(pubkey: hex)));

      await t.pumpWidget(host());
      await t.pump();
      await t.tap(find.text('Follow'));

      verify(() => bloc.add(any(that: isA<ToggleFollowEvent>()))).called(1);
    });

    testWidgets('a followed user shows Following, which toggles back', (
      t,
    ) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          isFollowing: true,
          profile: aProfile(pubkey: hex),
        ),
      );

      await t.pumpWidget(host());
      await t.pump();
      expect(find.text('Follow'), findsNothing);
      await t.tap(find.text('Following'));

      verify(() => bloc.add(any(that: isA<ToggleFollowEvent>()))).called(1);
    });

    testWidgets('while busy the follow button is disabled', (t) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          busy: true,
          profile: aProfile(pubkey: hex),
        ),
      );

      await t.pumpWidget(host());
      await t.pump();
      await t.tap(find.text('Follow'));

      verifyNever(() => bloc.add(any(that: isA<ToggleFollowEvent>())));
    });

    testWidgets('Message opens a DM with the pubkey', (t) async {
      stub(UserProfileState(pubkeyHex: hex, profile: aProfile(pubkey: hex)));

      await t.pumpWidget(host());
      await t.pump();
      await t.tap(find.text('Message'));
      await t.pumpAndSettle();

      expect(find.text('dm $hex'), findsOneWidget);
    });
  });

  group('notes', () {
    testWidgets('no notes shows the empty label', (t) async {
      stub(UserProfileState(pubkeyHex: hex, profile: aProfile(pubkey: hex)));

      await t.pumpWidget(host());
      await t.pump();

      expect(find.text('No notes yet'), findsOneWidget);
      expect(find.text('NOTES'), findsOneWidget);
    });

    testWidgets('notes are listed and tapping one opens its thread', (
      t,
    ) async {
      stub(
        UserProfileState(
          pubkeyHex: hex,
          profile: aProfile(pubkey: hex),
          notes: [aNote(id: 'n1', content: 'first note body')],
        ),
      );

      await t.pumpWidget(host());
      await t.pump();

      expect(find.text('No notes yet'), findsNothing);
      await t.tap(find.text('first note body'));
      await t.pumpAndSettle();

      expect(find.text('thread n1'), findsOneWidget);
    });
  });
}
