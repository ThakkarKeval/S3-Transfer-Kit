import 'dart:async';

import '../api/cancellation_token.dart';
import '../api/transfer_task.dart';
import '../exceptions/transfer_exception.dart';
import '../models/transfer_execution_mode.dart';
import '../models/transfer_priority.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_status.dart';
import 'transfer_queue_configuration.dart';
import 'transfer_queue_snapshot.dart';

class _QueueItem<T> {
  _QueueItem({
    required this.id,
    required this.priority,
    required this.executionMode,
    required this.sequenceNumber,
    required this.runner,
    required this.resultCompleter,
    required this.progressController,
    required this.statusController,
    required this.task,
    this.cancellationToken,
  });

  final String id;
  final TransferPriority priority;
  final TransferExecutionMode executionMode;
  final int sequenceNumber;
  final Future<T> Function(
    void Function(TransferProgress),
    void Function(TransferStatus),
  )
  runner;
  final Completer<T> resultCompleter;
  final StreamController<TransferProgress> progressController;
  final StreamController<TransferStatus> statusController;
  final S3TransferTask<T> task;
  final CancellationToken? cancellationToken;

  bool isPaused = false;
}

/// A priority-based, concurrency-limiting queue for coordinating transfer operations.
class TransferQueue {
  /// Constructs a [TransferQueue] with the given [configuration].
  TransferQueue({TransferQueueConfiguration? configuration})
    : configuration = configuration ?? const TransferQueueConfiguration() {
    _emitSnapshot();
  }

  /// Configuration governing concurrency and scheduling defaults.
  final TransferQueueConfiguration configuration;

  final List<_QueueItem<dynamic>> _queuedItems = [];
  final Map<String, _QueueItem<dynamic>> _runningItems = {};
  final Map<String, S3TransferTask<dynamic>> _allTasks = {};

  final StreamController<TransferQueueSnapshot> _snapshotController =
      StreamController<TransferQueueSnapshot>.broadcast();

  int _sequenceCounter = 0;
  bool _isPaused = false;
  bool _isDisposed = false;

  /// Whether the queue is currently paused from launching new tasks.
  bool get isPaused => _isPaused;

  /// Number of tasks currently waiting in the queue.
  int get queuedCount => _queuedItems.where((item) => !item.isPaused).length;

  /// Number of tasks currently actively executing.
  int get runningCount => _runningItems.length;

  /// Current immutable snapshot of the queue state.
  TransferQueueSnapshot get snapshot => TransferQueueSnapshot(
    queuedCount: _queuedItems.length,
    runningCount: _runningItems.length,
    isPaused: _isPaused,
  );

  /// Broadcast stream emitting updates whenever queue statistics change.
  Stream<TransferQueueSnapshot> get snapshotStream =>
      _snapshotController.stream;

  /// Enqueues a new transfer task for managed execution.
  S3TransferTask<T> enqueue<T>({
    required String id,
    required Future<T> Function(
      void Function(TransferProgress),
      void Function(TransferStatus),
    )
    runner,
    TransferPriority? priority,
    TransferExecutionMode? executionMode,
    CancellationToken? cancellationToken,
  }) {
    if (_isDisposed) {
      throw StateError('Cannot enqueue tasks on a disposed TransferQueue.');
    }

    final resolvedPriority = priority ?? configuration.defaultPriority;
    final resolvedExecutionMode =
        executionMode ?? configuration.defaultExecutionMode;

    final progressController = StreamController<TransferProgress>.broadcast();
    final statusController = StreamController<TransferStatus>.broadcast();
    final resultCompleter = Completer<T>();

    late final S3TransferTask<T> task;
    task = S3TransferTask<T>(
      id: id,
      priority: resolvedPriority,
      executionMode: resolvedExecutionMode,
      cancellationToken: cancellationToken,
      progressStream: progressController.stream,
      statusStream: statusController.stream,
      resultFuture: resultCompleter.future,
      onPause: () => pauseTask(id),
      onResume: () => resumeTask(id),
    );

    final item = _QueueItem<T>(
      id: id,
      priority: resolvedPriority,
      executionMode: resolvedExecutionMode,
      sequenceNumber: ++_sequenceCounter,
      runner: runner,
      resultCompleter: resultCompleter,
      progressController: progressController,
      statusController: statusController,
      task: task,
      cancellationToken: cancellationToken,
    );

    _queuedItems.add(item);
    _allTasks[id] = task;

    // Listen for early cancellation while in queue
    cancellationToken?.onCancelled(() {
      if (_queuedItems.contains(item)) {
        _handleQueuedItemCancelled(item, cancellationToken.reason);
      }
    });

    _emitSnapshot();
    _drain();

    return task;
  }

  /// Pauses the entire queue, preventing new tasks from starting.
  void pauseQueue() {
    if (_isPaused || _isDisposed) return;
    _isPaused = true;
    _emitSnapshot();
  }

  /// Resumes queue execution and starts eligible waiting tasks.
  void resumeQueue() {
    if (!_isPaused || _isDisposed) return;
    _isPaused = false;
    _emitSnapshot();
    _drain();
  }

