import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The backend flutter_edge_ai should *prefer* when opening a model or embedder.
///
/// GPU on every platform. Call sites retry on CPU when the GPU open *throws*,
/// but a native GPU driver crash cannot be caught — if a device reproduces one,
/// pin that device to CPU rather than reverting this globally. Android ran
/// CPU-only until flutter_edge_ai_litertlm (then flutter_edge_ai_litertlm 1.4.1) fixed the OpenCL per-turn
/// native-heap leak (flutter_edge_ai#348).
PreferredBackend get preferredLlmBackend => PreferredBackend.gpu;
