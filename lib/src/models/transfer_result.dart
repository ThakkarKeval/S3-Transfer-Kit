/// The result of a successful S3 upload transfer.
class S3UploadResult {
  /// Constructs an [S3UploadResult].
  const S3UploadResult({
    required this.bytesTransferred,
    this.eTag,
    this.responseHeaders = const <String, String>{},
  });

  /// The number of bytes successfully uploaded.
  final int bytesTransferred;

  /// The S3 ETag returned by the storage server, if provided in response headers.
  final String? eTag;

  /// Raw HTTP response headers received from the storage server.
  final Map<String, String> responseHeaders;

  @override
  String toString() =>
      'S3UploadResult(bytesTransferred: $bytesTransferred, eTag: $eTag)';
}
