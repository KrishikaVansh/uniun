import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/utils/llm_backend.dart';

/// Covers: preferredLlmBackend prefers GPU on every platform — Android
/// included, now that the OpenCL leak that kept it CPU-only is fixed.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android prefers GPU', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(preferredLlmBackend, PreferredBackend.gpu);
  });

  test('every platform prefers GPU', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(preferredLlmBackend, PreferredBackend.gpu, reason: '$platform');
    }
  });
}
