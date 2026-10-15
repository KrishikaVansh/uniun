import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/manas/manas_entity.dart';
import 'package:uniun/domain/usecases/manas_usecases.dart';
import 'package:uniun/features/shiv/composer_chat/widgets/manas_picker_sheet.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../../_helpers/fixtures.dart';

class _MockList extends Mock implements GetManasListUseCase {}

/// Covers: All-notes row always present, Manas rows with pluralised counts,
/// selected-check logic (all / one / none), results returned on tap, loading
/// spinner while the list is pending, and a failed load falling back to the
/// All-notes row only.
void main() {
  late _MockList list;
  ManasChatScope? result;
  var closed = false;

  setUp(() async {
    list = _MockList();
    result = null;
    closed = false;
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<GetManasListUseCase>(list);
  });

  tearDown(() => GetIt.instance.reset());

  Future<void> open(
    WidgetTester t, {
    ManasChatScope? current,
    bool settle = true,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showManasChatPicker(context, current: current);
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    if (settle) await t.pumpAndSettle();
  }

  final manas = [
    aManas(manasId: 'm1', name: 'Work', noteCount: 1),
    aManas(manasId: 'm2', name: 'Home', noteCount: 12),
  ];

  testWidgets('lists All notes plus every Manas with its note count', (
    t,
  ) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(t);

    expect(find.text('All notes'), findsOneWidget);
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('1 note'), findsOneWidget);
    expect(find.text('12 notes'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('picking All notes returns an empty-id scope', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(t);

    await t.tap(find.text('All notes'));
    await t.pumpAndSettle();

    expect(closed, isTrue);
    expect(result!.manasIds, isEmpty);
    expect(result!.name, isNull);
    expect(result!.icon, kAllNotesIcon);
  });

  testWidgets('picking a Manas returns its id and name', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(t);

    await t.tap(find.text('Home'));
    await t.pumpAndSettle();

    expect(result!.manasIds, ['m2']);
    expect(result!.name, 'Home');
  });

  testWidgets('the current single-Manas scope is checked', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(
      t,
      current: const ManasChatScope(manasIds: ['m2'], icon: Icons.folder),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('the all-notes scope checks the first row only', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(
      t,
      current: const ManasChatScope(manasIds: [], icon: kAllNotesIcon),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('a multi-Manas scope checks no single row', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(
      t,
      current: const ManasChatScope(manasIds: ['m1', 'm2'], icon: Icons.folder),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
  });

  testWidgets('a spinner shows while the list is loading', (t) async {
    final c = Completer<Either<Failure, List<ManasEntity>>>();
    when(() => list.call()).thenAnswer((_) => c.future);
    await open(t, settle: false);

    expect(find.text('All notes'), findsOneWidget);
    expect(find.text('Work'), findsNothing);

    c.complete(Right(manas));
    await t.pump();
    await t.pump();
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('a failed load leaves only the All notes row', (t) async {
    when(
      () => list.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('db closed')));
    await open(t);

    expect(find.text('All notes'), findsOneWidget);
    expect(find.text('Work'), findsNothing);
  });

  testWidgets('dismissing the sheet returns null', (t) async {
    when(() => list.call()).thenAnswer((_) async => Right(manas));
    await open(t);

    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNull);
  });
}
