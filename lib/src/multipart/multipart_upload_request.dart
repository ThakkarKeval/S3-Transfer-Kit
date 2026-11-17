import '../api/cancellation_token.dart';
import '../models/transfer_execution_mode.dart';
import '../models/transfer_priority.dart';
import '../retry/retry_policy.dart';
import 's3_multipart_provider.dart';

/// Request specification for uploading large files to S3 using the Multipart Upload API.
class S3MultipartUploadRequest {
  /// Constructs an [S3MultipartUploadRequest].
  const S3MultipartUploadRequest({
    required this.filePath,
    required this.provider,
    this.partSize = defaultPartSize,
    this.maxConcurrentParts = 4,
    this.contentType = 'application/octet-stream',
    this.customHeaders = const <String, String>{},
    this.cancellationToken,
    this.priority = TransferPriority.normal,
    this.executionMode = TransferExecutionMode.foregroundOnly,
    this.retryPolicy,
  }) : assert(
         partSize >= minPartSize,
         'partSize must be at least 5 MB (5,242,880 bytes) per S3 specification',
       ),
       assert(
         maxConcurrentParts > 0,
         'maxConcurrentParts must be greater than 0',
       );

  /// Minimum part size mandated by AWS S3 (5 MB).
  static const int minPartSize = 5 * 1024 * 1024;

  /// Default part size for multipart transfers (5 MB).
  static const int defaultPartSize = 5 * 1024 * 1024;

  /// Absolute local path of the file to upload.
  final String filePath;

  /// Provider orchestrating multipart initiation, part URL generation, and completion.
  final S3MultipartProvider provider;

  /// Byte size of each individual part slice. Must be >= 5 MB.
  final int partSize;

  /// Number of parts uploaded in parallel. Defaults to 4.
  final int maxConcurrentParts;

  /// MIME content type of the target file.
  final String contentType;

  /// Custom HTTP headers to pass during initiation.
  final Map<String, String> customHeaders;

  /// Optional token to cooperatively request cancellation of this transfer.
  final CancellationToken? cancellationToken;

  /// The scheduling priority in the transfer queue. Defaults to [TransferPriority.normal].
  final TransferPriority priority;

  /// The execution mode (foreground in-process or native background). Defaults to [TransferExecutionMode.foregroundOnly].
  final TransferExecutionMode executionMode;

  /// Optional retry policy governing automatic retries for individual parts.
  final RetryPolicy? retryPolicy;
}
