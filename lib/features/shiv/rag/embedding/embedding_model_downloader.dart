import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';

/// Installs the bundled Gecko embedding model into flutter_edge_ai's managed
/// storage so [EmbeddingService] can open it.
///
/// The model ships as an app asset (no network download), so this just copies
/// it into place once. Called by [SelectAIModelCubit] when the user downloads
/// their first LLM model, so the one-time asset copy happens behind the model
/// download progress UI rather than on the first Shiv message.
///
/// Name/method kept ("download") for call-site compatibility — it no longer
/// hits the network.
@lazySingleton
class EmbeddingModelDownloader {
  EmbeddingModelDownloader(this._gateway, this._embeddingService);

  final FlutterEdgeAiGateway _gateway;
  final EmbeddingService _embeddingService;

  /// True once the bundled embedder is installed and active.
  Future<bool> isDownloaded() async => _gateway.hasActiveEmbedder();

  /// Install the bundled embedder if not already active.
  /// Fire-and-forget safe — errors are logged but not rethrown.
  Future<void> downloadIfNeeded() async {
    if (await isDownloaded()) {
      debugPrint('📦 Embedding: already installed, skipping.');
      return;
    }
    debugPrint('📦 Embedding: installing bundled model…');
    try {
      await _embeddingService.ensureInstalled();
      debugPrint('📦 Embedding: install complete ✅');
    } catch (e) {
      debugPrint('📦 Embedding: install failed ❌ $e');
      // Non-fatal — EmbeddingService degrades gracefully if the model is absent.
    }
  }
}
