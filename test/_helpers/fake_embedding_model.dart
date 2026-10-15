import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:mocktail/mocktail.dart';

/// The two calls tests stub and verify on an embedder.
abstract class EmbedderCalls {
  Future<List<double>> embed(String text, TaskType taskType);
  Future<void> close();
}

class MockEmbedderCalls extends Mock implements EmbedderCalls {}

/// `EmbeddingModel` is a `base` class since flutter_edge_ai 2.3, so it cannot
/// be mocked with `implements`. This extends it and forwards the text and task
/// type to a mocktail [calls] object: stub `model.calls.embed(any(), any())`.
final class FakeEmbeddingModel extends EmbeddingModel {
  FakeEmbeddingModel({this.dimension = 768, this.maxInputTokens});

  final MockEmbedderCalls calls = MockEmbedderCalls();
  final _listeners = <void Function()>[];
  bool _closed = false;

  @override
  final int dimension;

  @override
  final int? maxInputTokens;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) => calls.embed(input.text ?? '', taskType);

  @override
  void addCloseListener(void Function() listener) => _listeners.add(listener);

  @override
  Future<void> close() async {
    _closed = true;
    for (final l in _listeners) {
      l();
    }
    await calls.close();
  }
}
