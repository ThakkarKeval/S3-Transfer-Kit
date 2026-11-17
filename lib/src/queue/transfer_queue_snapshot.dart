/// An immutable snapshot of the current state of a transfer queue.
class TransferQueueSnapshot {
  /// Constructs a [TransferQueueSnapshot].
  const TransferQueueSnapshot({
    required this.queuedCount,
    required this.runningCount,
    required this.isPaused,
  });

  /// The number of tasks currently waiting in the queue to be executed.
  final int queuedCount;

  /// The number of tasks currently actively running.
  final int runningCount;

  /// Total number of active (queued + running) tasks.
  int get totalActiveCount => queuedCount + runningCount;

  /// Whether the queue is currently paused from scheduling new tasks.
  final bool isPaused;

  @override
  String toString() =>
      'TransferQueueSnapshot(queued: $queuedCount, running: $runningCount, isPaused: $isPaused)';
}
