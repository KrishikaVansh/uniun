/// Which LLM backend currently services chat + extraction.
///
/// [localGemma] — on-device flutter_edge_ai inference. Default.
/// [uniunCloud] — the UNIUN inference gateway (api.uniun.in), authenticated
/// with the user's own Nostr keypair.
enum LlmBackendType {
  localGemma,
  uniunCloud;

  static LlmBackendType? fromName(String? name) {
    if (name == null) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    // Pre-UNIUN builds stored 'openRouter'; that backend is gone — callers
    // fall back to their default (local).
    return null;
  }
}
