import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/note_card/cubit/note_card_cubit.dart';
import 'package:uniun/common/widgets/note_card/translation_footer.dart';
import 'package:uniun/core/i18n/translation_language.dart';
import 'package:uniun/l10n/app_localizations.dart';

class _MockCard extends MockCubit<NoteCardState> implements NoteCardCubit {}

/// Covers: hidden when untranslated, "Translating…" without actions, the
/// translated strip with Show original / Show translation toggle, the Change
/// action opening the language sheet (dismiss does not translate), and the
/// two error snackbars clearing the error afterwards.
void main() {
  late _MockCard card;

  setUpAll(() => registerFallbackValue(TranslationLanguage.all.first));

  setUp(() {
    card = _MockCard();
    when(() => card.toggleOriginal()).thenReturn(null);
    when(() => card.clearTranslationError()).thenReturn(null);
    when(() => card.translate(any())).thenAnswer((_) async {});
  });

  Widget host() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: BlocProvider<NoteCardCubit>.value(
        value: card,
        child: const TranslationFooter(),
      ),
    ),
  );

  testWidgets('an untranslated note renders nothing', (t) async {
    when(() => card.state).thenReturn(const NoteCardState());
    await t.pumpWidget(host());
    expect(find.byIcon(Icons.translate_rounded), findsNothing);
  });

  testWidgets('while translating only the progress label shows', (t) async {
    when(() => card.state).thenReturn(const NoteCardState(isTranslating: true));
    await t.pumpWidget(host());
    expect(find.text('Translating…'), findsOneWidget);
    expect(find.text('Show original'), findsNothing);
    expect(find.text('Change'), findsNothing);
  });

  testWidgets('a translated note offers Show original and Change', (t) async {
    when(() => card.state).thenReturn(
      const NoteCardState(translation: 'नमस्ते', translationLanguage: 'hi'),
    );
    await t.pumpWidget(host());
    expect(find.textContaining('Translated to'), findsOneWidget);
    expect(find.text('Show original'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);

    await t.tap(find.text('Show original'));
    verify(() => card.toggleOriginal()).called(1);
  });

  testWidgets('while showing the original the action flips', (t) async {
    when(() => card.state).thenReturn(
      const NoteCardState(
        translation: 'x',
        translationLanguage: 'hi',
        showOriginal: true,
      ),
    );
    await t.pumpWidget(host());
    expect(find.text('Show translation'), findsOneWidget);
    expect(find.text('Show original'), findsNothing);
  });

  testWidgets(
    'Change opens the language sheet; dismissing translates nothing',
    (t) async {
      when(() => card.state).thenReturn(
        const NoteCardState(translation: 'x', translationLanguage: 'hi'),
      );
      await t.pumpWidget(host());

      await t.tap(find.text('Change'));
      await t.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);

      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      verifyNever(() => card.translate(any()));
    },
  );

  testWidgets('a generic failure shows the retry snackbar and clears it', (
    t,
  ) async {
    whenListen(
      card,
      Stream.value(const NoteCardState(translationError: 'boom')),
      initialState: const NoteCardState(),
    );
    await t.pumpWidget(host());
    await t.pump();
    await t.pump();

    expect(
      find.text("Couldn't translate this note. Try again."),
      findsOneWidget,
    );
    verify(() => card.clearTranslationError()).called(1);
  });

  testWidgets('the no-output marker shows the model-specific message', (
    t,
  ) async {
    whenListen(
      card,
      Stream.value(
        const NoteCardState(
          translationError: NoteCardCubit.kNoTranslationProduced,
        ),
      ),
      initialState: const NoteCardState(),
    );
    await t.pumpWidget(host());
    await t.pump();
    await t.pump();

    expect(find.textContaining("AI model couldn't translate"), findsOneWidget);
  });
}
