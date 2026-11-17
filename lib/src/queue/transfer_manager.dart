import 'dart:async';

import '../api/cancellation_token.dart';
import '../api/transfer_task.dart';
import '../models/download_request.dart';
import '../models/download_result.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../network/http_streaming_transport.dart';
import '../network/transfer_transport.dart';
import 'transfer_queue.dart';
import 'transfer_queue_configuration.dart';
import 'transfer_queue_snapshot.dart';

/// Central orchestrator coordinating transfer execution, concurrency limits, and lifecycle events.
class TransferManager {
  /// Constructs a [TransferManager].
  TransferManager({
    TransferQueueConfiguration? configuration,
    TransferTransport? transport,
  }) : _transport = transport ?? HttpStreamingTransport(),
       _queue = TransferQueue(configuration: configuration);

  final TransferTransport _transport;
  final TransferQueue _queue;

  int _taskIdCounter = 0;

  /// Underlying transfer queue managing scheduling and concurrency.
  TransferQueue get queue => _queue;

  /// Current queue state snapshot.
  TransferQueueSnapshot get snapshot => _queue.snapshot;

  /// Broadcast stream emitting queue state changes.
  Stream<TransferQueueSnapshot> get snapshotStream => _queue.snapshotStream;

  /// Whether the manager's queue is currently paused.
  bool get isPaused => _queue.isPaused;

  /// Number of tasks currently queued.
  int get queuedCount => _queue.queuedCount;

  /// Number of tasks currently running.
  int get runningCount => _queue.runningCount;

  /// Enqueues an upload transfer.
  S3UploadTask enqueueUpload(S3UploadRequest request) {
    final taskId =
        'upload_${++_taskIdCounter}_${DateTime.now().millisecondsSinceEpoch}';

    // If request didn't supply a CancellationToken, provide one for task-level control
    final token = request.cancellationToken ?? CancellationToken();
    final effectiveRequest = request.cancellationToken == null
        ? S3UploadRequest(
            filePath: request.filePath,
            authorization: request.authorization,
            contentType: request.contentType,
            customHeaders: request.customHeaders,
            cancellationToken: token,
            priority: request.priority,
            executionMode: request.executionMode,
          )
        : request;

    return _queue.enqueue<S3UploadResult>(
      id: taskId,
      priority: effectiveRequest.priority,
      executionMode: effectiveRequest.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) => _transport.upload(
        effectiveRequest,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
      ),
    );
  }

  /// Enqueues a download transfer.
  S3DownloadTask enqueueDownload(S3DownloadRequest request) {
    final taskId =
        'download_${++_taskIdCounter}_${DateTime.now().millisecondsSinceEpoch}';

    // If request didn't supply a CancellationToken, provide one for task-level control
    final token = request.cancellationToken ?? CancellationToken();
    final effectiveRequest = request.cancellationToken == null
        ? S3DownloadRequest(
            destinationPath: request.destinationPath,
            authorization: request.authorization,
            overwrite: request.overwrite,
            customHeaders: request.customHeaders,
            cancellationToken: token,
            priority: request.priority,
            executionMode: request.executionMode,
          )
        : request;

    return _queue.enqueue<S3DownloadResult>(
      id: taskId,
      priority: effectiveRequest.priority,
      executionMode: effectiveRequest.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) => _transport.download(
        effectiveRequest,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
      ),
    );
  }

  /// Pauses a specific task.
  void pauseTask(String taskId) => _queue.pauseTask(taskId);

  /// Resumes a specific paused task.
  void resumeTask(String taskId) => _queue.resumeTask(taskId);

  /// Cancels a specific task by [taskId].
  void cancelTask(String taskId, [String? reason]) =>
      _queue.cancelTask(taskId, reason);

  /// Pauses the entire queue, preventing waiting tasks from starting.
  void pauseAll() => _queue.pauseQueue();

  /// Resumes execution of the queue.
  void resumeAll() => _queue.resumeQueue();

  /// Cancels all queued and executing tasks.
  void cancelAll([String? reason]) => _queue.cancelAll(reason);

  /// Looks up an active task by [taskId].
  S3TransferTask<dynamic>? getTask(String taskId) => _queue.getTask(taskId);

  /// Disposes resources and closes internal streams.
  Future<void> dispose() async {
    await _queue.dispose();
  }
}
