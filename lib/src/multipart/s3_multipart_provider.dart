import '../models/transfer_result.dart';
import 's3_part_etag.dart';

/// Contract providing endpoints and orchestration hooks for S3 multipart uploads.
///
/// Typical implementations delegate to a backend service that interacts with AWS S3
/// (or compatible storage) using the AWS SDK, returning presigned URLs to the client.
abstract class S3MultipartProvider {
  /// Constructs an [S3MultipartProvider].
  const S3MultipartProvider();

  /// Creates a functional provider from callback functions.
  factory S3MultipartProvider.fromCallbacks({
    required Future<String> Function({
      required String filePath,
      required int fileLength,
      required String contentType,
      Map<String, String> customHeaders,
    })
    onInitiate,
    required Future<Uri> Function({
      required String uploadId,
      required int partNumber,
      required int partLength,
    })
    onGetPartUrl,
    required Future<S3UploadResult> Function({
      required String uploadId,
      required List<S3PartETag> parts,
    })
    onComplete,
    required Future<void> Function({required String uploadId}) onAbort,
  }) = _CallbackMultipartProvider;

  /// Initiates a multipart upload and returns the unique `uploadId`.
  Future<String> initiateMultipartUpload({
    required String filePath,
    required int fileLength,
    required String contentType,
    Map<String, String> customHeaders = const <String, String>{},
  });

  /// Returns the presigned HTTP PUT URL for uploading part [partNumber].
  Future<Uri> getPartUploadUrl({
    required String uploadId,
    required int partNumber,
    required int partLength,
  });

  /// Completes the multipart upload by submitting the assembled list of [parts].
  Future<S3UploadResult> completeMultipartUpload({
    required String uploadId,
    required List<S3PartETag> parts,
  });

  /// Aborts the multipart upload, deleting any uploaded parts from S3.
  Future<void> abortMultipartUpload({required String uploadId});
}

class _CallbackMultipartProvider extends S3MultipartProvider {
  const _CallbackMultipartProvider({
    required this.onInitiate,
    required this.onGetPartUrl,
    required this.onComplete,
    required this.onAbort,
  });

  final Future<String> Function({
    required String filePath,
    required int fileLength,
    required String contentType,
    Map<String, String> customHeaders,
  })
  onInitiate;

  final Future<Uri> Function({
    required String uploadId,
    required int partNumber,
    required int partLength,
  })
  onGetPartUrl;

  final Future<S3UploadResult> Function({
    required String uploadId,
    required List<S3PartETag> parts,
  })
  onComplete;

  final Future<void> Function({required String uploadId}) onAbort;

  @override
  Future<String> initiateMultipartUpload({
    required String filePath,
    required int fileLength,
    required String contentType,
    Map<String, String> customHeaders = const <String, String>{},
  }) => onInitiate(
    filePath: filePath,
    fileLength: fileLength,
    contentType: contentType,
    customHeaders: customHeaders,
  );

  @override
  Future<Uri> getPartUploadUrl({
    required String uploadId,
    required int partNumber,
    required int partLength,
  }) => onGetPartUrl(
    uploadId: uploadId,
    partNumber: partNumber,
    partLength: partLength,
  );

  @override
  Future<S3UploadResult> completeMultipartUpload({
    required String uploadId,
    required List<S3PartETag> parts,
  }) => onComplete(uploadId: uploadId, parts: parts);

  @override
  Future<void> abortMultipartUpload({required String uploadId}) =>
      onAbort(uploadId: uploadId);
}
