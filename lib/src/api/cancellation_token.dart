import 'dart:async';

/// Token used to cooperatively request cancellation of an ongoing transfer.
class CancellationToken {
  /// Constructs an uncancelled [CancellationToken].
  CancellationToken();

  bool _isCancelled = false;
  String? _reason;
  final Completer<void> _completer = Completer<void>();
  final List<void Function()> _listeners = <void Function()>[];

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Optional human-readable message describing why cancellation was requested.
  String? get reason => _reason;

  /// A [Future] that completes when cancellation is requested.
  Future<void> get whenCancelled => _completer.future;

  /// Requests cancellation of any transfers observing this token.
  void cancel([String? reason]) {
    if (_isCancelled) return;
    _isCancelled = true;
    _reason = reason;

    if (!_completer.isCompleted) {
      _completer.complete();
    }

    final listeners = List<void Function()>.from(_listeners);
    for (final listener in listeners) {
      listener();
    }
  }

  /// Registers a callback to be notified when cancellation is requested.
  void onCancelled(void Function() callback) {
    if (_isCancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
  }
}
