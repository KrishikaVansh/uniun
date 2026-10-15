import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/enum/report_type.dart';
import 'package:uniun/features/moderation/cubit/report_sheet_cubit.dart';
import 'package:uniun/features/moderation/widgets/report_type_list.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: one row per ReportType, a single selected radio, tapping a row
/// moves the selection through the real cubit, and re-tapping is idempotent.
void main() {
  late ReportSheetCubit cubit;

  setUp(() {
    cubit = ReportSheetCubit(targetEventId: 'e', targetPubkey: 'p');
  });

  tearDown(() => cubit.close());

  Widget host() => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: BlocProvider.value(value: cubit, child: const ReportTypeList()),
      ),
    ),
  );

  testWidgets('renders a row for every report type, none selected at first', (
    t,
  ) async {
    await t.pumpWidget(host());
    final rows = find.byType(InkWell);
    expect(rows, findsNWidgets(ReportType.values.length));
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsNothing);
    expect(
      find.byIcon(Icons.radio_button_unchecked_rounded),
      findsNWidgets(ReportType.values.length),
    );
  });

  testWidgets('tapping a row selects that type in the cubit', (t) async {
    await t.pumpWidget(host());
    final target = ReportType.values.last;
    expect(cubit.state.type, isNull);

    await t.ensureVisible(find.byType(InkWell).last);
    await t.tap(find.byType(InkWell).last);
    await t.pump();

    expect(cubit.state.type, target);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
  });

  testWidgets('re-tapping the selected row keeps it selected', (t) async {
    await t.pumpWidget(host());
    await t.tap(find.byType(InkWell).first);
    await t.pump();
    await t.tap(find.byType(InkWell).first);
    await t.pump();
    expect(cubit.state.type, ReportType.values.first);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);
  });
}
