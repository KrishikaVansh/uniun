import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/enum/message_role.dart';
import 'package:uniun/domain/entities/shiv/shiv_message_entity.dart';
import 'package:uniun/features/shiv/chat/widgets/shiv_message_bubble.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: ShivMessageBubble's waiting state (#123) — the three dots show for a
/// streaming reply that has no visible text yet (nothing streamed, only
/// whitespace, or a reasoning block still open) and give way to the text once
/// there is some; a finished reply never shows them.
void main() {
  ShivMessageEntity message({String content = ''}) => ShivMessageEntity(
    messageId: 'm1',
    conversationId: 'c1',
    parentId: 'u1',
    role: MessageRole.assistant,
    content: content,
    createdAt: DateTime(2026),
  );

  Widget host({String? streaming, String content = ''}) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ShivMessageBubble(
          message: message(content: content),
          streamingContent: streaming,
          isLastAssistant: true,
        ),
      ),
    ),
  );

  Finder dots() => find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_TypingIndicator',
  );

  Future<void> show(WidgetTester t, Widget w) async {
    await t.pumpWidget(w);
    // The dots start their animation after a short delay; let it run so no
    // timer is left pending when the test ends.
    await t.pump(const Duration(seconds: 1));
  }

  testWidgets('nothing streamed yet shows the dots', (t) async {
    await show(t, host(streaming: ''));

    expect(dots(), findsOneWidget);
  });

  testWidgets('only whitespace streamed so far still shows the dots',
      (t) async {
    // Cloud models often open a reply with a blank line; the bubble must not
    // go blank while that is all there is.
    await show(t, host(streaming: '\n\n'));

    expect(dots(), findsOneWidget);
  });

  testWidgets('real text replaces the dots', (t) async {
    await show(t, host(streaming: 'Paris is the capital of France.'));

    expect(dots(), findsNothing);
    expect(find.textContaining('Paris is the capital'), findsOneWidget);
  });

  testWidgets('an open reasoning block is not a blank bubble', (t) async {
    await show(t, host(streaming: '<think>'));

    // Either the dots or a reasoning label must be on screen.
    final texts = find.byType(Text).evaluate().length;
    expect(dots().evaluate().isNotEmpty || texts > 1, isTrue);
  });

  testWidgets('a finished reply has no dots', (t) async {
    await show(t, host(content: 'Done.'));

    expect(dots(), findsNothing);
    expect(find.text('Done.'), findsOneWidget);
  });

  testWidgets('a finished empty reply shows no dots and does not throw',
      (t) async {
    await show(t, host());

    expect(dots(), findsNothing);
  });
}
