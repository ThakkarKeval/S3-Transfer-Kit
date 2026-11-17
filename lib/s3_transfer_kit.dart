import 'dart:async';

import 's3_transfer_kit_platform_interface.dart';
import 'src/api/transfer_task.dart';
import 'src/models/download_request.dart';
import 'src/models/transfer_request.dart';
import 'src/multipart/multipart_upload_coordinator.dart';
import 'src/multipart/multipart_upload_request.dart';
import 'src/network/transfer_transport.dart';
import 'src/queue/transfer_manager.dart';
import 'src/queue/transfer_queue.dart';
import 'src/queue/transfer_queue_configuration.dart';
import 'src/queue/transfer_queue_snapshot.dart';

export 'src/api/cancellation_token.dart';
export 'src/api/transfer_task.dart';
export 'src/auth/s3_authorization.dart';
export 'src/exceptions/transfer_error_code.dart';
export 'src/exceptions/transfer_exception.dart';
export 'src/models/download_request.dart';
export 'src/models/download_result.dart';
export 'src/models/transfer_execution_mode.dart';
export 'src/models/transfer_priority.dart';
export 'src/models/transfer_progress.dart';
export 'src/models/transfer_request.dart';
export 'src/models/transfer_result.dart';
export 'src/models/transfer_status.dart';
export 'src/multipart/multipart_upload_coordinator.dart';
export 'src/multipart/multipart_upload_request.dart';
export 'src/multipart/s3_multipart_provider.dart';
export 'src/multipart/s3_part.dart';
export 'src/multipart/s3_part_etag.dart';
export 'src/queue/transfer_manager.dart';
export 'src/queue/transfer_queue.dart';
export 'src/queue/transfer_queue_configuration.dart';
export 'src/queue/transfer_queue_snapshot.dart';
export 'src/retry/retry_classifier.dart';
export 'src/retry/retry_policy.dart';
export 'src/retry/retrying_transport.dart';

/// Primary entrypoint and facade for the S3 Transfer Kit library.
class S3TransferKit {
  /// Constructs an [S3TransferKit] instance.
  ///
  /// Optionally accepts a custom [transport], [configuration], or [multipartCoordinator] for testing or platform-specific execution.
  S3TransferKit({
    TransferTransport? transport,
    TransferQueueConfiguration? configuration,
    MultipartUploadCoordinator? multipartCoordinator,
  }) : _manager = TransferManager(
         transport: transport,
         configuration: configuration,
         multipartCoordinator: multipartCoordinator,
       );

  final TransferManager _manager;

  /// Underlying transfer manager coordinating execution and queue state.
  TransferManager get manager => _manager;

  /// Underlying transfer queue.
  TransferQueue get queue => _manager.queue;

  /// Current queue state snapshot.
  TransferQueueSnapshot get snapshot => _manager.snapshot;

  /// Broadcast stream emitting updates when queue statistics change.
  Stream<TransferQueueSnapshot> get snapshotStream => _manager.snapshotStream;

  /// Returns the platform version reported by the registered native implementation.
  Future<String?> getPlatformVersion() =>
      S3TransferKitPlatform.instance.getPlatformVersion();

  /// Enqueues and initiates a single-file upload to an S3-compatible destination.
  ///
  /// Managed by the queue according to priority, execution mode, and concurrency limits.
  S3UploadTask upload(S3UploadRequest request) =>
      _manager.enqueueUpload(request);

  /// Enqueues and initiates a multipart upload for large files.
  ///
  /// Automatically slices the file into compliant parts ($\ge 5\text{MB}$), uploads parts concurrently,
  /// collects ETags, and finalizes with S3.
  S3UploadTask uploadMultipart(S3MultipartUploadRequest request) =>
      _manager.enqueueMultipartUpload(request);

  /// Enqueues and initiates a single-file download from an S3-compatible source.
  ///
  /// Managed by the queue according to priority, execution mode, and concurrency limits.
  S3DownloadTask download(S3DownloadRequest request) =>
      _manager.enqueueDownload(request);

  /// Pauses scheduling of new tasks across the entire queue.
  void pauseAll() => _manager.pauseAll();

  /// Resumes scheduling of waiting tasks in the queue.
  void resumeAll() => _manager.resumeAll();

  /// Cancels all queued and executing transfers.
  void cancelAll([String? reason]) => _manager.cancelAll(reason);

  /// Disposes queue streams and manager resources.
  Future<void> dispose() => _manager.dispose();
}
