import 'package:dartz/dartz.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/services/download_cancellation.dart';

abstract class AIModelRepository {
  /// Returns the catalog of models, with [isRecommended] set based on device RAM.
  Future<List<AIModelEntity>> getAvailableModels();

  /// Returns the model the user has downloaded and activated, or null if none.
  Future<Either<Failure, AIModelEntity?>> getActiveModel();

  /// Forces flutter_edge_ai's in-memory active-model registration onto
  /// [modelId], regardless of what is currently active. Unlike
  /// [getActiveModel] (which only rehydrates when NOTHING is active — a
  /// cheap cold-start check), this always re-links the engine, which is
  /// required after the user explicitly switches between two already-
  /// downloaded local models (a plain settings write leaves flutter_edge_ai
  /// pointed at the old one). [modelId]'s file must already be installed.
  Future<Either<Failure, Unit>> activateModel(AIModelId modelId);

  /// Downloads the model identified by [modelId] and marks it as active.
  /// Emits [AIModelDownloadEvent]s until complete or failed.
  ///
  /// Pass [cancellation] to abort an in-flight download. On cancel, the
  /// stream closes silently — no [AIModelDownloadEvent.failed] is emitted.
  Stream<AIModelDownloadEvent> downloadAndActivateModel(
    AIModelId modelId, {
    DownloadCancellation? cancellation,
  });

  /// Removes the active model selection (does not delete the file).
  Future<Either<Failure, Unit>> clearActiveModel();

  /// Returns IDs of all models whose files are present on disk.
  Future<Set<AIModelId>> getDownloadedModelIds();

  /// Returns total on-disk bytes actually used by flutter_edge_ai's installed
  /// model files (real size, not the catalog's static estimate).
  Future<int> getDownloadedModelsSizeBytes();

  /// Total bytes of files flutter_edge_ai no longer considers part of any
  /// installed model — partial downloads, or files a previous [deleteModel]
  /// couldn't locate by its guessed path. Not counted in
  /// [getDownloadedModelsSizeBytes].
  Future<int> getOrphanedModelFilesSizeBytes();

  /// Deletes every file flutter_edge_ai reports as orphaned. Returns the
  /// number of files removed.
  Future<Either<Failure, int>> cleanupOrphanedModelFiles();

  /// Deletes the model file from disk and removes it from Isar.
  /// If it was the active model, clears the active selection too.
  Future<Either<Failure, Unit>> deleteModel(AIModelId modelId);

}
