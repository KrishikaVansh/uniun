import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/features/settings/widgets/settings_card.dart';

/// Covers: SettingsGroup divider insertion, SettingsRow subtitle / value /
/// chevron / custom trailing / info tooltip / tap behaviour, picker button, and
/// the option sheet (selection mark, callback + dismissal, single option).
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a group inserts dividers between rows only', (t) async {
    await t.pumpWidget(
      host(
        const SettingsGroup(
          children: [
            SettingsRow(icon: Icons.home, label: 'one'),
            SettingsRow(icon: Icons.star, label: 'two'),
            SettingsRow(icon: Icons.place, label: 'three'),
          ],
        ),
      ),
    );
    expect(find.byType(SettingsRowDivider), findsNWidgets(2));
  });

  testWidgets('an empty or single-row group has no dividers', (t) async {
    await t.pumpWidget(host(const SettingsGroup(children: [])));
    expect(find.byType(SettingsRowDivider), findsNothing);

    await t.pumpWidget(
      host(
        const SettingsGroup(
          children: [SettingsRow(icon: Icons.home, label: 'only')],
        ),
      ),
    );
    expect(find.byType(SettingsRowDivider), findsNothing);
  });

  testWidgets('a row shows subtitle, value and a chevron by default', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        const SettingsRow(
          icon: Icons.lock,
          label: 'Privacy',
          subtitle: 'who sees what',
          value: 'On',
          valueAccent: true,
          valueMono: true,
        ),
      ),
    );
    expect(find.text('Privacy'), findsOneWidget);
    expect(find.text('who sees what'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('showChevron false hides the chevron', (t) async {
    await t.pumpWidget(
      host(
        const SettingsRow(
          icon: Icons.lock,
          label: 'Privacy',
          showChevron: false,
        ),
      ),
    );
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('a custom trailing replaces the value and chevron', (t) async {
    await t.pumpWidget(
      host(
        const SettingsRow(
          icon: Icons.lock,
          label: 'Privacy',
          value: 'ignored',
          trailing: Switch(value: true, onChanged: null),
        ),
      ),
    );
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('ignored'), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('the info icon reveals its tooltip on tap', (t) async {
    await t.pumpWidget(
      host(
        const SettingsRow(
          icon: Icons.lock,
          label: 'Privacy',
          infoTooltip: 'long explanation',
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.info_outline_rounded));
    await t.pump();
    expect(find.text('long explanation'), findsOneWidget);
  });

  testWidgets('onTap fires only when provided', (t) async {
    var taps = 0;
    await t.pumpWidget(
      host(SettingsRow(icon: Icons.lock, label: 'Tap me', onTap: () => taps++)),
    );
    await t.tap(find.text('Tap me'));
    expect(taps, 1);

    await t.pumpWidget(
      host(const SettingsRow(icon: Icons.lock, label: 'Static')),
    );
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('picker button shows the label and forwards taps', (t) async {
    var taps = 0;
    await t.pumpWidget(
      host(SettingsPickerButton(label: '7 days', onTap: () => taps++)),
    );
    expect(find.text('7 days'), findsOneWidget);
    await t.tap(find.byType(SettingsPickerButton));
    expect(taps, 1);
  });

  testWidgets('the option sheet checks the selection and reports a pick', (
    t,
  ) async {
    int? picked;
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsOptionSheet<int>(
              context: context,
              title: 'Keep notes for',
              selected: 3,
              options: const [
                SettingsOption(3, '3 days'),
                SettingsOption(7, '7 days'),
              ],
              onSelected: (v) => picked = v,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Keep notes for'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await t.tap(find.text('7 days'));
    await t.pumpAndSettle();
    expect(picked, 7);
    expect(find.text('Keep notes for'), findsNothing);
  });

  testWidgets('re-picking the selected option still reports and closes', (
    t,
  ) async {
    int? picked;
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettingsOptionSheet<int>(
              context: context,
              title: 'T',
              selected: 1,
              options: const [SettingsOption(1, 'only')],
              onSelected: (v) => picked = v,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.text('only'));
    await t.pumpAndSettle();
    expect(picked, 1);
  });
}
