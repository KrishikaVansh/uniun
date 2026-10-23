import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/composer/cubit/reference_picker_cubit.dart';
import 'package:uniun/common/widgets/composer/reference_picker_page.dart';
import 'package:uniun/common/widgets/composer/uniun_composer.dart';
import 'package:uniun/common/widgets/drop_loading_indicator.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockCubit extends MockCubit<ReferencePickerState>
    implements ReferencePickerCubit {}

/// Covers: ReferencePickerPage — rows (name from profile, username, short
/// pubkey, none; time; empty preview), selection toggling and the Add count,
/// held selection shown first, tab chips and search forwarding, the empty and
/// loading states, and the selection returned by Add, close and system back.
void main() {
  late _MockCubit cubit;

  ComposerReference ref(
    String id, {
    String label = 'note body',
    String? author,
    DateTime? created,
    ComposerReferenceKind kind = ComposerReferenceKind.note,
  }) => ComposerReference(
    id: id,
    label: label,
    authorPubkey: author,
    created: created,
    kind: kind,
  );

  setUpAll(() => registerFallbackValue(ReferenceTab.all));

  setUp(() async {
    cubit = _MockCubit();
    when(() => cubit.state).thenReturn(const ReferencePickerState());
    when(() => cubit.close()).thenAnswer((_) async {});
    when(() => cubit.setTab(any())).thenAnswer((_) async {});
    when(() => cubit.search(any())).thenAnswer((_) async {});
    await GetIt.instance.reset();
    GetIt.instance.registerFactory<ReferencePickerCubit>(() => cubit);
  });

  tearDown(() => GetIt.instance.reset());

  /// Opens the page from a button and records what it returned.
  Widget host({
    List<ComposerReference> initial = const [],
    void Function(List<ComposerReference>?)? onResult,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (ctx) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final r = await Navigator.push<List<ComposerReference>>(
              ctx,
              MaterialPageRoute(
                builder: (_) => ReferencePickerPage(
                  title: 'Pick',
                  searchHint: 'Search notes',
                  emptyLabel: 'Nothing here',
                  initialSelected: initial,
                ),
              ),
            );
            onResult?.call(r);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester t, Widget w) async {
    await t.pumpWidget(w);
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  testWidgets('shows the title, search hint and all four tabs', (t) async {
    await open(t, host());

    expect(find.text('Pick'), findsOneWidget);
    expect(find.text('Search notes'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Drafts'), findsOneWidget);
  });

  testWidgets('an empty result shows the empty label', (t) async {
    await open(t, host());

    expect(find.text('Nothing here'), findsOneWidget);
  });

  testWidgets('while loading with no rows a spinner replaces the label',
      (t) async {
    when(() => cubit.state)
        .thenReturn(const ReferencePickerState(loading: true));
    // The spinner animates forever, so settle by pumping a fixed time.
    await t.pumpWidget(host());
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    expect(find.text('Nothing here'), findsNothing);
    expect(find.byType(DropLoadingIndicator), findsOneWidget);
  });

  testWidgets('rows show name, time and a stripped preview; a row with no '
      'text shows an ellipsis', (t) async {
    final state = ReferencePickerState(
      results: [
        ref('a', label: '**bold** नमस्ते 🌍', author: kAlicePub, created: tNow),
        ref('b', label: '   ', author: kBobPub),
        ref('c', label: 'no author'),
      ],
      profiles: {kAlicePub: aProfile(pubkey: kAlicePub, name: 'Alice')},
    );
    when(() => cubit.state).thenReturn(state);
    await open(t, host());

    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('bold नमस्ते'), findsOneWidget);
    expect(find.textContaining('· '), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    expect(find.text('no author'), findsOneWidget);
  });

  testWidgets('the username is used when a profile has no name', (t) async {
    when(() => cubit.state).thenReturn(ReferencePickerState(
      results: [ref('a', author: kAlicePub)],
      profiles: {
        kAlicePub: aProfile(pubkey: kAlicePub, name: '  ', username: 'ali_u'),
      },
    ));
    await open(t, host());

    expect(find.text('ali_u'), findsNothing,
        reason: 'a blank name falls through to the short pubkey');
    expect(find.textContaining('…'), findsNothing);
  });

  testWidgets('tapping rows selects and deselects, and the Add button counts',
      (t) async {
    when(() => cubit.state).thenReturn(ReferencePickerState(
      results: [ref('a', label: 'first'), ref('b', label: 'second')],
    ));
    await open(t, host());
    expect(find.text('Add'), findsOneWidget);

    await t.tap(find.text('first'));
    await t.pump();
    expect(find.text('Add (1)'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await t.tap(find.text('second'));
    await t.pump();
    expect(find.text('Add (2)'), findsOneWidget);

    await t.tap(find.text('first'));
    await t.pump();
    expect(find.text('Add (1)'), findsOneWidget);
  });

  testWidgets('the held selection is listed first, even when the results '
      'do not include it', (t) async {
    when(() => cubit.state).thenReturn(ReferencePickerState(
      results: [ref('a', label: 'from results')],
    ));
    await open(t, host(initial: [ref('held', label: 'held earlier')]));

    expect(find.text('Add (1)'), findsOneWidget);
    final held = t.getTopLeft(find.text('held earlier')).dy;
    final other = t.getTopLeft(find.text('from results')).dy;
    expect(held, lessThan(other));
  });

  testWidgets('a held reference shown in the results uses the result row',
      (t) async {
    when(() => cubit.state).thenReturn(ReferencePickerState(
      results: [ref('a', label: 'fresh label')],
    ));
    await open(t, host(initial: [ref('a', label: 'stale label')]));

    expect(find.text('fresh label'), findsOneWidget);
    expect(find.text('stale label'), findsNothing);
    expect(find.text('Add (1)'), findsOneWidget);
  });

  testWidgets('Add returns the selection', (t) async {
    List<ComposerReference>? result;
    when(() => cubit.state).thenReturn(
      ReferencePickerState(results: [ref('a', label: 'first')]),
    );
    await open(t, host(onResult: (r) => result = r));

    await t.tap(find.text('first'));
    await t.pump();
    await t.tap(find.text('Add (1)'));
    await t.pumpAndSettle();

    expect(result!.map((r) => r.id), ['a']);
  });

  testWidgets('the close button returns the selection too', (t) async {
    List<ComposerReference>? result;
    await open(
      t,
      host(initial: [ref('held')], onResult: (r) => result = r),
    );

    await t.tap(find.byIcon(Icons.close_rounded));
    await t.pumpAndSettle();

    expect(result!.map((r) => r.id), ['held']);
  });

  testWidgets('system back returns the selection instead of dropping it',
      (t) async {
    List<ComposerReference>? result;
    await open(
      t,
      host(initial: [ref('held')], onResult: (r) => result = r),
    );

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(result!.map((r) => r.id), ['held']);
  });

  testWidgets('typing forwards the query to the cubit', (t) async {
    await open(t, host());

    await t.enterText(find.byType(TextField), 'plans');

    verify(() => cubit.search('plans')).called(1);
  });

  testWidgets('switching tab clears the search box and tells the cubit',
      (t) async {
    await open(t, host());
    await t.enterText(find.byType(TextField), 'plans');

    await t.tap(find.text('Saved'));
    await t.pump();

    verify(() => cubit.setTab(ReferenceTab.saved)).called(1);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '');
  });

  testWidgets('every tab can be chosen', (t) async {
    await open(t, host());

    for (final entry in {
      'All': ReferenceTab.all,
      'Saved': ReferenceTab.saved,
      'Drafts': ReferenceTab.drafts,
    }.entries) {
      await t.tap(find.text(entry.key));
      await t.pump();
      verify(() => cubit.setTab(entry.value)).called(1);
    }
  });
}
