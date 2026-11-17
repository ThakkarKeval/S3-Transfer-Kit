/// The result of a successful S3 download transfer.
class S3DownloadResult {
  /// Constructs an [S3DownloadResult].
  const S3DownloadResult({
    required this.destinationPath,
    required this.bytesTransferred,
    this.eTag,
    this.responseHeaders = const <String, String>{},
  });

  /// The local destination path where the file was saved.
  final String destinationPath;

  /// The total number of bytes downloaded and written to disk.
  final int bytesTransferred;

  /// The S3 ETag returned in the response headers, if available.
  final String? eTag;

  /// Raw HTTP response headers received from the storage server.
  final Map<String, String> responseHeaders;

  @override
  String toString() =>
      'S3DownloadResult(destinationPath: $destinationPath, bytesTransferred: $bytesTransferred, eTag: $eTag)';
}
