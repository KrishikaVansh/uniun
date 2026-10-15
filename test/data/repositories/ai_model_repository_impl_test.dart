import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/datasources/app_settings_store.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/data/datasources/llm/local_llm_runner.dart';
import 'package:uniun/data/models/ai_model_selection_model.dart';
import 'package:uniun/data/repositories/ai_model_repository_impl.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/services/download_cancellation.dart';

import '../../_helpers/fake_path_provider.dart';
import '../../_helpers/isar_test_harness.dart';

class _MockSettings extends Mock implements AppSettingsStore {}

class _MockRunner extends Mock implements AIModelRunner {}

class _MockGateway extends Mock implements FlutterEdgeAiGateway {}

/// Covers: AIModelRepositoryImpl.activateModel/deleteModel's orchestration
/// decisions — when they route through AIModelRunner's scheduler-coordinated
/// path, and with which forcePreempt value, vs. when they skip it entirely
/// (issue #160 follow-on: model-switch/delete must not race an in-flight
/// generation against the native engine).
///
/// Two test styles, deliberately kept side by side:
///
///  1. The top-level groups use a REAL `FlutterEdgeAi.initialize()` (with
///     mocked shared_preferences) via the real `FlutterEdgeAiGatewayImpl` —
///     proving the repository genuinely works against flutter_edge_ai's real
///     static surface, not just a mock's promise that it would. Nothing is
///     ever actually downloaded in this environment, so only the "not
///     installed yet" branches are reachable this way.
///  2. The "with a mocked gateway" group below doubles `FlutterEdgeAiGateway`
///     (the seam introduced specifically to close this gap — see
///     docs/AUDIT.md) to reach the "model IS installed / IS active"
///     success branches a real empty environment can never simulate:
///     `getActiveModel`'s rehydration paths, `activateModel`'s success
///     path, the full `downloadAndActivateModel` progress/cancel/failure
///     stream, storage introspection, and `deleteModel`'s uninstall
///     success + manual-file-delete-fallback branches.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(AIModelId.qwen25_05b);
    registerFallbackValue(() async {});
    registerFallbackValue(() async => const Right<Failure, Unit>(unit));
    registerFallbackValue(ModelType.gemmaIt);
    registerFallbackValue(ModelFileType.task);
    registerFallbackValue(CancelToken());
  });

  late Isar isar;
  late _MockSettings settings;
  late _MockRunner runner;
  late AIModelRepositoryImpl repo;
  late Directory tempDir;

  setUp(() async {
    isar = await openTestIsar();
    settings = _MockSettings();
    runner = _MockRunner();
    repo = AIModelRepositoryImpl(isar, settings, runner, FlutterEdgeAiGatewayImpl());

    tempDir = await Directory.systemTemp.createTemp('ai_model_repo_test');
    PathProviderPlatform.instance = FakePathProviderPlatform(
      docs: tempDir.path,
      support: tempDir.path,
    );

    SharedPreferences.setMockInitialValues({});
    await FlutterEdgeAi.initialize();
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
    await tempDir.delete(recursive: true);
  });

  // `AIModelRepositoryImpl.activateModel`/`downloadAndActivateModel` both
  // guard `_catalog.where((m) => m.modelId == modelId).firstOrNull == null`
  // before proceeding — but `modelId`'s type is the `AIModelId` enum, and
  // `_catalog` carries exactly one entry per enum value, so that null case
  // is structurally unreachable through the public API, not just untested.
  // Left uncovered rather than fabricating an unreachable call.
  group('modelForRamMb (pure RAM-threshold logic)', () {
    test('null or non-positive RAM falls back to DeepSeek R1', () {
      expect(AIModelRepositoryImpl.modelForRamMb(null), AIModelId.deepseekR1);
      expect(AIModelRepositoryImpl.modelForRamMb(0), AIModelId.deepseekR1);
      expect(AIModelRepositoryImpl.modelForRamMb(-1), AIModelId.deepseekR1);
    });

    test('under 3 GB recommends Qwen3 0.6B', () {
      expect(AIModelRepositoryImpl.modelForRamMb(1), AIModelId.qwen25_05b);
      expect(AIModelRepositoryImpl.modelForRamMb(2999), AIModelId.qwen25_05b);
    });

    test('3–5 GB recommends DeepSeek R1', () {
      expect(AIModelRepositoryImpl.modelForRamMb(3000), AIModelId.deepseekR1);
      expect(AIModelRepositoryImpl.modelForRamMb(4999), AIModelId.deepseekR1);
    });

    test('5–7 GB recommends Gemma 4 E2B', () {
      expect(AIModelRepositoryImpl.modelForRamMb(5000), AIModelId.gemma4E2b);
      expect(AIModelRepositoryImpl.modelForRamMb(6999), AIModelId.gemma4E2b);
    });

    test('7 GB and above recommends Gemma 4 E4B', () {
      expect(AIModelRepositoryImpl.modelForRamMb(7000), AIModelId.gemma4E4b);
      expect(
          AIModelRepositoryImpl.modelForRamMb(32000), AIModelId.gemma4E4b);
    });
  });

  group('activateModel', () {
    test('a model that is not actually downloaded fails before ever '
        'reaching the runner', () async {
      final result = await repo.activateModel(AIModelId.gemma4E2b);

      expect(result.isLeft(), isTrue);
      verifyNever(() => runner.runExclusiveModelOperation<Either<Failure, Unit>>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          ));
    });
  });

  group('deleteModel', () {
    test('deleting a model that is NOT the active one never touches the '
        'runner', () async {
      when(() => settings.activeModelId).thenReturn(AIModelId.gemma4E4b);

      final result = await repo.deleteModel(AIModelId.deepseekR1);

      expect(result.isRight(), isTrue);
      verifyNever(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          ));
      verifyNever(() => settings.setActiveModelId(any()));
    });

    test('deleting the currently-active model routes through the runner '
        'with forcePreempt:true, then clears the active setting', () async {
      when(() => settings.activeModelId).thenReturn(AIModelId.deepseekR1);
      when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});
      when(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          )).thenAnswer((invocation) async {
        final action = invocation.namedArguments[#action] as Future<void>
            Function();
        await action();
      });

      final result = await repo.deleteModel(AIModelId.deepseekR1);

      expect(result.isRight(), isTrue);
      verify(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: true,
            action: any(named: 'action'),
          )).called(1);
      verify(() => settings.setActiveModelId(null)).called(1);
    });

    // ── Negative ────────────────────────────────────────────────────────

    test('the runner rejecting the wrapped action surfaces as a Left, not '
        'silently swallowed', () async {
      when(() => settings.activeModelId).thenReturn(AIModelId.deepseekR1);
      when(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          )).thenThrow(Exception('scheduler blew up'));

      final result = await repo.deleteModel(AIModelId.deepseekR1);

      expect(result.isLeft(), isTrue);
      verifyNever(() => settings.setActiveModelId(any()));
    });

    test('deleting an unknown/never-installed model that happens to be '
        '"active" in settings still routes through the forced path '
        'harmlessly', () async {
      when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
      when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});
      when(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          )).thenAnswer((invocation) async {
        final action = invocation.namedArguments[#action] as Future<void>
            Function();
        await action();
      });

      final result = await repo.deleteModel(AIModelId.qwen25_05b);

      expect(result.isRight(), isTrue);
      verify(() => runner.runExclusiveModelOperation<void>(
            forcePreempt: true,
            action: any(named: 'action'),
          )).called(1);
    });
  });

  group('with a mocked gateway — the "installed"/success branches a real, '
      'empty FlutterEdgeAi.initialize() environment can never reach', () {
    late _MockGateway gateway;
    late AIModelRepositoryImpl repo2;

    setUp(() {
      gateway = _MockGateway();
      repo2 = AIModelRepositoryImpl(isar, settings, runner, gateway);
      when(() => runner.runExclusiveModelOperation<Either<Failure, Unit>>(
            forcePreempt: any(named: 'forcePreempt'),
            action: any(named: 'action'),
          )).thenAnswer((invocation) async {
        final action = invocation.namedArguments[#action]
            as Future<Either<Failure, Unit>> Function();
        return action();
      });
    });

    group('getActiveModel', () {
      test('installed + already active — returns the entry without '
          're-linking', () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => true);
        when(() => gateway.hasActiveModel()).thenReturn(true);

        final result = await repo2.getActiveModel();

        expect(result.isRight(), isTrue);
        result.fold((_) => fail('expected Right'), (m) {
          expect(m?.modelId, AIModelId.qwen25_05b);
          expect(m?.isDownloaded, isTrue);
        });
        verifyNever(() => gateway.installModel(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
            ));
      });

      test('installed but NOTHING active yet — cold-start re-links it',
          () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.deepseekR1);
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => true);
        when(() => gateway.hasActiveModel()).thenReturn(false);
        when(() => gateway.installModel(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
            )).thenAnswer((_) async {});

        final result = await repo2.getActiveModel();

        expect(result.isRight(), isTrue);
        verify(() => gateway.installModel(
              modelType: ModelType.deepSeek,
              fileType: ModelFileType.task,
              networkUrl: any(named: 'networkUrl'),
            )).called(1);
      });

      test('not actually installed anymore (reinstall / storage wipe) — '
          'resets the active model and returns Right(null)', () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
        when(() => settings.setActiveModelId(null)).thenAnswer((_) async {});
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => false);

        final result = await repo2.getActiveModel();

        expect(result, const Right<Failure, AIModelEntity?>(null));
        verify(() => settings.setActiveModelId(null)).called(1);
      });

      test('a gateway failure surfaces as Left, not an uncaught throw',
          () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
        when(() => gateway.isModelInstalled(any()))
            .thenThrow(Exception('native layer not ready'));

        final result = await repo2.getActiveModel();

        expect(result.isLeft(), isTrue);
      });
    });

    group('clearActiveModel', () {
      test('clears the setting and returns Right(unit)', () async {
        when(() => settings.setActiveModelId(null)).thenAnswer((_) async {});

        final result = await repo2.clearActiveModel();

        expect(result, const Right<Failure, Unit>(unit));
      });

      test('a settings failure surfaces as Left', () async {
        when(() => settings.setActiveModelId(null))
            .thenThrow(Exception('prefs write failed'));

        final result = await repo2.clearActiveModel();

        expect(result.isLeft(), isTrue);
      });
    });

    group('getAvailableModels', () {
      test('returns every catalog entry with exactly one marked recommended',
          () async {
        final models = await repo2.getAvailableModels();

        expect(models, hasLength(4));
        expect(models.where((m) => m.isRecommended), hasLength(1));
      });
    });

    group('activateModel', () {
      test('installed model activates through the runner and re-links '
          'the gateway', () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => true);
        when(() => gateway.installModel(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
            )).thenAnswer((_) async {});

        final result = await repo2.activateModel(AIModelId.gemma4E2b);

        expect(result.isRight(), isTrue);
        verify(() => runner.runExclusiveModelOperation<Either<Failure, Unit>>(
              forcePreempt: false,
              action: any(named: 'action'),
            )).called(1);
        verify(() => gateway.installModel(
              modelType: ModelType.gemma4,
              fileType: ModelFileType.litertlm,
              networkUrl: any(named: 'networkUrl'),
            )).called(1);
      });

      test('a gateway failure surfaces as Left, not an uncaught throw',
          () async {
        when(() => gateway.isModelInstalled(any()))
            .thenThrow(Exception('native layer not ready'));

        final result = await repo2.activateModel(AIModelId.gemma4E2b);

        expect(result.isLeft(), isTrue);
        verifyNever(() => runner.runExclusiveModelOperation<Either<Failure, Unit>>(
              forcePreempt: any(named: 'forcePreempt'),
              action: any(named: 'action'),
            ));
      });
    });

    group('downloadAndActivateModel', () {
      test('already installed — skips the download, activates directly',
          () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => true);
        when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});

        final events = await repo2
            .downloadAndActivateModel(AIModelId.qwen25_05b)
            .toList();

        expect(events, [const AIModelDownloadEvent.complete(AIModelId.qwen25_05b)]);
        verify(() => settings.setActiveModelId(AIModelId.qwen25_05b)).called(1);
        verifyNever(() => gateway.installModelWithProgress(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
              cancelToken: any(named: 'cancelToken'),
            ));
      });

      test('already installed but persisting the activation fails — '
          'yields AIModelDownloadEvent.failed', () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => true);
        when(() => settings.setActiveModelId(any()))
            .thenThrow(Exception('prefs write failed'));

        final events = await repo2
            .downloadAndActivateModel(AIModelId.qwen25_05b)
            .toList();

        expect(events, hasLength(1));
        expect(events.single, isA<AIModelDownloadFailed>());
      });

      test('not installed — streams progress, persists the Isar record, '
          'and completes', () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => false);
        when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});
        when(() => gateway.installModelWithProgress(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
              cancelToken: any(named: 'cancelToken'),
            )).thenAnswer((_) => Stream.fromIterable([0, 50, 100]));

        final events = await repo2
            .downloadAndActivateModel(AIModelId.qwen25_05b)
            .toList();

        expect(events, [
          const AIModelDownloadEvent.progress(0.0),
          const AIModelDownloadEvent.progress(0.5),
          const AIModelDownloadEvent.progress(1.0),
          const AIModelDownloadEvent.complete(AIModelId.qwen25_05b),
        ]);
        final record = await isar.aIModelSelectionModels
            .filter()
            .modelIdEqualTo(AIModelId.qwen25_05b)
            .findFirst();
        expect(record, isNotNull);
        verify(() => settings.setActiveModelId(AIModelId.qwen25_05b)).called(1);
      });

      test('a genuine (non-cancel) failure yields AIModelDownloadEvent.failed',
          () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => false);
        when(() => gateway.installModelWithProgress(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
              cancelToken: any(named: 'cancelToken'),
            )).thenAnswer(
                (_) => Stream.error(Exception('network unreachable')));

        final events = await repo2
            .downloadAndActivateModel(AIModelId.deepseekR1)
            .toList();

        expect(events, hasLength(1));
        expect(events.single, isA<AIModelDownloadFailed>());
      });

      test('download completes but persisting the selection fails — '
          'yields AIModelDownloadEvent.failed after streaming progress',
          () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => false);
        when(() => gateway.installModelWithProgress(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
              cancelToken: any(named: 'cancelToken'),
            )).thenAnswer((_) => Stream.fromIterable([100]));
        when(() => settings.setActiveModelId(any()))
            .thenThrow(Exception('prefs write failed'));

        final events = await repo2
            .downloadAndActivateModel(AIModelId.deepseekR1)
            .toList();

        expect(events, [
          const AIModelDownloadEvent.progress(1.0),
          isA<AIModelDownloadFailed>(),
        ]);
      });

      test('a cooperative cancellation ends the stream silently — no '
          'failed event', () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((_) async => false);
        when(() => gateway.installModelWithProgress(
              modelType: any(named: 'modelType'),
              fileType: any(named: 'fileType'),
              networkUrl: any(named: 'networkUrl'),
              cancelToken: any(named: 'cancelToken'),
            )).thenAnswer((_) => Stream.fromFutures([
                  Future.error(
                      DownloadCancelledException('User cancelled', null)),
                ]));
        final cancellation = DownloadCancellation()..cancel();

        final events = await repo2
            .downloadAndActivateModel(AIModelId.deepseekR1,
                cancellation: cancellation)
            .toList();

        expect(events, isEmpty);
      });
    });

    group('getDownloadedModelIds / storage introspection', () {
      test('reports exactly the catalog entries the gateway confirms '
          'installed', () async {
        when(() => gateway.isModelInstalled(any())).thenAnswer((invocation) async {
          final filename = invocation.positionalArguments.single as String;
          return filename.contains('deepseek') || filename.contains('Qwen3');
        });

        final downloaded = await repo2.getDownloadedModelIds();

        expect(downloaded, {AIModelId.qwen25_05b, AIModelId.deepseekR1});
      });

      test('getDownloadedModelsSizeBytes forwards the gateway\'s total',
          () async {
        when(() => gateway.getStorageInfo()).thenAnswer(
            (_) async => const StorageStats(totalFiles: 2, totalSizeBytes: 4096, orphanedFiles: []));

        expect(await repo2.getDownloadedModelsSizeBytes(), 4096);
      });

      test('getOrphanedModelFilesSizeBytes sums every orphan\'s size',
          () async {
        when(() => gateway.getOrphanedFiles()).thenAnswer((_) async => [
              const OrphanedFileInfo(
                filename: 'a.task',
                path: '/tmp/a.task',
                sizeBytes: 100,
                lastModified: null,
                isDownloadFragment: false,
              ),
              const OrphanedFileInfo(
                filename: 'b.task',
                path: '/tmp/b.task',
                sizeBytes: 250,
                lastModified: null,
                isDownloadFragment: true,
              ),
            ]);

        expect(await repo2.getOrphanedModelFilesSizeBytes(), 350);
      });

      test('cleanupOrphanedModelFiles surfaces the removed count as Right',
          () async {
        when(() => gateway.cleanupStorage()).thenAnswer((_) async => 3);

        final result = await repo2.cleanupOrphanedModelFiles();

        expect(result, const Right<Failure, int>(3));
      });

      test('cleanupOrphanedModelFiles surfaces a gateway failure as Left',
          () async {
        when(() => gateway.cleanupStorage())
            .thenThrow(Exception('storage handle busy'));

        final result = await repo2.cleanupOrphanedModelFiles();

        expect(result.isLeft(), isTrue);
      });
    });

    group('deleteModel', () {
      setUp(() {
        when(() => runner.runExclusiveModelOperation<void>(
              forcePreempt: any(named: 'forcePreempt'),
              action: any(named: 'action'),
            )).thenAnswer((invocation) async {
          final action =
              invocation.namedArguments[#action] as Future<void> Function();
          await action();
        });
      });

      test('uninstallModel succeeds cleanly and removes the matching Isar '
          'selection record', () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
        when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});
        when(() => gateway.uninstallModel(any())).thenAnswer((_) async {});
        await isar.writeTxn(() async {
          await isar.aIModelSelectionModels.put(AIModelSelectionModel()
            ..modelId = AIModelId.qwen25_05b
            ..modelName = AIModelId.qwen25_05b.name
            ..modelPath = AIModelId.qwen25_05b.name
            ..downloadedAt = DateTime.now());
        });

        final result = await repo2.deleteModel(AIModelId.qwen25_05b);

        expect(result.isRight(), isTrue);
        verify(() => gateway.uninstallModel(any())).called(1);
        final record = await isar.aIModelSelectionModels
            .filter()
            .modelIdEqualTo(AIModelId.qwen25_05b)
            .findFirst();
        expect(record, isNull);
      });

      test('uninstallModel throws — falls back to deleting the file '
          'straight off disk', () async {
        when(() => settings.activeModelId).thenReturn(AIModelId.qwen25_05b);
        when(() => settings.setActiveModelId(any())).thenAnswer((_) async {});
        when(() => gateway.uninstallModel(any()))
            .thenThrow(Exception('metadata already gone'));
        final orphan = File('${tempDir.path}/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm');
        orphan.writeAsStringSync('fake model bytes');
        expect(orphan.existsSync(), isTrue);

        final result = await repo2.deleteModel(AIModelId.qwen25_05b);

        expect(result.isRight(), isTrue);
        expect(orphan.existsSync(), isFalse);
      });
    });
  });
}
