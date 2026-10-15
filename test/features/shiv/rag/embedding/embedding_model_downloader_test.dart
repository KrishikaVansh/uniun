import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/data/datasources/llm/flutter_edge_ai_gateway.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_model_downloader.dart';
import 'package:uniun/features/shiv/rag/embedding/embedding_service.dart';

class _MockGateway extends Mock implements FlutterEdgeAiGateway {}

class _MockEmbeddingService extends Mock implements EmbeddingService {}

void main() {
  late _MockGateway gateway;
  late _MockEmbeddingService embeddingService;
  late EmbeddingModelDownloader downloader;

  setUp(() {
    gateway = _MockGateway();
    embeddingService = _MockEmbeddingService();
    downloader = EmbeddingModelDownloader(gateway, embeddingService);
  });

  group('isDownloaded', () {
    test('delegates to the gateway', () async {
      when(() => gateway.hasActiveEmbedder()).thenReturn(true);
      expect(await downloader.isDownloaded(), isTrue);

      when(() => gateway.hasActiveEmbedder()).thenReturn(false);
      expect(await downloader.isDownloaded(), isFalse);
    });
  });

  group('downloadIfNeeded', () {
    test('already installed — skips ensureInstalled entirely', () async {
      when(() => gateway.hasActiveEmbedder()).thenReturn(true);

      await downloader.downloadIfNeeded();

      verifyNever(() => embeddingService.ensureInstalled());
    });

    test('not installed — delegates the install to EmbeddingService',
        () async {
      when(() => gateway.hasActiveEmbedder()).thenReturn(false);
      when(() => embeddingService.ensureInstalled()).thenAnswer((_) async {});

      await downloader.downloadIfNeeded();

      verify(() => embeddingService.ensureInstalled()).called(1);
    });

    test('an install failure is swallowed — fire-and-forget safe', () async {
      when(() => gateway.hasActiveEmbedder()).thenReturn(false);
      when(() => embeddingService.ensureInstalled())
          .thenThrow(Exception('asset copy failed'));

      await downloader.downloadIfNeeded(); // must not throw
    });
  });
}
