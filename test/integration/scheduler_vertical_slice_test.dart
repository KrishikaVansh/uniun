import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniun/data/datasources/app_settings_store.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/data/datasources/llm/inference_scheduler.dart';
import 'package:uniun/data/datasources/llm/local_llm_runner.dart';
import 'package:uniun/data/repositories/scheduler_coordinator_impl.dart';
import 'package:uniun/domain/entities/llm/llm_task_kind.dart';
import 'package:uniun/domain/repositories/scheduler_coordinator.dart';
import 'package:uniun/domain/usecases/scheduler_usecases.dart';

/// Vertical-slice integration tests — wire the real production classes
/// across all three layers (presentation → domain → data) with NO mocks
/// and verify the chain behaves end-to-end.
///
/// This catches "I forgot to register X in DI" / "I swapped a method
/// signature in the data layer but the use case still compiles" classes
/// of bug that isolated unit tests can miss.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InferenceScheduler scheduler;
  late SchedulerCoordinator coordinator;
  late SetForegroundKindUseCase setForegroundUseCase;

  setUp(() {
    scheduler = InferenceScheduler();
    coordinator = SchedulerCoordinatorImpl(scheduler);
    setForegroundUseCase = SetForegroundKindUseCase(coordinator);
  });

  group('Page → UseCase → Coordinator → Scheduler — full vertical slice', () {
    test('setForegroundUseCase(nataraj) hoists queued nataraj over gana',
        () async {
      // Block the scheduler so both candidates are queued before pick.
      final blocker = scheduler.run<void>(
        kind: LlmTaskKind.chat,
        modelId: 'm',
        work: (_) => Future.delayed(const Duration(milliseconds: 40)),
      );

      // Page → use case (simulating NatarajDeckPage.initState).
      final fgResult = await setForegroundUseCase.call(LlmTaskKind.nataraj);
      expect(fgResult, isA<Right<dynamic, Unit>>());

      // Submit a gana (T4) and a nataraj. With foreground=nataraj, nataraj
      // becomes T1 and wins.
      final order = <String>[];
      final g = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        work: (_) async => order.add('gana'),
      );
      final n = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (_) async => order.add('nataraj'),
      );
      await Future.wait([blocker, g, n]);

      expect(order, equals(['nataraj', 'gana']));
    });

    test('setForegroundUseCase(null) on dispose drops kind back to T4',
        () async {
      // Hoist nataraj, then immediately clear (simulating Page.dispose).
      await setForegroundUseCase.call(LlmTaskKind.nataraj);
      final clearResult = await setForegroundUseCase.call(null);
      expect(clearResult, isA<Right<dynamic, Unit>>());

      // Both at T4 now; vruntime ties → FIFO.
      final blocker = scheduler.run<void>(
        kind: LlmTaskKind.chat,
        modelId: 'm',
        work: (_) => Future.delayed(const Duration(milliseconds: 30)),
      );
      final order = <String>[];
      final g = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        work: (_) async => order.add('gana'),
      );
      final n = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (_) async => order.add('nataraj'),
      );
      await Future.wait([blocker, g, n]);

      // After clear, no more T1 hoist; gana queued first wins by FIFO.
      expect(order.first, equals('gana'));
    });

    test('foreground transition simulating route change (Nataraj → Gana page)',
        () async {
      // NatarajDeckPage opens.
      await setForegroundUseCase.call(LlmTaskKind.nataraj);
      // User navigates away to GanaFormPage — Nataraj.dispose then
      // Gana.initState. In Flutter the order is push-new → pop-old, so
      // both calls happen back-to-back.
      await setForegroundUseCase.call(null);
      await setForegroundUseCase.call(LlmTaskKind.gana);

      // Now gana is foreground.
      final blocker = scheduler.run<void>(
        kind: LlmTaskKind.chat,
        modelId: 'm',
        work: (_) => Future.delayed(const Duration(milliseconds: 30)),
      );
      final order = <String>[];
      final n = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (_) async => order.add('nataraj'),
      );
      final g = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        work: (_) async => order.add('gana'),
      );
      await Future.wait([blocker, n, g]);

      // gana is T1 → runs first even though nataraj queued earlier.
      expect(order.first, equals('gana'));
    });

    test('coordinator returns Right(unit) symmetrically with use case',
        () async {
      // The use case is a thin adapter; its result type matches the
      // coordinator's. This catches a future "use case starts wrapping
      // in a different Failure" regression.
      final r1 = await setForegroundUseCase.call(LlmTaskKind.chat);
      final r2 = await coordinator.setForeground(LlmTaskKind.chat);
      expect(r1.runtimeType.toString(), equals(r2.runtimeType.toString()));
    });
  });

  group('Multi-producer concurrent submission — vertical slice', () {
    test('chat + nataraj + gana + extract submitted in flurries', () async {
      // Simulates a busy app: user opens chat, while Nataraj is filling,
      // Gana cron fires, and ExtractKnowledge runs in the background.
      // Verifies the full stack does not crash and ordering is sane.

      // Foreground is the Shiv chat surface — chat-only T0 boost.
      // (We don't call setForeground(chat) — chat is T0 unconditionally.)
      final completed = <String>[];

      // Long Nataraj in flight.
      final n = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (cancel) async {
          for (var i = 0; i < 20; i++) {
            if (cancel.isCancelled) return;
            await Future.delayed(const Duration(milliseconds: 5));
          }
          completed.add('nataraj');
        },
      );
      await Future.delayed(const Duration(milliseconds: 10));

      // Background extract backfill.
      final e = scheduler.run<void>(
        kind: LlmTaskKind.extract,
        modelId: 'm',
        work: (_) async {
          await Future.delayed(const Duration(milliseconds: 10));
          completed.add('extract');
        },
      );

      // Gana cron with past deadline.
      final g = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
        work: (_) async {
          await Future.delayed(const Duration(milliseconds: 10));
          completed.add('gana');
        },
      );

      // Chat arrives.
      final c = scheduler.run<void>(
        kind: LlmTaskKind.chat,
        modelId: 'm',
        work: (_) async {
          await Future.delayed(const Duration(milliseconds: 5));
          completed.add('chat');
        },
      );

      await Future.wait([n, e, g, c]);

      // Expectation: chat ran first (T0). Other ordering can vary, but all
      // four must complete without deadlock.
      expect(completed, contains('chat'));
      expect(completed, contains('nataraj'));
      expect(completed, contains('extract'));
      expect(completed, contains('gana'));
      expect(completed.first, equals('chat'));
    });
  });

  group('Model switch — AIModelRunner → InferenceScheduler vertical slice '
      '(issue #160 follow-on)', () {
    late AIModelRunner runner;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettingsStore(await SharedPreferences.getInstance());
      runner = AIModelRunner(scheduler, settings, FlutterEdgeAiGatewayImpl());
    });

    test('gentle switch waits for a running nataraj job to finish, then '
        'runs ahead of a gana that arrived while it waited', () async {
      final order = <String>[];
      final nataraj = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (cancel) async {
          for (var i = 0; i < 10; i++) {
            if (cancel.isCancelled) return;
            await Future.delayed(const Duration(milliseconds: 5));
          }
          order.add('nataraj');
        },
      );
      await Future.delayed(const Duration(milliseconds: 10));

      final switchFuture = runner.runExclusiveModelOperation<void>(
        forcePreempt: false,
        action: () async => order.add('switch'),
      );
      final gana = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        work: (_) async => order.add('gana'),
      );

      await Future.wait([nataraj, switchFuture, gana]);

      expect(order, ['nataraj', 'switch', 'gana']);
    });

    test('forced switch preempts a running chat immediately', () async {
      final order = <String>[];
      final chat = scheduler.run<void>(
        kind: LlmTaskKind.chat,
        modelId: 'm',
        work: (cancel) async {
          for (var i = 0; i < 20; i++) {
            if (cancel.isCancelled) {
              order.add('chat-cancelled');
              return;
            }
            await Future.delayed(const Duration(milliseconds: 5));
          }
          order.add('chat-finished');
        },
      );
      await Future.delayed(const Duration(milliseconds: 10));

      await runner.runExclusiveModelOperation<void>(
        forcePreempt: true,
        action: () async => order.add('switch'),
      );
      await chat;

      expect(order, ['chat-cancelled', 'switch']);
    });

    test('forced switch preempts a running gana, which re-queues and '
        'completes after the switch — no work lost', () async {
      final order = <String>[];
      final gana = scheduler.run<void>(
        kind: LlmTaskKind.gana,
        modelId: 'm',
        work: (cancel) async {
          for (var i = 0; i < 10; i++) {
            if (cancel.isCancelled) return;
            await Future.delayed(const Duration(milliseconds: 5));
          }
          order.add('gana');
        },
      );
      await Future.delayed(const Duration(milliseconds: 10));

      final switchFuture = runner.runExclusiveModelOperation<void>(
        forcePreempt: true,
        action: () async => order.add('switch'),
      );

      await switchFuture;
      await gana; // re-queued run completes after the switch

      expect(order, ['switch', 'gana']);
    });

    test('a queued gentle switch is not disturbed by an unrelated '
        'foreground toggle', () async {
      final order = <String>[];
      final nataraj = scheduler.run<void>(
        kind: LlmTaskKind.nataraj,
        modelId: 'm',
        work: (cancel) async {
          for (var i = 0; i < 10; i++) {
            if (cancel.isCancelled) {
              order.add('nataraj-cancelled');
              return;
            }
            await Future.delayed(const Duration(milliseconds: 5));
          }
          order.add('nataraj');
        },
      );
      await Future.delayed(const Duration(milliseconds: 10));

      final switchFuture = runner.runExclusiveModelOperation<void>(
        forcePreempt: false,
        action: () async => order.add('switch'),
      );

      coordinator.setForeground(LlmTaskKind.gana);

      await Future.wait([nataraj, switchFuture]);

      expect(order, ['nataraj', 'switch']);
    });
  });
}
