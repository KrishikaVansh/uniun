/// Outcome of one Gana run, persisted on `GanaRunModel`.
enum GanaRunStatus {
  /// Run started; the engine crashed or the app died before completion.
  running,

  /// Run completed, output enqueued for publish, cursor advanced.
  succeeded,

  /// Run was a no-op. Cursor is NOT advanced — input is retried next trigger.
  /// See [GanaSkipReason] for which kind of skip.
  skipped,

  /// Run hit an unexpected error (parser failed, publish use case threw, etc.).
  /// Cursor NOT advanced. `error` carries the message.
  failed,
}

/// Why a [GanaRunStatus.skipped] run was a no-op.
enum GanaSkipReason {
  /// `FlutterEdgeAi.hasActiveModel() == false` — user hasn't installed/loaded
  /// a model. Retry on next trigger.
  noActiveModel,

  /// Gana's `desiredModelId` is non-null and != current active model id.
  modelMismatch,

  /// Input filter returned nothing (and the Gana has an input source).
  noNewInput,

  /// The model swapped mid-run; the engine cancelled this run.
  modelSwapped,

  /// The model returned `<NOOP>` or empty body — explicit "nothing to say."
  noopReturned,

  /// Recurring Gana has hit its `maxOutputs` cap. Engine auto-disables the
  /// Gana so subsequent triggers don't keep skipping forever. User can
  /// raise the cap and re-enable.
  maxOutputsReached,

  /// `desiredBackend == uniunCloud` but UNIUN Cloud isn't connected, or no
  /// cloud model is set. Retry on next trigger.
  cloudUnavailable,
}
