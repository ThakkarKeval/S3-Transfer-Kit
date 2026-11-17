import 'dart:async';
import 'dart:io';

import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';

/// Evaluates whether an error encountered during transfer execution is transient and retryable.
class RetryClassifier {
  const RetryClassifier._();

  /// Determines whether [error] is transient and eligible for automatic retry.
  static bool isRetryable(Object error) {
    if (error is TransferException) {
      switch (error.code) {
        case TransferErrorCode.cancelled:
        case TransferErrorCode.fileNotFound:
        case TransferErrorCode.fileAccessDenied:
        case TransferErrorCode.invalidConfiguration:
        case TransferErrorCode.authenticationExpired:
          return false;

        case TransferErrorCode.networkUnavailable:
        case TransferErrorCode.networkTimeout:
          return true;

        case TransferErrorCode.httpFailure:
          final statusCode = error.httpStatusCode;
          if (statusCode != null) {
            // 429 (Rate limited) or 5xx (Server error) are retryable
            return statusCode == 429 || statusCode >= 500;
          }
          return error.isRetryable;

        case TransferErrorCode.unexpectedFailure:
          return error.isRetryable;
      }
    }

    if (error is SocketException || error is TimeoutException) {
      return true;
    }

    return false;
  }
}