  /// Pauses a specific task.
  ///
  /// If the task is queued, it will be skipped by the scheduler until resumed.
  void pauseTask(String id) {
    final queuedIndex = _queuedItems.indexWhere((item) => item.id == id);
    if (queuedIndex != -1) {
      final item = _queuedItems[queuedIndex];
      item.isPaused = true;
      item.task.updateStatus(TransferStatus.paused);
      if (!item.statusController.isClosed) {
        item.statusController.add(TransferStatus.paused);
      }
      _emitSnapshot();
    }
  }

  /// Resumes a specific task that was paused.
  void resumeTask(String id) {
    final queuedIndex = _queuedItems.indexWhere((item) => item.id == id);
    if (queuedIndex != -1) {
      final item = _queuedItems[queuedIndex];
      if (item.isPaused) {
        item.isPaused = false;
        item.task.updateStatus(TransferStatus.enqueued);
        if (!item.statusController.isClosed) {
          item.statusController.add(TransferStatus.enqueued);
        }
        _emitSnapshot();
        _drain();
      }
    }
  }

  /// Cancels a specific task by [id].
  void cancelTask(String id, [String? reason]) {
    final queuedIndex = _queuedItems.indexWhere((item) => item.id == id);
    if (queuedIndex != -1) {
      final item = _queuedItems.removeAt(queuedIndex);
      _handleQueuedItemCancelled(item, reason);
      return;
    }

    final runningItem = _runningItems[id];
    if (runningItem != null) {
      runningItem.cancellationToken?.cancel(reason);
    }
  }

  /// Cancels all active tasks in the queue.
  void cancelAll([String? reason]) {
    final queuedCopy = List<_QueueItem<dynamic>>.from(_queuedItems);
    _queuedItems.clear();

    for (final item in queuedCopy) {
      _handleQueuedItemCancelled(item, reason);
    }

    for (final runningItem in _runningItems.values) {
      runningItem.cancellationToken?.cancel(reason);
    }

    _emitSnapshot();
  }

  /// Looks up a registered task by [id].
  S3TransferTask<dynamic>? getTask(String id) => _allTasks[id];

  void _drain() {
    if (_isPaused || _isDisposed) return;

    while (_runningItems.length < configuration.maxConcurrentTransfers) {
      final nextIndex = _findNextEligibleItemIndex();
      if (nextIndex == -1) break;

      final item = _queuedItems.removeAt(nextIndex);
      _startItem(item);
    }
  }

  int _findNextEligibleItemIndex() {
    int bestIndex = -1;
    _QueueItem<dynamic>? bestItem;

    for (int i = 0; i < _queuedItems.length; i++) {
      final item = _queuedItems[i];
      if (item.isPaused) continue;

      if (bestItem == null) {
        bestItem = item;
        bestIndex = i;
        continue;
      }

      // Priority comparison: higher priority first
      final priorityComparison = item.priority.compareTo(bestItem.priority);
      if (priorityComparison > 0) {
        bestItem = item;
        bestIndex = i;
      } else if (priorityComparison == 0) {
        // Equal priority: FIFO by sequence number
        if (item.sequenceNumber < bestItem.sequenceNumber) {
          bestItem = item;
          bestIndex = i;
        }
      }
    }

    return bestIndex;
  }

  void _startItem(_QueueItem<dynamic> item) {
    _runningItems[item.id] = item;
    item.task.updateStatus(TransferStatus.inProgress);
    if (!item.statusController.isClosed) {
      item.statusController.add(TransferStatus.inProgress);
    }

    _emitSnapshot();

    item
        .runner(
          (progress) {
            if (!item.progressController.isClosed) {
              item.progressController.add(progress);
            }
          },
          (status) {
            item.task.updateStatus(status);
            if (!item.statusController.isClosed) {
              item.statusController.add(status);
            }
          },
        )
        .then((result) {
          if (!item.resultCompleter.isCompleted) {
            item.resultCompleter.complete(result);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (!item.resultCompleter.isCompleted) {
            item.resultCompleter.completeError(error, stackTrace);
          }
        })
        .whenComplete(() {
          _runningItems.remove(item.id);
          _closeControllers(item);
          _emitSnapshot();
          _drain();
        });
  }

  void _handleQueuedItemCancelled(_QueueItem<dynamic> item, String? reason) {
    _queuedItems.remove(item);
    item.task.updateStatus(TransferStatus.cancelled);
    if (!item.statusController.isClosed) {
      item.statusController.add(TransferStatus.cancelled);
    }
    if (!item.resultCompleter.isCompleted) {
      item.resultCompleter.completeError(
        TransferException.cancelled(reason: reason),
      );
    }
    _closeControllers(item);
    _emitSnapshot();
  }

  void _closeControllers(_QueueItem<dynamic> item) {
    if (!item.progressController.isClosed) {
      item.progressController.close();
    }
    if (!item.statusController.isClosed) {
      item.statusController.close();
    }
  }

  void _emitSnapshot() {
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  /// Disposes the queue and cleans up internal streams.
  Future<void> dispose() async {
    _isDisposed = true;
    _snapshotController.close();
  }
}
