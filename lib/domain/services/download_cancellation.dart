import 'dart:async';

/// Domain-side cancellation handle for long-running downloads.
///
/// Kept pure-Dart so the domain layer does not import any data-layer
/// download library (e.g. flutter_edge_ai's `CancelToken`). The repository
/// implementation bridges this to whatever the underlying downloader uses.
class DownloadCancellation {
  final Completer<void> _completer = Completer<void>();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  /// Completes once [cancel] is invoked. Bridges can `await` this to forward
  /// the signal to a concrete downloader token.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}
