import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:uniun/core/utils/llm_text_sanitizer.dart';
import 'package:uniun/domain/usecases/llm_usecases.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_state.dart';
import 'package:uniun/features/shiv/generation/chat_helpers.dart';
import 'package:uniun/features/shiv/generation/context/manas_context_loader.dart';
import 'package:uniun/features/shiv/generation/prompt/composer_chat_prompt.dart';
import 'package:uniun/features/shiv/rag/prompt/prompt_budget.dart';

/// Headless chat engine for the composer-chat (WS4): the inline AI chat the
/// note composer becomes when the user long-presses the avatar and picks a
/// Manas. It answers about the conversation the user is reading (thread /
/// group / DM / private group), grounded in the picked Manas.
///
/// Standalone by design — it reuses the existing [SendChatStreamUseCase] +
/// [ManasContextLoader] + WS3 chat helpers, so it needs no decomposition of
/// `ShivAIBloc`. Registered `@injectable` (factory), so each composer instance
/// gets its own cubit and multiple chat surfaces never share state (the runner
/// is stateless per turn after WS1c).
@injectable
class ComposerChatCubit extends Cubit<ComposerChatState> {
  ComposerChatCubit(
    this._sendChat,
    this._manasLoader,
    this._hasModel,
    this._getActiveModel,
  ) : super(const ComposerChatState());

  final SendChatStreamUseCase _sendChat;
  final ManasContextLoader _manasLoader;
  final HasActiveLlmModelUseCase _hasModel;
  final GetActiveLlmModelUseCase _getActiveModel;

  StreamSubscription<String>? _sub;
  List<String> _manasIds = const [];
  List<String> _entityContext = const [];

  static const int _manasBudgetTokens = 1024;
  static const int _maxHistoryPairs = 3;

  /// Enter chat mode with the picked Manas + the surface's recent messages
  /// (already flattened to short `"author: text"` lines by the caller).
  void start({
    required List<String> manasIds,
    String? manasName,
    List<String> entityContext = const [],
  }) {
    _manasIds = manasIds;
    _entityContext = entityContext;
    emit(ComposerChatState(active: true, manasName: manasName));
  }

  /// Refresh the surface context (e.g. new messages arrived) without resetting.
  void updateEntityContext(List<String> entityContext) {
    _entityContext = entityContext;
  }

  Future<void> send(String question) async {
    final q = question.trim();
    if (q.isEmpty || state.status == ComposerChatStatus.streaming) return;

    if (!await _hasModel.call()) {
      if (isClosed) return;
      emit(state.copyWith(status: ComposerChatStatus.noModel));
      return;
    }

    // Relevance-rank the notes against the question. "All notes" scope
    // (empty manasIds) searches the WHOLE vector index — NOT empty, which was
    // leaving the model ungrounded; a specific Manas filters to its notes.
    // How similar a note must be depends on the model: the 0.6B one copies
    // whatever it is given, so it only gets notes that really match.
    final model = (await _getActiveModel.call()).getOrElse(() => null);
    final manasNotes = _manasIds.isEmpty
        ? await _manasLoader.searchAll(
            query: q,
            minScore: PromptBudget.forActiveModel(model).minScore,
          )
        : await _manasLoader.merge(
            manasIds: _manasIds,
            budget: _manasBudgetTokens,
            relevanceQuery: q,
          );
    if (isClosed) return;

    final userMsg = ComposerChatPromptTemplate.userMessage(
      question: q,
      entityContext: _entityContext,
      manasNotes: manasNotes,
    );
    final sysInstruction = ComposerChatPromptTemplate.systemInstruction(
      manasName: state.manasName,
    );

    // Prior Q&A as clean history for follow-ups (capped).
    final history = <(String, String)>[
      for (final t in state.turns)
        if (t.answer.trim().isNotEmpty) (t.question, t.answer),
    ];
    final trimmed = history.length <= _maxHistoryPairs
        ? history
        : history.sublist(history.length - _maxHistoryPairs);

    emit(state.copyWith(
      turns: [...state.turns, ComposerTurn(question: q)],
      status: ComposerChatStatus.streaming,
      streaming: '',
      errorMessage: null,
    ));

    final buf = StringBuffer();
    _sub?.cancel();
    _sub = _sendChat
        .call(SendChatStreamInput(
          message: userMsg,
          systemInstruction: sysInstruction,
          cleanHistory: trimmed,
        ))
        .listen(
      (token) {
        if (isClosed) return;
        buf.write(token);
        // Sanitize the cumulative raw buffer for display — decodes GPT-2
        // byte runs (emoji mojibake), strips tool-call envelopes, hides
        // `<think>` blocks. Idempotent + safe to re-run every token. Must
        // run on the WHOLE buffer (not per chunk) because UTF-8 sequences
        // can span chunks.
        emit(state.copyWith(
            streaming: LlmTextSanitizer.clean(buf.toString())));
      },
      onDone: () {
        if (isClosed) return;
        final answer = stripThinking(buf.toString());
        emit(state.copyWith(
          turns: _withLastAnswer(answer.isEmpty ? '(no answer)' : answer),
          status: ComposerChatStatus.idle,
          streaming: null,
        ));
      },
      onError: (Object e) {
        if (isClosed) return;
        emit(state.copyWith(
          status: ComposerChatStatus.error,
          errorMessage: e.toString(),
          streaming: null,
        ));
      },
      cancelOnError: true,
    );
  }

  /// Stop the in-flight stream, keeping whatever was generated so far.
  void stop() {
    if (state.status != ComposerChatStatus.streaming) return;
    _sub?.cancel();
    _sub = null;
    final partial = stripThinking(state.streaming ?? '');
    emit(state.copyWith(
      turns: _withLastAnswer(partial.isEmpty ? kStoppedReply : partial),
      status: ComposerChatStatus.idle,
      streaming: null,
    ));
  }

  /// Leave chat mode, back to normal composing.
  void exit() {
    _sub?.cancel();
    _sub = null;
    _manasIds = const [];
    _entityContext = const [];
    emit(const ComposerChatState());
  }

  List<ComposerTurn> _withLastAnswer(String answer) {
    final turns = [...state.turns];
    if (turns.isNotEmpty) {
      turns[turns.length - 1] = turns.last.copyWith(answer: answer);
    }
    return turns;
  }

  @override
  Future<void> close() {
    _sub?.cancel();
    return super.close();
  }
}
