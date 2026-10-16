import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/domain/entities/llm/llm_model_info.dart';
import 'package:uniun/domain/usecases/llm_usecases.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_cubit.dart';
import 'package:uniun/features/shiv/composer_chat/cubit/composer_chat_state.dart';
import 'package:uniun/features/shiv/generation/context/manas_context_loader.dart';

class _MockSendChat extends Mock implements SendChatStreamUseCase {}

class _MockManasLoader extends Mock implements ManasContextLoader {}

class _MockHasModel extends Mock implements HasActiveLlmModelUseCase {}

class _MockGetActiveModel extends Mock implements GetActiveLlmModelUseCase {}

PackedNote _note(String id, String content) => PackedNote(
      id: id,
      content: content,
      created: DateTime(2026, 1, 1),
      source: PackedNoteSource.own,
    );

void main() {
  late _MockSendChat sendChat;
  late _MockManasLoader manasLoader;
  late _MockHasModel hasModel;
  late _MockGetActiveModel getActiveModel;

  setUpAll(() {
    registerFallbackValue(const SendChatStreamInput(message: 'x'));
  });

  ComposerChatCubit build() =>
      ComposerChatCubit(sendChat, manasLoader, hasModel, getActiveModel);

  setUp(() {
    sendChat = _MockSendChat();
    manasLoader = _MockManasLoader();
    hasModel = _MockHasModel();
    getActiveModel = _MockGetActiveModel();
    when(() => hasModel.call()).thenAnswer((_) async => true);
    when(() => getActiveModel.call()).thenAnswer((_) async => const Right(null));
  });

  group('start / updateEntityContext / exit', () {
    blocTest<ComposerChatCubit, ComposerChatState>(
      'start enters chat mode with the picked Manas name',
      build: build,
      act: (cubit) => cubit.start(
          manasIds: const ['m1'], manasName: 'Work', entityContext: const ['hi']),
      expect: () => [
        isA<ComposerChatState>()
            .having((s) => s.active, 'active', true)
            .having((s) => s.manasName, 'manasName', 'Work'),
      ],
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'exit resets to the default state and cancels any subscription',
      build: build,
      seed: () => const ComposerChatState(active: true, manasName: 'Work'),
      act: (cubit) => cubit.exit(),
      expect: () => [const ComposerChatState()],
    );

    test('updateEntityContext does not emit — it only updates internal '
        'state consumed by the next send()', () async {
      final cubit = build();
      cubit.start(manasIds: const [], entityContext: const ['old']);
      final states = <ComposerChatState>[];
      final sub = cubit.stream.listen(states.add);

      cubit.updateEntityContext(const ['new']);
      await Future<void>.delayed(Duration.zero);

      expect(states, isEmpty);
      await sub.cancel();
      await cubit.close();
    });
  });

  group('send — guards', () {
    blocTest<ComposerChatCubit, ComposerChatState>(
      'a blank/whitespace-only question is a no-op',
      build: build,
      act: (cubit) => cubit.send('   '),
      expect: () => [],
      verify: (_) {
        verifyNever(() => hasModel.call());
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'is a no-op while already streaming',
      build: build,
      seed: () => const ComposerChatState(status: ComposerChatStatus.streaming),
      act: (cubit) => cubit.send('another question'),
      expect: () => [],
      verify: (_) {
        verifyNever(() => hasModel.call());
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'no active model — emits noModel and never calls the loader/sendChat',
      build: build,
      setUp: () {
        when(() => hasModel.call()).thenAnswer((_) async => false);
      },
      act: (cubit) => cubit.send('question'),
      expect: () => [
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.noModel),
      ],
      verify: (_) {
        verifyNever(() => manasLoader.merge(
              manasIds: any(named: 'manasIds'),
              budget: any(named: 'budget'),
              relevanceQuery: any(named: 'relevanceQuery'),
            ));
        verifyNever(() => sendChat.call(any()));
      },
    );
  });

  group('send — Manas scoping', () {
    blocTest<ComposerChatCubit, ComposerChatState>(
      'empty manasIds ("All notes") searches the whole vector index via '
      'searchAll, not merge',
        build: () {
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => [_note('n1', 'hit')]);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('question'),
      verify: (_) {
        verify(() => manasLoader.searchAll(query: 'question', minScore: 0.72))
            .called(1);
        verifyNever(() => manasLoader.merge(
              manasIds: any(named: 'manasIds'),
              budget: any(named: 'budget'),
              relevanceQuery: any(named: 'relevanceQuery'),
            ));
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'the active model sets how similar a note must be: Gemma keeps 0.3 '
      '(#199)',
      build: () {
        when(() => getActiveModel.call()).thenAnswer(
          (_) async => const Right(
            LlmModelInfo(
              id: 'gemma4E2b',
              displayName: 'Gemma',
              backend: LlmBackendType.localGemma,
            ),
          ),
        );
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            )).thenAnswer((_) async => [_note('n1', 'hit')]);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('question'),
      verify: (_) {
        verify(() => manasLoader.searchAll(query: 'question', minScore: 0.3))
            .called(1);
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'a picked Manas filters via merge with the question as the '
      'relevance query, not searchAll',
        build: () {
        return build()..start(manasIds: const ['m1']);
      },
      setUp: () {
        when(() => manasLoader.merge(
              manasIds: any(named: 'manasIds'),
              budget: any(named: 'budget'),
              relevanceQuery: any(named: 'relevanceQuery'),
            )).thenAnswer((_) async => [_note('n1', 'hit')]);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('question'),
      verify: (_) {
        verify(() => manasLoader.merge(
              manasIds: ['m1'],
              budget: 1024,
              relevanceQuery: 'question',
            )).called(1);
        verifyNever(() => manasLoader.searchAll(query: any(named: 'query')));
      },
    );
  });

  group('send — streaming lifecycle', () {
    blocTest<ComposerChatCubit, ComposerChatState>(
      'streams sanitized cumulative text, then finalizes the turn on done',
        build: () {
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        when(() => sendChat.call(any()))
            .thenAnswer((_) => Stream.fromIterable(['Hel', 'lo']));
      },
      act: (cubit) => cubit.send('hi'),
      expect: () => [
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.streaming)
            .having((s) => s.turns.last.question, 'question', 'hi'),
        isA<ComposerChatState>().having((s) => s.streaming, 'streaming', 'Hel'),
        isA<ComposerChatState>().having((s) => s.streaming, 'streaming', 'Hello'),
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.idle)
            .having((s) => s.turns.last.answer, 'answer', 'Hello')
            .having((s) => s.streaming, 'streaming', isNull),
      ],
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'an empty final answer is recorded as "(no answer)"',
        build: () {
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('hi'),
      expect: () => [
        isA<ComposerChatState>(),
        isA<ComposerChatState>()
            .having((s) => s.turns.last.answer, 'answer', '(no answer)'),
      ],
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'a stream error emits an error status with the message',
        build: () {
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        when(() => sendChat.call(any()))
            .thenAnswer((_) => Stream.error(Exception('native crash')));
      },
      act: (cubit) => cubit.send('hi'),
      expect: () => [
        isA<ComposerChatState>(),
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.error)
            .having((s) => s.errorMessage, 'errorMessage', contains('native crash')),
      ],
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'prior answered turns become clean history capped to the last 3 pairs',
      build: () {
        return build()..start(manasIds: const []);
      },
      seed: () => const ComposerChatState(turns: [
        ComposerTurn(question: 'q1', answer: 'a1'),
        ComposerTurn(question: 'q2', answer: 'a2'),
        ComposerTurn(question: 'q3', answer: 'a3'),
        ComposerTurn(question: 'q4', answer: ''), // unanswered — excluded
      ]),
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('q5'),
      verify: (_) {
        final captured = verify(() => sendChat.call(captureAny()))
            .captured
            .single as SendChatStreamInput;
        expect(captured.cleanHistory, [('q1', 'a1'), ('q2', 'a2'), ('q3', 'a3')]);
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'history longer than the cap keeps only the most recent 3 pairs',
        build: () {
        return build()..start(manasIds: const []);
      },
      seed: () => ComposerChatState(turns: List.generate(
          5, (i) => ComposerTurn(question: 'q$i', answer: 'a$i'))),
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('q5'),
      verify: (_) {
        final captured = verify(() => sendChat.call(captureAny()))
            .captured
            .single as SendChatStreamInput;
        expect(captured.cleanHistory, [('q2', 'a2'), ('q3', 'a3'), ('q4', 'a4')]);
      },
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'the systemInstruction carries the active Manas name',
        build: () {
        return build()..start(manasIds: const ['m1'], manasName: 'Work');
      },
      setUp: () {
        when(() => manasLoader.merge(
              manasIds: any(named: 'manasIds'),
              budget: any(named: 'budget'),
              relevanceQuery: any(named: 'relevanceQuery'),
            )).thenAnswer((_) async => const []);
        when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      },
      act: (cubit) => cubit.send('hi'),
      verify: (_) {
        final captured = verify(() => sendChat.call(captureAny()))
            .captured
            .single as SendChatStreamInput;
        expect(captured.systemInstruction, contains('"Work"'));
      },
    );
  });

  group('stop', () {
    blocTest<ComposerChatCubit, ComposerChatState>(
      'is a no-op when not streaming',
      build: build,
      act: (cubit) => cubit.stop(),
      expect: () => [],
    );

    blocTest<ComposerChatCubit, ComposerChatState>(
      'finalizes the turn with the partial streamed text and cancels the '
      'subscription',
        build: () {
        return build()..start(manasIds: const []);
      },
      setUp: () {
        when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
            .thenAnswer((_) async => const []);
        // Never completes on its own — only stop() should finalize it.
        when(() => sendChat.call(any()))
            .thenAnswer((_) => Stream<String>.fromIterable(['par', 'tial'])
                .asyncMap((e) async {
              await Future<void>.delayed(const Duration(seconds: 10));
              return e;
            }));
      },
      act: (cubit) async {
        // Kick off streaming, wait for the "streaming" status to land, then
        // stop before the (artificially slow) stream ever completes.
        unawaited(cubit.send('hi'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        cubit.stop();
      },
      expect: () => [
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.streaming),
        isA<ComposerChatState>()
            .having((s) => s.status, 'status', ComposerChatStatus.idle)
            .having((s) => s.turns.last.answer, 'answer', '(stopped)')
            .having((s) => s.streaming, 'streaming', isNull),
      ],
    );
  });

  group('close', () {
    test('closing while a send() is still awaiting hasModel/manasLoader '
        'does not crash with "emit after close" — regression: send() had '
        'no isClosed guards before its first emit, unlike every sibling '
        'bloc/cubit in this codebase (NatarajBloc, ShivAIBloc)', () async {
      when(() => manasLoader.searchAll(
              query: any(named: 'query'),
              minScore: any(named: 'minScore'),
            ))
          .thenAnswer((_) async => const []);
      when(() => sendChat.call(any())).thenAnswer((_) => const Stream.empty());
      final cubit = build()..start(manasIds: const []);

      unawaited(cubit.send('hi'));
      await cubit.close();
    });
  });
}
