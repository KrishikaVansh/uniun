import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:system_info_plus/system_info_plus.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/datasources/app_settings_store.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/data/datasources/llm/local_llm_runner.dart';
import 'package:uniun/data/models/ai_model_selection_model.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/repositories/ai_model_repository.dart';
import 'package:uniun/domain/services/download_cancellation.dart';
import 'package:path/path.dart' as p;

@Injectable(as: AIModelRepository)
class AIModelRepositoryImpl implements AIModelRepository {
  final Isar _isar;
  final AppSettingsStore _settings;
  final AIModelRunner _runner;
  final FlutterEdgeAiGateway _gateway;

  AIModelRepositoryImpl(this._isar, this._settings, this._runner, this._gateway);

  // ── Model catalog ────────────────────────────────────────────────────────────
  // All URLs are real HuggingFace releases compatible with flutter_edge_ai (then flutter_edge_ai 0.13.x)
  // on Android and iOS (no auth token required).
  //
  // Mobile file format rules:
  //  .task      → MediaPipe LiteRT engine (Android + iOS)
  //  .litertlm  → LiteRT-LM engine       (Android + iOS + Desktop)
  //
  // Gemma 4 E2B/E4B use .litertlm (LiteRT-LM). All others use .task.

  // Base catalog — isRecommended is set dynamically in getAvailableModels()
  // based on device RAM so users always see the right suggestion.
  static const List<AIModelEntity> _catalog = [
    AIModelEntity(
      modelId: AIModelId.qwen25_05b,
      sizeLabel: '329 MB',
      sizeBytes: 344671744,
      tier: AIModelTier.lite,
      isRecommended: false,
      optimization: AIModelOptimization.cpu,
      downloadUrl:
          'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
    ),
    AIModelEntity(
      modelId: AIModelId.deepseekR1,
      sizeLabel: '1.7 GB',
      sizeBytes: 1825964032,
      tier: AIModelTier.balanced,
      isRecommended: false,
      optimization: AIModelOptimization.cpu,
      downloadUrl:
          'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/deepseek_q8_ekv1280.task',
    ),
    AIModelEntity(
      modelId: AIModelId.gemma4E2b,
      sizeLabel: '2.4 GB',
      sizeBytes: 2576980377,
      tier: AIModelTier.performance,
      isRecommended: false,
      optimization: AIModelOptimization.gpuCpu,
      downloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    ),
    AIModelEntity(
      modelId: AIModelId.gemma4E4b,
      sizeLabel: '4.3 GB',
      sizeBytes: 4617089638,
      tier: AIModelTier.flagship,
      isRecommended: false,
      optimization: AIModelOptimization.gpu,
      downloadUrl:
          'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
    ),
  ];

  /// flutter_edge_ai engine params — separate from the public entity fields.
  /// Each entry MUST match the chat template the model file was trained with;
  /// passing the wrong [ModelType] to `openChat` makes the SDK render a
  /// template that the model can't parse → leading whitespace tokens,
  /// degraded quality.
  static const Map<AIModelId, ({ModelType modelType, ModelFileType fileType})>
      _gemmaParams = {
    AIModelId.qwen25_05b: (
      modelType: ModelType.qwen3,
      fileType: ModelFileType.litertlm,
    ),
    AIModelId.deepseekR1: (
      modelType: ModelType.deepSeek,
      fileType: ModelFileType.task,
    ),
    AIModelId.gemma4E2b: (
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ),
    AIModelId.gemma4E4b: (
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ),
  };

  @override
  Future<List<AIModelEntity>> getAvailableModels() async {
    final recommended = await _recommendedModelId();
    return _catalog
        .map((m) => m.copyWith(isRecommended: m.modelId == recommended))
        .toList();
  }

  /// Reads total physical RAM and returns the best-fit model ID.
  /// Thresholds (conservative — model size + OS overhead):
  ///   < 3 GB  → Qwen3 0.6B
  ///   3–5 GB  → DeepSeek R1
  ///   5–7 GB  → Gemma 4 E2B
  ///   ≥ 7 GB  → Gemma 4 E4B
  static Future<AIModelId> _recommendedModelId() async {
    try {
      // physicalMemory returns MB, or null on unsupported platforms.
      final totalMb = await SystemInfoPlus.physicalMemory;
      return modelForRamMb(totalMb);
    } catch (_) {
      return AIModelId.deepseekR1;
    }
  }

