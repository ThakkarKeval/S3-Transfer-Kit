/// Categorized error codes for S3 transfer operations.
enum TransferErrorCode {
  /// The request or configuration was invalid (e.g. invalid URL, missing parameters).
  invalidConfiguration,

  /// The target local file does not exist.
  fileNotFound,

  /// The local file or destination cannot be accessed due to permissions or file lock.
  fileAccessDenied,

  /// Network is not reachable or connection was reset.
  networkUnavailable,

  /// Connection or read/write timeout occurred.
  networkTimeout,

  /// S3 or the HTTP endpoint returned an error status code (e.g. 4xx, 5xx).
  httpFailure,

  /// Presigned URL or credentials have expired (e.g. S3 RequestTimeTooSkewed or ExpiredToken).
  authenticationExpired,

  /// The transfer was explicitly cancelled by the caller.
  cancelled,

  /// An unclassified or unexpected error occurred.
  unexpectedFailure,
}
