import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/common/widgets/note_card/draft_note_tile.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

const _longKey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// Covers: DraftNoteTile — name fallbacks (profile name, username, shortened
/// pubkey), the Draft pill, time, empty and unicode content, hashtags (first
/// three), and staged media.
void main() {
  Widget host({
    String content = 'hello',
    String? authorPubkey = _longKey,
    bool withProfile = false,
    DateTime? created,
    List<String> tTags = const [],
    List<MediaBlobEntity> attachments = const [],
    VoidCallback? onTap,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: DraftNoteTile(
        draftId: 'd1',
        content: content,
        draftLabel: 'Draft',
        authorPubkey: authorPubkey,
        profile: withProfile ? aProfile(name: 'Alice') : null,
        created: created,
        tTags: tTags,
        attachments: attachments,
        onTap: onTap,
      ),
    ),
  );

  testWidgets('shows the profile name, the Draft pill and the text', (t) async {
    await t.pumpWidget(host(withProfile: true, content: 'plain text'));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.textContaining('plain text'), findsOneWidget);
  });

  testWidgets('falls back to the username, then to a shortened pubkey',
      (t) async {
    await t.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DraftNoteTile(
          draftId: 'd1',
          content: 'x',
          draftLabel: 'Draft',
          authorPubkey: _longKey,
          profile: aProfile(name: null, username: 'alice_u'),
        ),
      ),
    ));
    expect(find.text('alice_u'), findsOneWidget);

    await t.pumpWidget(host(authorPubkey: _longKey));
    expect(find.text('aaaaaaaa...aaaa'), findsOneWidget);

    await t.pumpWidget(host(authorPubkey: 'short'));
    expect(find.text('short'), findsOneWidget);
  });

  testWidgets('no author at all still renders', (t) async {
    await t.pumpWidget(host(authorPubkey: null));

    expect(find.text('Draft'), findsOneWidget);
  });

  testWidgets('the time is shown only when the draft has one', (t) async {
    await t.pumpWidget(host());
    expect(find.textContaining('ago'), findsNothing);

    await t.pumpWidget(
      host(created: DateTime.now().subtract(const Duration(hours: 3))),
    );
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('empty content with no media shows a dash placeholder',
      (t) async {
    await t.pumpWidget(host(content: '   '));

    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('empty content with media shows neither text nor placeholder',
      (t) async {
    await t.pumpWidget(host(content: '', attachments: [aMediaBlob()]));

    expect(find.text('—'), findsNothing);
  });

  testWidgets('unicode, RTL and emoji content renders', (t) async {
    await t.pumpWidget(host(content: 'नमस्ते 🌍 مرحبا'));

    expect(find.textContaining('नमस्ते'), findsOneWidget);
  });

  testWidgets('shows at most three hashtags', (t) async {
    await t.pumpWidget(host(tTags: ['a', 'b', 'c', 'd']));

    expect(find.text('#a'), findsOneWidget);
    expect(find.text('#c'), findsOneWidget);
    expect(find.text('#d'), findsNothing);
  });

  testWidgets('tapping the words or the empty space beside them opens it',
      (t) async {
    var taps = 0;
    await t.pumpWidget(host(content: 'tap me', onTap: () => taps++));

    await t.tap(find.textContaining('tap me'));
    await t.tap(find.text('Draft'));

    expect(taps, 2);
  });

  testWidgets('with no onTap a tap does nothing', (t) async {
    await t.pumpWidget(host(content: 'tap me'));

    await t.tap(find.textContaining('tap me'));

    expect(find.byType(DraftNoteTile), findsOneWidget);
  });
}
