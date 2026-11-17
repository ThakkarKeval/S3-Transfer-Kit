import 'dart:async';

import '../models/transfer_progress.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import 'cancellation_token.dart';

/// An active or completed transfer task handle exposing progress and lifecycle controls.
class S3TransferTask {
  /// Internal constructor for [S3TransferTask].
  S3TransferTask({
    required this.id,
    required Stream<TransferProgress> progressStream,
    required Future<S3UploadResult> resultFuture,
    this.cancellationToken,
  }) : _progress = progressStream,
       _result = resultFuture;

  /// Unique identifier for this transfer task.
  final String id;

  /// Optional cancellation token associated with this task.
  final CancellationToken? cancellationToken;

  final Stream<TransferProgress> _progress;
  final Future<S3UploadResult> _result;

  TransferStatus _status = TransferStatus.enqueued;

  /// Stream of transfer progress updates.
  Stream<TransferProgress> get progress => _progress;

  /// Future completing with the [S3UploadResult] on success, or throwing a [TransferException] on failure.
  Future<S3UploadResult> get result => _result;

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
}
