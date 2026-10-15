import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:injectable/injectable.dart';

/// Thin seam around every `FlutterEdgeAi.*` static call [AIModelRunner],
/// [AIModelRepositoryImpl], and [EmbeddingService] make. Exists purely so
/// those classes' real logic (retry, backend fallback, prompt composition,
/// scheduler coordination, orchestration branching) can be unit tested with
/// a mock — `FlutterEdgeAi`'s own statics have no seam of their own, and the
/// plugin's real behavior needs either a device or `FlutterEdgeAi.
/// initialize()` + mocked platform channels (both already used elsewhere
/// this session, neither reaches every branch these classes have).
///
/// [FlutterEdgeAiGatewayImpl] is a one-line passthrough per method — it is
/// deliberately NOT unit tested beyond a smoke check; it IS the boundary.
abstract class FlutterEdgeAiGateway {
  bool hasActiveModel();

  Future<InferenceModel> getActiveModel({
    required int maxTokens,
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    int? maxNumImages,
  });

  Future<bool> isModelInstalled(String filename);

  /// Simple install/re-link — the shape [AIModelRepositoryImpl.
  /// _installAndActivate] needs. Not for downloads with progress; see
  /// [installModelWithProgress] for that.
  Future<void> installModel({
    required ModelType modelType,
    required ModelFileType fileType,
    required String networkUrl,
  });

  /// The full download flow with progress + cancellation, matching what
  /// [AIModelRepositoryImpl.downloadAndActivateModel] drives today.
  /// Completes the stream on success; adds an error and completes on
  /// failure (including cancellation, which surfaces as an error the
  /// caller checks via `CancelToken.isCancel`).
  Stream<int> installModelWithProgress({
    required ModelType modelType,
    required ModelFileType fileType,
    required String networkUrl,
    required CancelToken cancelToken,
  });

  Future<void> uninstallModel(String filename);

  Future<StorageStats> getStorageInfo();

  Future<List<OrphanedFileInfo>> getOrphanedFiles();

  Future<int> cleanupStorage();

  // ── Embedder (used by EmbeddingService) ─────────────────────────────────

  bool hasActiveEmbedder();

  Future<EmbeddingModel> getActiveEmbedder({PreferredBackend? preferredBackend});

  /// Installs the bundled embedder from the given asset paths. Idempotent —
  /// callers check [hasActiveEmbedder] first.
  Future<void> installEmbedder({
    required String modelAsset,
    required String tokenizerAsset,
  });
}

@Injectable(as: FlutterEdgeAiGateway)
class FlutterEdgeAiGatewayImpl implements FlutterEdgeAiGateway {
  @override
  bool hasActiveModel() => FlutterEdgeAi.hasActiveModel();

  @override
  Future<InferenceModel> getActiveModel({
    required int maxTokens,
    PreferredBackend? preferredBackend,
    bool supportImage = false,
    int? maxNumImages,
  }) =>
      FlutterEdgeAi.getActiveModel(
        maxTokens: maxTokens,
        preferredBackend: preferredBackend,
        supportImage: supportImage,
        maxNumImages: maxNumImages,
      );

  @override
  Future<bool> isModelInstalled(String filename) =>
      FlutterEdgeAi.isModelInstalled(filename);

  /// Android-only: runs the download under a dataSync foreground service, so a
  /// multi-GB model survives backgrounding and Doze. iOS gains nothing from it
  /// but a notification-permission prompt, so it keeps the plugin default.
  static bool? get _foreground => Platform.isAndroid ? true : null;

  @override
  Future<void> installModel({
    required ModelType modelType,
    required ModelFileType fileType,
    required String networkUrl,
  }) =>
      FlutterEdgeAi.installModel(modelType: modelType, fileType: fileType)
          .fromNetwork(networkUrl, foreground: _foreground)
          .install();

  @override
  Stream<int> installModelWithProgress({
    required ModelType modelType,
    required ModelFileType fileType,
    required String networkUrl,
    required CancelToken cancelToken,
  }) {
    final controller = StreamController<int>();
    FlutterEdgeAi.installModel(modelType: modelType, fileType: fileType)
        .fromNetwork(networkUrl, foreground: _foreground)
        .withProgress((percent) {
          if (!controller.isClosed) controller.add(percent);
        })
        .withCancelToken(cancelToken)
        .install()
        .then((_) {
          if (!controller.isClosed) controller.close();
        })
        .catchError((Object e) {
          if (!controller.isClosed) {
            controller.addError(e);
            controller.close();
          }
        });
    return controller.stream;
  }

  @override
  Future<void> uninstallModel(String filename) =>
      FlutterEdgeAi.uninstallModel(filename);

  @override
  Future<StorageStats> getStorageInfo() => FlutterEdgeAi.getStorageInfo();

  @override
  Future<List<OrphanedFileInfo>> getOrphanedFiles() =>
      FlutterEdgeAi.getOrphanedFiles();

  @override
  Future<int> cleanupStorage() => FlutterEdgeAi.cleanupStorage();

  @override
  bool hasActiveEmbedder() => FlutterEdgeAi.hasActiveEmbedder();

  @override
  Future<EmbeddingModel> getActiveEmbedder({PreferredBackend? preferredBackend}) =>
      FlutterEdgeAi.getActiveEmbedder(preferredBackend: preferredBackend);

  @override
  Future<void> installEmbedder({
    required String modelAsset,
    required String tokenizerAsset,
  }) =>
      FlutterEdgeAi.installEmbedder()
          .modelFromAsset(modelAsset)
          .tokenizerFromAsset(tokenizerAsset)
          .install();
}
