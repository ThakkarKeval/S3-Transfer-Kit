import 'dart:async';

import 's3_transfer_kit_platform_interface.dart';
import 'src/api/transfer_task.dart';
import 'src/models/transfer_progress.dart';
import 'src/models/transfer_request.dart';
import 'src/models/transfer_result.dart';
import 'src/network/http_streaming_transport.dart';
import 'src/network/transfer_transport.dart';

export 'src/api/cancellation_token.dart';
export 'src/api/transfer_task.dart';
export 'src/auth/s3_authorization.dart';
export 'src/exceptions/transfer_error_code.dart';
export 'src/exceptions/transfer_exception.dart';
export 'src/models/transfer_progress.dart';
export 'src/models/transfer_request.dart';
export 'src/models/transfer_result.dart';
export 'src/models/transfer_status.dart';

/// Primary entrypoint and facade for the S3 Transfer Kit library.
class S3TransferKit {
  /// Constructs an [S3TransferKit] instance.
  ///
  /// Optionally accepts a custom [transport] for testing or platform-specific execution.
  S3TransferKit({TransferTransport? transport})
    : _transport = transport ?? HttpStreamingTransport();

  final TransferTransport _transport;
  int _taskIdCounter = 0;

  /// Returns the platform version reported by the registered native implementation.
  Future<String?> getPlatformVersion() =>
      S3TransferKitPlatform.instance.getPlatformVersion();

  /// Initiates a single-file upload to an S3-compatible destination.
  ///
  /// Uses bounded-memory chunk streaming and reports progress through the returned [S3TransferTask].
  S3TransferTask upload(S3UploadRequest request) {
    final taskId =
        'upload_${++_taskIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final progressController = StreamController<TransferProgress>.broadcast();
    final resultCompleter = Completer<S3UploadResult>();

    final task = S3TransferTask(
      id: taskId,
      progressStream: progressController.stream,
      resultFuture: resultCompleter.future,
      cancellationToken: request.cancellationToken,
    );

    _executeUpload(
      request: request,
      task: task,
      progressController: progressController,
      resultCompleter: resultCompleter,
    );

    return task;
  }

  Future<void> _executeUpload({
    required S3UploadRequest request,
    required S3TransferTask task,
    required StreamController<TransferProgress> progressController,
    required Completer<S3UploadResult> resultCompleter,
  }) async {
    try {
      final result = await _transport.upload(
        request,
        onProgress: (progress) {
          if (!progressController.isClosed) {
            progressController.add(progress);
          }
        },
        onStatusChanged: (status) {
          task.updateStatus(status);
        },
      );
      if (!progressController.isClosed) {
        progressController.close();
      }
      resultCompleter.complete(result);
    } catch (e, st) {
      if (!progressController.isClosed) {
        progressController.close();
      }
      resultCompleter.completeError(e, st);
    }
  }
}
