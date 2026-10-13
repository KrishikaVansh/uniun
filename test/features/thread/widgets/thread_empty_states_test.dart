import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/features/thread/widgets/thread_empty_states.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: empty-replies and no-references copy, a reference item's 12-char
/// id truncation, and the error body message.
void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets('empty replies invites the first reply', (t) async {
    await t.pumpWidget(host(const ThreadEmptyReplies()));
    expect(find.text('No replies yet'), findsOneWidget);
    expect(find.text('Be the first to reply.'), findsOneWidget);
  });

  testWidgets('no references explains there are none', (t) async {
    await t.pumpWidget(host(const ThreadNoReferences()));
    expect(find.text('No references'), findsOneWidget);
    expect(find.text('No notes reference this one yet.'), findsOneWidget);
  });

  testWidgets('a reference item shows a 12 character id prefix', (t) async {
    await t.pumpWidget(
      host(const ThreadReferenceItem(eventId: '0123456789abcdefFEDCBA')),
    );
    expect(find.text('0123456789ab…'), findsOneWidget);
  });

  testWidgets('a reference id of exactly 12 characters is still fine', (
    t,
  ) async {
    await t.pumpWidget(
      host(const ThreadReferenceItem(eventId: '0123456789ab')),
    );
    expect(find.text('0123456789ab…'), findsOneWidget);
  });

  testWidgets('the error body shows the message', (t) async {
    await t.pumpWidget(host(const ThreadErrorBody(message: 'relay is down')));
    expect(find.text('relay is down'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
  });
}
