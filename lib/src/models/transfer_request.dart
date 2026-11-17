import '../api/cancellation_token.dart';
import '../auth/s3_authorization.dart';

/// Request specification for uploading a file to an S3-compatible destination.
class S3UploadRequest {
  /// Constructs an [S3UploadRequest].
  const S3UploadRequest({
    required this.filePath,
    required this.authorization,
    this.contentType = 'application/octet-stream',
    this.customHeaders = const <String, String>{},
    this.cancellationToken,
  });

  /// Convenience constructor for uploading directly via a presigned URL.
  factory S3UploadRequest.fromPresignedUrl({
    required String filePath,
    required Uri uploadUrl,
    String contentType = 'application/octet-stream',
    Map<String, String> customHeaders = const <String, String>{},
    CancellationToken? cancellationToken,
  }) {
    return S3UploadRequest(
      filePath: filePath,
      authorization: S3Authorization.presignedUrl(uploadUrl),
      contentType: contentType,
      customHeaders: customHeaders,
      cancellationToken: cancellationToken,
    );
  }

  /// The absolute path to the local file to upload.
  final String filePath;

  /// The authorization strategy (presigned URL, dynamic provider, or Cognito).
  final S3Authorization authorization;

  /// The MIME content type for the file (e.g. `image/jpeg`, `application/pdf`).
  final String contentType;

  /// Additional custom HTTP headers to include with the upload request.
  final Map<String, String> customHeaders;

  /// Optional token to cooperatively request cancellation of this upload.
  final CancellationToken? cancellationToken;
}
