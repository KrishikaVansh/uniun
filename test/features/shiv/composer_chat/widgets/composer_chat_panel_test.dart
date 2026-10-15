import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_state.dart';
import 'package:uniun/features/shiv/composer_chat/widgets/composer_chat_panel.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: header scope (named Manas vs All notes), the grounded hint before
/// any turn, Q&A bubbles with copy/use-as-reply actions only on answered
/// turns, streaming placeholder vs partial text with a Stop button, no-model
/// and error statuses (custom message vs default), exit callback, and
/// copy-to-clipboard.
void main() {
  Widget host(
    ComposerChatState state, {
    VoidCallback? onExit,
    VoidCallback? onStop,
    void Function(String)? onUse,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ComposerChatPanel(
          state: state,
          onExit: onExit ?? () {},
          onStop: onStop ?? () {},
          onUseAsReply: onUse ?? (_) {},
        ),
      ),
    ),
  );

  testWidgets('an empty chat shows the grounded hint for the Manas', (t) async {
    await t.pumpWidget(host(const ComposerChatState(manasName: 'Work')));
    expect(find.byIcon(Icons.tips_and_updates_outlined), findsOneWidget);
    expect(find.textContaining('WORK'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsNothing);
  });

  testWidgets('without a Manas the scope falls back to All notes', (t) async {
    await t.pumpWidget(host(const ComposerChatState()));
    expect(find.textContaining('ALL NOTES'), findsOneWidget);
  });

  testWidgets('turns render question and answer with actions per answer', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        const ComposerChatState(
          turns: [
            ComposerTurn(question: 'q1', answer: 'a1'),
            ComposerTurn(question: 'q2', answer: 'a2'),
          ],
        ),
      ),
    );
    expect(find.text('q1'), findsOneWidget);
    expect(find.text('a2'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.tips_and_updates_outlined), findsNothing);
  });

  testWidgets('an unanswered turn has no actions', (t) async {
    await t.pumpWidget(
      host(
        const ComposerChatState(turns: [ComposerTurn(question: 'pending q')]),
      ),
    );
    expect(find.text('pending q'), findsOneWidget);
    expect(find.byIcon(Icons.content_copy_rounded), findsNothing);
  });

  testWidgets('streaming shows a thinking placeholder, then partial text', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        const ComposerChatState(
          streaming: '',
          status: ComposerChatStatus.streaming,
        ),
      ),
    );
    expect(find.text('Thinking…'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

    await t.pumpWidget(
      host(
        const ComposerChatState(
          streaming: 'partial ans',
          status: ComposerChatStatus.streaming,
        ),
      ),
    );
    expect(find.text('partial ans'), findsOneWidget);
    expect(find.text('Thinking…'), findsNothing);
  });

  testWidgets('Stop, exit and use-as-reply fire their callbacks', (t) async {
    var stops = 0, exits = 0;
    String? used;
    await t.pumpWidget(
      host(
        const ComposerChatState(
          turns: [ComposerTurn(question: 'q', answer: 'final answer')],
          streaming: 'x',
          status: ComposerChatStatus.streaming,
        ),
        onStop: () => stops++,
        onExit: () => exits++,
        onUse: (s) => used = s,
      ),
    );

    await t.tap(find.byIcon(Icons.stop_circle_outlined));
    await t.tap(find.byIcon(Icons.close_rounded));
    await t.tap(find.byIcon(Icons.reply_rounded));

    expect([stops, exits, used], [1, 1, 'final answer']);
  });

  testWidgets('copy puts the answer on the clipboard and confirms', (t) async {
    String? clip;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await t.pumpWidget(
      host(
        const ComposerChatState(
          turns: [ComposerTurn(question: 'q', answer: 'copy me 🌍')],
        ),
      ),
    );
    await t.tap(find.byIcon(Icons.content_copy_rounded));
    await t.pump();

    expect(clip, 'copy me 🌍');
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('no-model and error statuses explain themselves', (t) async {
    await t.pumpWidget(
      host(const ComposerChatState(status: ComposerChatStatus.noModel)),
    );
    expect(
      find.text('No AI model is active. Download one from the Shiv tab.'),
      findsOneWidget,
    );

    await t.pumpWidget(
      host(
        const ComposerChatState(
          status: ComposerChatStatus.error,
          errorMessage: 'GPU exploded',
        ),
      ),
    );
    expect(find.text('GPU exploded'), findsOneWidget);

    await t.pumpWidget(
      host(const ComposerChatState(status: ComposerChatStatus.error)),
    );
    expect(find.text('Something went wrong.'), findsOneWidget);
  });
}
