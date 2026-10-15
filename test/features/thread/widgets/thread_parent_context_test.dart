import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/common/widgets/note_card/reference_note_card.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/features/thread/widgets/thread_parent_context.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

List<NoteEntity> _notes(int n) => [
  for (var i = 0; i < n; i++) aNote(id: 'n$i', content: 'ancestor $i'),
];

/// Covers: empty list renders nothing, reply-chain label vs references label,
/// collapse after two siblings with a show-more count and expansion, no
/// collapse for a non-sibling chain or for exactly two siblings, and the
/// per-row tap callback.
void main() {
  Widget host(
    List<NoteEntity> notes, {
    bool sibling = false,
    void Function(String)? onTap,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ThreadParentContext(
          notes: notes,
          profiles: const {},
          onNoteTap: onTap ?? (_) {},
          isSiblingGroup: sibling,
        ),
      ),
    ),
  );

  testWidgets('renders nothing when there are no ancestors', (t) async {
    await t.pumpWidget(host(const []));
    expect(find.byType(ReferenceNoteCard), findsNothing);
    expect(find.byIcon(Icons.reply_rounded), findsNothing);
  });

  testWidgets('a reply chain shows the replying-to label and every row', (
    t,
  ) async {
    await t.pumpWidget(host(_notes(4)));
    expect(find.byIcon(Icons.reply_rounded), findsOneWidget);
    expect(find.byType(ReferenceNoteCard), findsNWidgets(4));
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
  });

  testWidgets('siblings beyond two collapse behind a show-more row', (t) async {
    await t.pumpWidget(host(_notes(5), sibling: true));
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(find.byType(ReferenceNoteCard), findsNWidgets(2));
    expect(find.text('Show 3 more references'), findsOneWidget);

    await t.tap(find.byIcon(Icons.expand_more_rounded));
    await t.pump();

    expect(find.byType(ReferenceNoteCard), findsNWidgets(5));
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
  });

  testWidgets('exactly two siblings are not collapsed', (t) async {
    await t.pumpWidget(host(_notes(2), sibling: true));
    expect(find.byType(ReferenceNoteCard), findsNWidgets(2));
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
  });

  testWidgets('tapping a row reports that note id', (t) async {
    final tapped = <String>[];
    await t.pumpWidget(host(_notes(3), onTap: tapped.add));
    await t.tap(find.byType(ReferenceNoteCard).at(1));
    expect(tapped, ['n1']);
  });
}
