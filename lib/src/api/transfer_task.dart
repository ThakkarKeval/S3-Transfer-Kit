import 'dart:async';

import '../models/download_result.dart';
import '../models/transfer_execution_mode.dart';
import '../models/transfer_priority.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import 'cancellation_token.dart';

/// An active or queued transfer task handle exposing progress, lifecycle controls, and status streams.
class S3TransferTask<T> {
  /// Internal constructor for [S3TransferTask].
  S3TransferTask({
    required this.id,
    required Stream<TransferProgress> progressStream,
    required Future<T> resultFuture,
    this.cancellationToken,
    this.priority = TransferPriority.normal,
    this.executionMode = TransferExecutionMode.foregroundOnly,
    this._statusStream,
    this.onPause,
    this.onResume,
  }) : _progress = progressStream,
       _result = resultFuture;

  /// Unique identifier for this transfer task.
  final String id;

  /// The scheduling priority of this task.
  final TransferPriority priority;

  /// The execution mode (foreground in-process or native background).
  final TransferExecutionMode executionMode;

  /// Optional cancellation token associated with this task.
  final CancellationToken? cancellationToken;

  /// Optional callback invoked when pausing this task.
  final void Function()? onPause;

  /// Optional callback invoked when resuming this task.
  final void Function()? onResume;

  final Stream<TransferProgress> _progress;
  final Future<T> _result;
  final Stream<TransferStatus>? _statusStream;

  TransferStatus _status = TransferStatus.enqueued;

  /// Stream of transfer progress updates.
  Stream<TransferProgress> get progress => _progress;

  /// Stream of transfer lifecycle status updates.
  Stream<TransferStatus> get statusStream =>
      _statusStream ?? const Stream.empty();

  /// Future completing with the transfer result on success, or throwing a [TransferException] on failure.
  Future<T> get result => _result;

  /// The current lifecycle status of this transfer.
  TransferStatus get status => _status;

  /// Updates the internal status of this task.
  void updateStatus(TransferStatus newStatus) {
    _status = newStatus;
  }

  /// Cancels this transfer task.
  void cancel([String? reason]) {
    cancellationToken?.cancel(reason);
  }

  /// Requests pausing this transfer task if supported.
  void pause() {
    onPause?.call();
  }

  /// Requests resuming this transfer task if paused.
  void resume() {
    onResume?.call();
  }
}

/// Convenience type alias for an upload transfer task.
typedef S3UploadTask = S3TransferTask<S3UploadResult>;

/// Convenience type alias for a download transfer task.
typedef S3DownloadTask = S3TransferTask<S3DownloadResult>;
