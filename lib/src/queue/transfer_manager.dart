import 'dart:async';
import 'dart:io';

import '../api/cancellation_token.dart';
import '../api/transfer_task.dart';
import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';
import '../models/download_request.dart';
import '../models/download_result.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import '../multipart/multipart_upload_coordinator.dart';
import '../multipart/multipart_upload_request.dart';
import '../multipart/s3_multipart_provider.dart';
import '../network/http_streaming_transport.dart';
import '../network/transfer_transport.dart';
import '../persistence/persistent_transfer_record.dart';
import '../persistence/transfer_store.dart';
import '../persistence/transfer_type.dart';
import '../retry/retrying_transport.dart';
import '../utils/file_validator.dart';
import 'transfer_queue.dart';
import 'transfer_queue_configuration.dart';
import 'transfer_queue_snapshot.dart';

/// Central orchestrator coordinating transfer execution, concurrency limits, persistence, and lifecycle events.
class TransferManager {
  /// Constructs a [TransferManager].
  TransferManager({
    TransferQueueConfiguration? configuration,
    TransferTransport? transport,
    MultipartUploadCoordinator? multipartCoordinator,
    TransferStore? transferStore,
  }) : _configuration = configuration ?? const TransferQueueConfiguration(),
       _transport = transport is RetryingTransport
           ? transport
           : RetryingTransport(
               transport ?? HttpStreamingTransport(),
               defaultRetryPolicy:
                   (configuration ?? const TransferQueueConfiguration())
                       .defaultRetryPolicy,
             ),
       _transferStore = transferStore,
       _multipartCoordinator =
           multipartCoordinator ??
           MultipartUploadCoordinator(store: transferStore),
       _queue = TransferQueue(configuration: configuration);

  final TransferQueueConfiguration _configuration;
  final TransferTransport _transport;
  final MultipartUploadCoordinator _multipartCoordinator;
  final TransferStore? _transferStore;
  final TransferQueue _queue;

  int _taskIdCounter = 0;

  /// Underlying transfer queue managing scheduling and concurrency.
  TransferQueue get queue => _queue;

  /// Active queue configuration.
  TransferQueueConfiguration get configuration => _configuration;

