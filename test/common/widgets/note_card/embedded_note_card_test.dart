import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/note_card/cubit/note_card_cubit.dart';
import 'package:uniun/common/widgets/note_card/embedded_note_card.dart';
import 'package:uniun/core/router/app_routes.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockNoteCardCubit extends MockCubit<NoteCardState>
    implements NoteCardCubit {}

/// Covers: placeholder for a missing embed, name fallback chain, the
/// unverified badge for a blanked signature, the "read more" hint for long or
/// multi-line content, and tap-through to the thread route.
void main() {
  late _MockNoteCardCubit card;

  setUp(() async {
    card = _MockNoteCardCubit();
    when(() => card.state).thenReturn(const NoteCardState());
    await GetIt.instance.reset();
    GetIt.instance.registerFactoryParam<NoteCardCubit, NoteEntity, void>(
      (_, __) => card,
    );
  });

  tearDown(() => GetIt.instance.reset());

  Widget host(NoteEntity? note, {void Function(String)? onThread}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(body: EmbeddedNoteCard(note: note)),
        ),
        GoRoute(
          name: AppRoutes.thread,
          path: '/thread/:noteId',
          builder: (_, state) {
            onThread?.call(state.pathParameters['noteId']!);
            return const Scaffold(body: Text('thread-page'));
          },
        ),
      ],
    );
    return MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }

  testWidgets('a null note renders the not-found placeholder', (t) async {
    await t.pumpWidget(host(null));
    expect(find.byIcon(Icons.link_off_rounded), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('shows a shortened pubkey when no profile is known', (t) async {
    final pk = 'a' * 20;
    await t.pumpWidget(host(aNote(authorPubkey: pk)));
    expect(find.text('aaaaaa…aaaa'), findsOneWidget);
  });

  testWidgets('a short pubkey is shown whole', (t) async {
    await t.pumpWidget(host(aNote(authorPubkey: 'abc')));
    expect(find.text('abc'), findsOneWidget);
  });

  testWidgets('a verified embed shows no unverified badge', (t) async {
    await t.pumpWidget(host(aNote(sig: 'good-sig')));
    expect(find.byIcon(Icons.gpp_maybe_rounded), findsNothing);
  });

  testWidgets('a blanked signature is flagged as unverified', (t) async {
    await t.pumpWidget(host(aNote(sig: '')));
    expect(find.byIcon(Icons.gpp_maybe_rounded), findsOneWidget);
  });

  testWidgets('long content shows the read-more hint, short does not', (
    t,
  ) async {
    await t.pumpWidget(host(aNote(content: 'x' * 400)));
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await t.pumpWidget(host(aNote(content: 'short body')));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('four or more lines also trigger the read-more hint', (t) async {
    await t.pumpWidget(host(aNote(content: 'a\nb\nc\nd\ne')));
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('tapping the embed opens its thread', (t) async {
    String? opened;
    await t.pumpWidget(
      host(aNote(id: 'quoted-1'), onThread: (id) => opened = id),
    );
    await t.tap(find.byType(InkWell).first);
    await t.pumpAndSettle();
    expect(opened, 'quoted-1');
    expect(find.text('thread-page'), findsOneWidget);
  });

  testWidgets('unicode and emoji content render without error', (t) async {
    await t.pumpWidget(host(aNote(content: 'नमस्ते 🌍 مرحبا')));
    expect(find.textContaining('नमस्ते'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
