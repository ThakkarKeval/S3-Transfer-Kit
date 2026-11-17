import 'transfer_error_code.dart';

/// Base exception thrown when an S3 transfer operation fails.
class TransferException implements Exception {
  /// Constructs a [TransferException].
  const TransferException({
    required this.code,
    required this.message,
    this.httpStatusCode,
    this.isRetryable = false,
    this.cause,
    this.stackTrace,
  });

  /// Factory constructor for a cancelled transfer.
  factory TransferException.cancelled({String? reason, Object? cause}) {
    return TransferException(
      code: TransferErrorCode.cancelled,
      message: reason ?? 'Transfer was cancelled.',
      cause: cause,
      isRetryable: false,
    );
  }

  /// The stable error category for programmatic handling.
  final TransferErrorCode code;

  /// A sanitized, human-readable description of the error.
  final String message;

  /// The HTTP status code returned by the server, if available.
  final int? httpStatusCode;

  /// Whether the operation can safely be retried.
  final bool isRetryable;

  /// The underlying exception or error, if available.
  final Object? cause;

  /// The stack trace where the error occurred.
  final StackTrace? stackTrace;

  /// Whether this exception represents an intentional cancellation.
  bool get isCancelled => code == TransferErrorCode.cancelled;

  /// Whether this exception represents an authentication or credential expiry failure.
  bool get isAuthError =>
      code == TransferErrorCode.authenticationExpired ||
      httpStatusCode == 401 ||
      httpStatusCode == 403;

  @override
  String toString() {
    final statusPart = httpStatusCode != null ? ' (HTTP $httpStatusCode)' : '';
    return 'TransferException[$code]$statusPart: $message';
  }
}
