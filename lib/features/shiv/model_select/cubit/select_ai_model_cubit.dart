import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:injectable/injectable.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/domain/entities/llm/llm_model_info.dart';
import 'package:uniun/domain/services/download_cancellation.dart';
import 'package:uniun/domain/usecases/ai_model_usecases.dart';
import 'package:uniun/domain/usecases/llm_usecases.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_model_downloader.dart';

part 'select_ai_model_state.dart';
part 'select_ai_model_cubit.freezed.dart';

@injectable
class SelectAIModelCubit extends Cubit<SelectAIModelState> {
  final GetAvailableAIModelsUseCase _getAvailable;
  final GetActiveAIModelUseCase _getActive;
  final GetDownloadedModelIdsUseCase _getDownloaded;
  final DownloadAndActivateAIModelUseCase _download;
  final DeleteAIModelUseCase _deleteModel;
  final EmbeddingModelDownloader _embeddingDownloader;
  final ConnectUniunCloudUseCase _connectCloud;
  final IsUniunCloudConnectedUseCase _isCloudConnected;
  final ListCloudLlmModelsUseCase _listCloudModels;
  final SetActiveLlmBackendUseCase _setBackend;
  final SetActiveLlmModelUseCase _setLlmModel;
  final GetActiveLlmModelUseCase _getLlmModel;
  final GetActiveLlmBackendUseCase _getBackend;
  final GetOrphanedModelFilesSizeBytesUseCase _getOrphanedSize;
  final CleanupOrphanedModelFilesUseCase _cleanupOrphaned;

  StreamSubscription<AIModelDownloadEvent>? _downloadSub;
  DownloadCancellation? _cancellation;

  SelectAIModelCubit(
    this._getAvailable,
    this._getActive,
    this._getDownloaded,
    this._download,
    this._deleteModel,
    this._embeddingDownloader,
    this._connectCloud,
    this._isCloudConnected,
    this._listCloudModels,
    this._setBackend,
    this._setLlmModel,
    this._getLlmModel,
    this._getBackend,
    this._getOrphanedSize,
    this._cleanupOrphaned,
  ) : super(const SelectAIModelState()) {
    _init();
  }

  Future<void> _init() async {
    final models = await _getAvailable.call();
    final activeResult = await _getActive.call();
    final activeId = activeResult.fold((_) => null, (m) => m?.modelId);
    final downloadedIds = await _getDownloaded.call();

    final backendResult = await _getBackend.call();
    final backend =
        backendResult.fold((_) => LlmBackendType.localGemma, (b) => b);

    // Already-connected accounts see their cloud models immediately; a
    // fresh install sees just the sign-in card (no silent login here).
    var cloudModels = const <LlmModelInfo>[];
    String? activeCloudId;
    if (await _isCloudConnected.call()) {
      final cloudResult = await _listCloudModels.call();
      cloudModels = cloudResult.fold((_) => const [], (list) => list);
      final activeModel = await _getLlmModel.call();
      activeCloudId = activeModel.fold(
        (_) => null,
        (m) => m?.backend == LlmBackendType.uniunCloud ? m?.id : null,
      );
    }

    final orphanedSize = await _getOrphanedSize.call();

    emit(state.copyWith(
      models: models,
      activeModelId: activeId,
      downloadedModelIds: downloadedIds,
      activeBackend: backend,
      cloudModels: cloudModels,
      activeCloudModelId: activeCloudId,
      selectedModelId: activeId ??
          models.where((m) => m.isRecommended).firstOrNull?.modelId ??
          models.firstOrNull?.modelId,
      orphanedFilesSizeBytes: orphanedSize,
    ));

    // If a model is already active (app restart with existing model),
    // ensure the embedding model files are also present.
    if (activeId != null) {
      unawaited(_ensureEmbeddingDownloaded());
    }
  }

  Future<void> _ensureEmbeddingDownloaded() async {
    if (await _embeddingDownloader.isDownloaded()) return;
    if (isClosed) return;
    emit(state.copyWith(isEmbeddingDownloading: true));
    await _embeddingDownloader.downloadIfNeeded();
    if (isClosed) return;
    emit(state.copyWith(isEmbeddingDownloading: false));
  }

  Future<void> refresh() => _init();

  void selectModel(AIModelId modelId) {
    if (state.status == SelectAIModelStatus.downloading) return;
    emit(state.copyWith(selectedModelId: modelId));
  }

  Future<void> downloadAndActivate() async {
    final modelId = state.selectedModelId;
    if (modelId == null) return;
    if (state.status == SelectAIModelStatus.downloading) return;

    if (modelId == state.activeModelId) {
      // Re-activating the stored local model still counts as choosing
      // on-device — switch back if the cloud backend was in use.
      await _setBackend.call(LlmBackendType.localGemma);
      emit(state.copyWith(
        status: SelectAIModelStatus.done,
        activeBackend: LlmBackendType.localGemma,
      ));
      return;
    }

    emit(state.copyWith(
      status: SelectAIModelStatus.downloading,
      downloadProgress: 0.0,
      errorMessage: null,
    ));

    _downloadSub?.cancel();
    _cancellation = DownloadCancellation();
    _downloadSub = _download.call(modelId, cancellation: _cancellation).listen(
      (event) {
        event.when(
          progress: (value) =>
              emit(state.copyWith(downloadProgress: value)),
          complete: (id) async {
            // Download embedding model BEFORE emitting done, so the cubit
            // is still alive (navigating away on done closes the cubit).
            if (!await _embeddingDownloader.isDownloaded()) {
              if (isClosed) return;
              emit(state.copyWith(
                downloadProgress: 1.0,
                isEmbeddingDownloading: true,
              ));
              await _embeddingDownloader.downloadIfNeeded();
              if (isClosed) return;
              // Embedding download complete — clear embedding flag
              emit(state.copyWith(
                isEmbeddingDownloading: false,
                downloadProgress: 1.0,
              ));
            }
            if (isClosed) return;
            // A fresh download is an explicit on-device choice — make sure
            // the backend matches (the user may have been on cloud).
            await _setBackend.call(LlmBackendType.localGemma);
            if (isClosed) return;
            // All downloads complete — emit done status
            emit(state.copyWith(
              status: SelectAIModelStatus.done,
              activeModelId: id,
              activeBackend: LlmBackendType.localGemma,
              downloadProgress: 1.0,
              isEmbeddingDownloading: false,
            ));
          },
          failed: (msg) => emit(state.copyWith(
            status: SelectAIModelStatus.error,
            errorMessage: msg,
          )),
        );
      },
      onError: (e) => emit(state.copyWith(
        status: SelectAIModelStatus.error,
        errorMessage: e.toString(),
      )),
    );
  }