  /// The pure threshold logic, split out from [_recommendedModelId] so it's
  /// directly unit-testable — `SystemInfoPlus.physicalMemory` is a real
  /// platform-channel call with no fake in this environment, but the
  /// decision it feeds has no such ceiling.
  @visibleForTesting
  static AIModelId modelForRamMb(int? totalMb) {
    if (totalMb == null || totalMb <= 0) return AIModelId.deepseekR1;
    if (totalMb < 3000) return AIModelId.qwen25_05b;
    if (totalMb < 5000) return AIModelId.deepseekR1;
    if (totalMb < 7000) return AIModelId.gemma4E2b;
    return AIModelId.gemma4E4b;
  }

  // ── Active model ─────────────────────────────────────────────────────────────

  @override
  Future<Either<Failure, AIModelEntity?>> getActiveModel() async {
    try {
      final activeId = _settings.activeModelId;
      if (activeId == null) return const Right(null);

      final entry = _catalog.where((m) => m.modelId == activeId).firstOrNull;
      if (entry == null) return const Right(null);

      final filename = p.basename(Uri.parse(entry.downloadUrl).path);
      final isInstalled = await _gateway.isModelInstalled(filename);

      if (!isInstalled) {
        // Files cleared (app reinstall / storage wipe) — reset active model.
        await clearActiveModel();
        return const Right(null);
      }

      // Cheap cold-start rehydration: only re-links when NOTHING is active
      // yet. Does NOT catch "a DIFFERENT model is active" — that case is
      // [activateModel]'s job, called explicitly on every model switch.
      if (!_gateway.hasActiveModel()) {
        await _installAndActivate(entry);
      }

      return Right(entry.copyWith(isDownloaded: true));
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> activateModel(AIModelId modelId) async {
    try {
      final entry = _catalog.where((m) => m.modelId == modelId).firstOrNull;
      if (entry == null) {
        return Left(Failure.errorFailure('Unknown local model: $modelId'));
      }

      final filename = p.basename(Uri.parse(entry.downloadUrl).path);
      final isInstalled = await _gateway.isModelInstalled(filename);
      if (!isInstalled) {
        return Left(Failure.errorFailure(
            'Model ${modelId.name} is not downloaded yet.'));
      }

      // Unconditional — this is the explicit-switch path, so re-link
      // flutter_edge_ai to [modelId] even if a DIFFERENT model is currently
      // active (settings alone was already updated by the caller). Routed
      // through the scheduler (gentle — waits for whatever's running to
      // finish naturally, then jumps the queue) so the swap never races an
      // in-flight generation against the native engine.
      return await _runner.runExclusiveModelOperation<Either<Failure, Unit>>(
        forcePreempt: false,
        action: () async {
          await _installAndActivate(entry);
          return const Right(unit);
        },
      );
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  /// Re-links flutter_edge_ai's in-memory active model to [entry]. The file is
  /// already confirmed installed by the caller, so `.install()` here is a
  /// fast local re-link, not a re-download.
  Future<void> _installAndActivate(AIModelEntity entry) async {
    final params = _gemmaParams[entry.modelId]!;
    await _gateway.installModel(
      modelType: params.modelType,
      fileType: params.fileType,
      networkUrl: entry.downloadUrl,
    );
  }

  @override
  Future<Either<Failure, Unit>> clearActiveModel() async {
    try {
      await _settings.setActiveModelId(null);
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  // ── Download ─────────────────────────────────────────────────────────────────

  @override
  Stream<AIModelDownloadEvent> downloadAndActivateModel(
    AIModelId modelId, {
    DownloadCancellation? cancellation,
  }) async* {
    final entry = _catalog.where((m) => m.modelId == modelId).firstOrNull;
    if (entry == null) {
      yield AIModelDownloadEvent.failed('Unknown model: ${modelId.name}');
      return;
    }

    final params = _gemmaParams[modelId]!;
    final filename = _filename(modelId);

    // Already on disk — skip download, just activate.
    if (await _gateway.isModelInstalled(filename)) {
      try {
        await _settings.setActiveModelId(modelId);
        yield AIModelDownloadEvent.complete(modelId);
      } catch (e) {
        yield AIModelDownloadEvent.failed(e.toString());
      }
      return;
    }

    // Bridge the domain cancellation handle to flutter_edge_ai's CancelToken.
    final cancelToken = CancelToken();
    final cancelBridge = cancellation?.whenCancelled.then((_) {
      if (!cancelToken.isCancelled) cancelToken.cancel('User cancelled');
    });

    final progressStream = _gateway.installModelWithProgress(
      modelType: params.modelType,
      fileType: params.fileType,
      networkUrl: entry.downloadUrl,
      cancelToken: cancelToken,
    );

    try {
      await for (final percent in progressStream) {
        yield AIModelDownloadEvent.progress(percent / 100.0);
      }
    } catch (e) {
      if (CancelToken.isCancel(e)) {
        // Silent close — caller initiated the cancel, no failure to report.
        return;
      }
      yield AIModelDownloadEvent.failed(e.toString());
      return;
    } finally {
      // Detach the bridge so a later cancel() doesn't fire a stale token.
      unawaited(cancelBridge ?? Future<void>.value());
    }

    // install() completed — persist download record to Isar and active
    // selection to SharedPreferences.
    try {
      await _isar.writeTxn(() async {
        final prev = await _isar.aIModelSelectionModels
            .filter()
            .modelIdEqualTo(modelId)
            .findFirst();
        final model = prev ?? AIModelSelectionModel();
        model.modelId = modelId;
        model.modelName = modelId.name;
        model.modelPath = modelId.name;
        model.downloadedAt = DateTime.now();
        await _isar.aIModelSelectionModels.put(model);
      });
      await _settings.setActiveModelId(modelId);

      yield AIModelDownloadEvent.complete(modelId);
    } catch (e) {
      yield AIModelDownloadEvent.failed(e.toString());
    }
  }

  // ── Downloaded models ────────────────────────────────────────────────────────

  static String _filename(AIModelId id) {
    final entry = _catalog.firstWhere((m) => m.modelId == id);
    return p.basename(Uri.parse(entry.downloadUrl).path);
  }

  @override
  Future<Set<AIModelId>> getDownloadedModelIds() async {
    final downloaded = <AIModelId>{};
    for (final model in _catalog) {
      final filename = _filename(model.modelId);
      if (await _gateway.isModelInstalled(filename)) {
        downloaded.add(model.modelId);
      }
    }
    return downloaded;
  }

  @override
  Future<int> getDownloadedModelsSizeBytes() async {
    final info = await _gateway.getStorageInfo();
    return info.totalSizeBytes;
  }

  @override
  Future<int> getOrphanedModelFilesSizeBytes() async {
    final files = await _gateway.getOrphanedFiles();
    return files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
  }

  @override
  Future<Either<Failure, int>> cleanupOrphanedModelFiles() async {
    try {
      final removed = await _gateway.cleanupStorage();
      return Right(removed);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteModel(AIModelId modelId) async {
    try {
      final filename = _filename(modelId);
      final isActive = _settings.activeModelId == modelId;

      // Use flutter_edge_ai's uninstall to clear both the file and internal
      // metadata so isModelInstalled() returns false afterwards.
      Future<void> uninstallNative() async {
        try {
          await _gateway.uninstallModel(filename);
        } catch (_) {
          // Fallback: manual file delete in case metadata was already gone.
          final dir = await getApplicationDocumentsDirectory();
          final file = File(p.join(dir.path, filename));
          if (file.existsSync()) await file.delete();
        }
      }

      if (isActive) {
        // Forced — the file is being removed, so unlike a plain switch we
        // can't wait for whatever's running to finish on its own. Nataraj/
        // Gana recover for free via the scheduler's existing re-queue
        // policy; a cancelled chat turn finalizes with partial content.
        await _runner.runExclusiveModelOperation<void>(
          forcePreempt: true,
          action: uninstallNative,
        );
      } else {
        // Not the active model — nothing native is at risk, no need to
        // coordinate with the scheduler.
        await uninstallNative();
      }

      await _isar.writeTxn(() async {
        final record = await _isar.aIModelSelectionModels
            .filter()
            .modelIdEqualTo(modelId)
            .findFirst();
        if (record != null) {
          await _isar.aIModelSelectionModels.delete(record.id);
        }
      });
      if (isActive) {
        await _settings.setActiveModelId(null);
      }

      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

}