  /// Optional transfer persistence store.
  TransferStore? get transferStore => _transferStore;

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
            retryPolicy: request.retryPolicy,
          )
        : request;

    return _queue.enqueue<S3UploadResult>(
      id: taskId,
      priority: effectiveRequest.priority,
      executionMode: effectiveRequest.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) async {
        if (_transferStore != null) {
          final now = DateTime.now();
          final file = File(effectiveRequest.filePath);
          final length = await file.exists() ? await file.length() : 0;
          await _transferStore.save(
            PersistentTransferRecord(
              id: taskId,
              type: TransferType.singleUpload,
              status: TransferStatus.inProgress,
              filePath: effectiveRequest.filePath,
              fileLength: length,
              createdAt: now,
              updatedAt: now,
              contentType: effectiveRequest.contentType,
            ),
          );
        }

        try {
          final result = await _transport.upload(
            effectiveRequest,
            onProgress: onProgress,
            onStatusChanged: (status) {
              onStatusChanged(status);
              if (_transferStore != null) {
                _transferStore.get(taskId).then((rec) {
                  if (rec != null) {
                    _transferStore.save(
                      rec.copyWith(status: status, updatedAt: DateTime.now()),
                    );
                  }
                });
              }
            },
          );

          if (_transferStore != null) {
            final rec = await _transferStore.get(taskId);
            if (rec != null) {
              await _transferStore.save(
                rec.copyWith(
                  status: TransferStatus.completed,
                  updatedAt: DateTime.now(),
                ),
              );
            }
          }
          return result;
        } catch (e) {
          if (_transferStore != null) {
            final rec = await _transferStore.get(taskId);
            if (rec != null) {
              await _transferStore.save(
                rec.copyWith(
                  status: token.isCancelled
                      ? TransferStatus.cancelled
                      : TransferStatus.failed,
                  updatedAt: DateTime.now(),
                ),
              );
            }
          }
          rethrow;
        }
      },
    );
  }

  /// Enqueues a multipart upload transfer for large files.
  S3UploadTask enqueueMultipartUpload(S3MultipartUploadRequest request) {
    final taskId =
        'multipart_upload_${++_taskIdCounter}_${DateTime.now().millisecondsSinceEpoch}';

    final token = request.cancellationToken ?? CancellationToken();
    final effectiveRequest = request.cancellationToken == null
        ? S3MultipartUploadRequest(
            filePath: request.filePath,
            provider: request.provider,
            partSize: request.partSize,
            maxConcurrentParts: request.maxConcurrentParts,
            contentType: request.contentType,
            customHeaders: request.customHeaders,
            cancellationToken: token,
            priority: request.priority,
            executionMode: request.executionMode,
            retryPolicy: request.retryPolicy,
          )
        : request;

    return _queue.enqueue<S3UploadResult>(
      id: taskId,
      priority: effectiveRequest.priority,
      executionMode: effectiveRequest.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) => _multipartCoordinator.upload(
        effectiveRequest,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
        taskId: taskId,
      ),
    );
  }

  /// Enqueues a download transfer.
  S3DownloadTask enqueueDownload(S3DownloadRequest request) {
    final taskId =
        'download_${++_taskIdCounter}_${DateTime.now().millisecondsSinceEpoch}';

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
            retryPolicy: request.retryPolicy,
          )
        : request;

    return _queue.enqueue<S3DownloadResult>(
      id: taskId,
      priority: effectiveRequest.priority,
      executionMode: effectiveRequest.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) async {
        if (_transferStore != null) {
          final now = DateTime.now();
          await _transferStore.save(
            PersistentTransferRecord(
              id: taskId,
              type: TransferType.download,
              status: TransferStatus.inProgress,
              filePath: effectiveRequest.destinationPath,
              fileLength: 0,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        try {
          final result = await _transport.download(
            effectiveRequest,
            onProgress: onProgress,
            onStatusChanged: (status) {
              onStatusChanged(status);
              if (_transferStore != null) {
                _transferStore.get(taskId).then((rec) {
                  if (rec != null) {
                    _transferStore.save(
                      rec.copyWith(status: status, updatedAt: DateTime.now()),
                    );
                  }
                });
              }
            },
          );

          if (_transferStore != null) {
            final rec = await _transferStore.get(taskId);
            if (rec != null) {
              await _transferStore.save(
                rec.copyWith(
                  status: TransferStatus.completed,
                  fileLength: result.bytesTransferred,
                  updatedAt: DateTime.now(),
                ),
              );
            }
          }
          return result;
        } catch (e) {
          if (_transferStore != null) {
            final rec = await _transferStore.get(taskId);
            if (rec != null) {
              await _transferStore.save(
                rec.copyWith(
                  status: token.isCancelled
                      ? TransferStatus.cancelled
                      : TransferStatus.failed,
                  updatedAt: DateTime.now(),
                ),
              );
            }
          }
          rethrow;
        }
      },
    );
  }

  /// Retrieves all transfer records currently stored that are pending or active (in-progress, enqueued, or paused).
  Future<List<PersistentTransferRecord>> getPendingTransfers() async {
    if (_transferStore == null) return [];
    return _transferStore.getActive();
  }

  /// Resumes an interrupted multipart upload using its persistent record.
  ///
  /// Validates that the local source file still exists and matches the recorded length before resuming.
  Future<S3UploadTask> resumeMultipartUpload({
    required String taskId,
    required S3MultipartProvider provider,
    int? maxConcurrentParts,
    CancellationToken? cancellationToken,
  }) async {
    if (_transferStore == null) {
      throw StateError(
        'Cannot resume transfer: no TransferStore configured on TransferManager.',
      );
    }

    final record = await _transferStore.get(taskId);
    if (record == null) {
      throw TransferException(
        code: TransferErrorCode.unexpectedFailure,
        message: 'No persistent transfer record found for task ID: $taskId',
      );
    }

    if (record.type != TransferType.multipartUpload ||
        record.uploadId == null) {
      throw TransferException(
        code: TransferErrorCode.unexpectedFailure,
        message: 'Task $taskId is not a multipart upload.',
      );
    }

    // Validate local file integrity
    final file = File(record.filePath);
    final fileLength = await FileValidator.validateUploadFile(file);
    if (fileLength != record.fileLength) {
      throw TransferException(
        code: TransferErrorCode.fileValidationFailed,
        message:
            'Cannot resume multipart upload: local file size changed from ${record.fileLength} to $fileLength bytes.',
      );
    }

    final token = cancellationToken ?? CancellationToken();
    final request = S3MultipartUploadRequest(
      filePath: record.filePath,
      provider: provider,
      partSize: record.partSize ?? S3MultipartUploadRequest.defaultPartSize,
      maxConcurrentParts:
          maxConcurrentParts ??
          S3MultipartUploadRequest.defaultMaxConcurrentParts,
      contentType: record.contentType ?? 'application/octet-stream',
      cancellationToken: token,
    );

    return _queue.enqueue<S3UploadResult>(
      id: taskId,
      priority: request.priority,
      executionMode: request.executionMode,
      cancellationToken: token,
      runner: (onProgress, onStatusChanged) => _multipartCoordinator.upload(
        request,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
        taskId: taskId,
        resumeRecord: record,
      ),
    );
  }

  /// Cleans up old orphaned transfer records, optionally aborting in-flight multipart uploads on S3.
  ///
  /// Returns the number of pruned transfer records.
  Future<int> cleanOrphanedTransfers({
    Duration olderThan = const Duration(days: 1),
    S3MultipartProvider? provider,
  }) async {
    if (_transferStore == null) return 0;

    final records = await _transferStore.getAll();
    final cutoff = DateTime.now().subtract(olderThan);
    int cleanedCount = 0;

    for (final record in records) {
      if (record.updatedAt.isBefore(cutoff) &&
          record.status != TransferStatus.completed) {
        if (record.type == TransferType.multipartUpload &&
            record.uploadId != null &&
            provider != null) {
          try {
            await provider.abortMultipartUpload(uploadId: record.uploadId!);
          } catch (_) {}
        }
        await _transferStore.delete(record.id);
        cleanedCount++;
      }
    }

    return cleanedCount;
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
