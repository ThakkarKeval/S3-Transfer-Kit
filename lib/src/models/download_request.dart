import '../api/cancellation_token.dart';
import '../auth/s3_authorization.dart';
import '../retry/retry_policy.dart';
import 'transfer_execution_mode.dart';
import 'transfer_priority.dart';

/// Request specification for downloading a file from an S3-compatible source.
class S3DownloadRequest {
  /// Constructs an [S3DownloadRequest].
  const S3DownloadRequest({
    required this.destinationPath,
    required this.authorization,
    this.overwrite = false,
    this.customHeaders = const <String, String>{},
    this.cancellationToken,
    this.priority = TransferPriority.normal,
    this.executionMode = TransferExecutionMode.foregroundOnly,
    this.retryPolicy,
  });

  /// Convenience constructor for downloading directly via a presigned GET URL.
  factory S3DownloadRequest.fromPresignedUrl({
    required String destinationPath,
    required Uri downloadUrl,
    bool overwrite = false,
    Map<String, String> customHeaders = const <String, String>{},
    CancellationToken? cancellationToken,
    TransferPriority priority = TransferPriority.normal,
    TransferExecutionMode executionMode = TransferExecutionMode.foregroundOnly,
    RetryPolicy? retryPolicy,
  }) {
    return S3DownloadRequest(
      destinationPath: destinationPath,
      authorization: S3Authorization.presignedUrl(downloadUrl),
      overwrite: overwrite,
      customHeaders: customHeaders,
      cancellationToken: cancellationToken,
      priority: priority,
      executionMode: executionMode,
      retryPolicy: retryPolicy,
    );
  }

  /// The local file path where the downloaded file will be saved.
  final String destinationPath;

  /// The authorization strategy (presigned URL, dynamic provider, or Cognito).
  final S3Authorization authorization;

  /// Whether to overwrite any existing file at [destinationPath]. Defaults to `false`.
  final bool overwrite;

  /// Additional custom HTTP headers to include with the download request.
  final Map<String, String> customHeaders;

  /// Optional token to cooperatively request cancellation of this download.
  final CancellationToken? cancellationToken;

  /// The scheduling priority in the transfer queue. Defaults to [TransferPriority.normal].
  final TransferPriority priority;

  /// The execution mode (foreground in-process or native background). Defaults to [TransferExecutionMode.foregroundOnly].
  final TransferExecutionMode executionMode;

  /// Optional retry policy governing automatic retries for this download.
  ///
  /// Set to [RetryPolicy.none] to fail fast without retrying. Defaults to the queue configuration policy.
  final RetryPolicy? retryPolicy;
}
