import 'dart:async';

import '../api/cancellation_token.dart';
import '../exceptions/transfer_exception.dart';
import '../models/download_request.dart';
import '../models/download_result.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import '../network/transfer_transport.dart';
import 'retry_classifier.dart';
import 'retry_policy.dart';

/// A [TransferTransport] decorator that transparently retries transient transfer failures.
class RetryingTransport implements TransferTransport {
  /// Constructs a [RetryingTransport] wrapping [underlying].
  RetryingTransport(
    this.underlying, {
    this.defaultRetryPolicy = RetryPolicy.standard,
  });

  /// The underlying transport executing raw network transfers.
  final TransferTransport underlying;

  /// Default retry policy applied when requests do not specify one.
  final RetryPolicy defaultRetryPolicy;

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    final policy = request.retryPolicy ?? defaultRetryPolicy;
    if (!policy.allowRetry || policy.maxAttempts <= 1) {
      return underlying.upload(
        request,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
      );
    }

    final token = request.cancellationToken;
    for (int attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason);
      }

      try {
        return await underlying.upload(
          request,
          onProgress: onProgress,
          onStatusChanged: onStatusChanged,
        );
      } catch (error) {
        if (token != null && token.isCancelled) {
          rethrow;
        }

        final isRetryable = RetryClassifier.isRetryable(error);
        if (!isRetryable || attempt >= policy.maxAttempts) {
          rethrow;
        }

        final delay = policy.calculateDelay(attempt);
        await _sleepWithCancellation(delay, token);
      }
    }

    throw StateError('Unreachable retry loop exit');
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    final policy = request.retryPolicy ?? defaultRetryPolicy;
    if (!policy.allowRetry || policy.maxAttempts <= 1) {
      return underlying.download(
        request,
        onProgress: onProgress,
        onStatusChanged: onStatusChanged,
      );
    }

    final token = request.cancellationToken;
    for (int attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason);
      }

      try {
        return await underlying.download(
          request,
          onProgress: onProgress,
          onStatusChanged: onStatusChanged,
        );
      } catch (error) {
        if (token != null && token.isCancelled) {
          rethrow;
        }

        final isRetryable = RetryClassifier.isRetryable(error);
        if (!isRetryable || attempt >= policy.maxAttempts) {
          rethrow;
        }

        final delay = policy.calculateDelay(attempt);
        await _sleepWithCancellation(delay, token);
      }
    }

    throw StateError('Unreachable retry loop exit');
  }

  Future<void> _sleepWithCancellation(
    Duration delay,
    CancellationToken? token,
  ) async {
    if (delay <= Duration.zero) return;
    if (token != null && token.isCancelled) {
      throw TransferException.cancelled(reason: token.reason);
    }

    final completer = Completer<void>();
    final timer = Timer(delay, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    token?.onCancelled(() {
      timer.cancel();
      if (!completer.isCompleted) {
        completer.completeError(
          TransferException.cancelled(reason: token.reason),
        );
      }
    });

    await completer.future;
  }
}
