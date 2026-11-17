/// The category of a transfer operation.
enum TransferType {
  /// A single-part upload.
  singleUpload,

  /// A chunked multipart upload.
  multipartUpload,

  /// A file download.
  download,
}