  /// Signs in to UNIUN Cloud (silent keypair login) and loads the plan's
  /// models — no download, no backend switch yet. The user then picks one
  /// via [activateCloudModel].
  Future<void> connectCloud() async {
    if (state.isCloudConnecting) return;
    emit(state.copyWith(isCloudConnecting: true, cloudErrorMessage: null));

    final connected = await _connectCloud.call();
    if (connected.isLeft()) {
      if (isClosed) return;
      emit(state.copyWith(
        isCloudConnecting: false,
        cloudErrorMessage: connected.fold((f) => f.toMessage(), (_) => ''),
      ));
      return;
    }

    final models = await _listCloudModels.call();
    final list = models.fold((_) => const <LlmModelInfo>[], (l) => l);
    if (isClosed) return;
    if (list.isEmpty) {
      emit(state.copyWith(
        isCloudConnecting: false,
        cloudErrorMessage: models.fold(
            (f) => f.toMessage(), (_) => 'No cloud models on this plan'),
      ));
      return;
    }
    emit(state.copyWith(isCloudConnecting: false, cloudModels: list));
  }

  /// Activates a cloud model: switches the backend to uniunCloud, persists
  /// the model, fetches the embedder RAG still needs locally, and finishes
  /// the screen — zero downloads.
  Future<void> activateCloudModel(String modelId) async {
    if (state.activatingCloudModelId != null) return;
    if (state.status == SelectAIModelStatus.downloading) return;
    emit(state.copyWith(
        activatingCloudModelId: modelId, cloudErrorMessage: null));

    final switched = await _setBackend.call(LlmBackendType.uniunCloud);
    final failure = await switched.fold(
      (f) async => f,
      (_) async {
        final set = await _setLlmModel.call(modelId);
        return set.fold((f) => f, (_) => null);
      },
    );
    if (isClosed) return;
    if (failure != null) {
      emit(state.copyWith(
        activatingCloudModelId: null,
        cloudErrorMessage: failure.toString(),
      ));
      return;
    }

    await _ensureEmbeddingDownloaded();
    if (isClosed) return;
    emit(state.copyWith(
      activatingCloudModelId: null,
      activeCloudModelId: modelId,
      activeBackend: LlmBackendType.uniunCloud,
      status: SelectAIModelStatus.done,
    ));
  }

  Future<void> cancelDownload() async {
    if (state.status != SelectAIModelStatus.downloading) return;

    _cancellation?.cancel();
    _cancellation = null;
    await _downloadSub?.cancel();
    _downloadSub = null;

    if (isClosed) return;
    emit(state.copyWith(
      status: SelectAIModelStatus.initial,
      downloadProgress: 0.0,
      errorMessage: null,
    ));
  }

  Future<void> deleteModel(AIModelId modelId) async {
    if (state.deletingModelId != null) return;
    emit(state.copyWith(deletingModelId: modelId));
    final result = await _deleteModel.call(modelId);
    result.fold(
      (f) => emit(state.copyWith(
        deletingModelId: null,
        errorMessage: f.toString(),
      )),
      (_) async {
        final downloadedIds = await _getDownloaded.call();
        final activeId = state.activeModelId == modelId ? null : state.activeModelId;
        emit(state.copyWith(
          deletingModelId: null,
          downloadedModelIds: downloadedIds,
          activeModelId: activeId,
          // If we deleted the selected model, fall back to first available.
          selectedModelId: state.selectedModelId == modelId
              ? (state.models.firstOrNull?.modelId)
              : state.selectedModelId,
        ));
      },
    );
  }

  /// Deletes every leftover model file flutter_edge_ai no longer tracks
  /// (partial downloads, files a previous delete couldn't locate). Returns
  /// the number of files removed, or null on failure — the caller decides
  /// how to surface either outcome (this cubit has no toast/snackbar state).
  Future<int?> cleanupOrphanedFiles() async {
    if (state.isCleaningUpFiles) return null;
    emit(state.copyWith(isCleaningUpFiles: true));
    final result = await _cleanupOrphaned.call();
    if (isClosed) return null;
    return result.fold(
      (f) {
        emit(state.copyWith(isCleaningUpFiles: false));
        return null;
      },
      (removedCount) {
        emit(state.copyWith(
          isCleaningUpFiles: false,
          orphanedFilesSizeBytes: 0,
        ));
        return removedCount;
      },
    );
  }

  @override
  Future<void> close() {
    _cancellation?.cancel();
    _downloadSub?.cancel();
    return super.close();
  }
}
