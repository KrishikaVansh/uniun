import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/features/shiv/chat/widgets/shiv_input_composer.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: ShivInputComposer's send / stop control (#123) — while a reply is
/// streaming (including before its first token) the button is Stop and calls
/// `onStop`; otherwise it is Send and sends what was typed.
void main() {
  var stops = 0;
  late List<String> sent;

  setUp(() {
    stops = 0;
    sent = [];
  });

  Widget host({required bool streaming}) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ShivInputComposer(
          isStreaming: streaming,
          onStop: () => stops++,
          onSend: (text, manasIds, images) => sent.add(text),
        ),
      ),
    ),
  );

  testWidgets('streaming shows Stop, and tapping it stops', (t) async {
    await t.pumpWidget(host(streaming: true));

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
    await t.tap(find.byIcon(Icons.stop_rounded));
    expect(stops, 1);
  });

  testWidgets('idle shows Send, not Stop', (t) async {
    await t.pumpWidget(host(streaming: false));

    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
  });

  testWidgets('the control flips as a reply starts and ends', (t) async {
    await t.pumpWidget(host(streaming: false));
    await t.pumpWidget(host(streaming: true));
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

    await t.pumpWidget(host(streaming: false));
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
  });

  testWidgets('typing then Send sends the text once', (t) async {
    await t.pumpWidget(host(streaming: false));
    await t.enterText(find.byType(TextField), 'What is 2+2?');
    await t.pump();

    await t.tap(find.byIcon(Icons.arrow_upward_rounded));
    await t.pump();

    expect(sent, ['What is 2+2?']);
  });

  testWidgets('Send does nothing with an empty box', (t) async {
    await t.pumpWidget(host(streaming: false));

    await t.tap(find.byIcon(Icons.arrow_upward_rounded));
    await t.pump();

    expect(sent, isEmpty);
  });
}
