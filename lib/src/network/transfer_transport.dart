import '../models/transfer_progress.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';

/// Contract decoupling network transfer execution from transfer orchestration.
abstract class TransferTransport {
  /// Executes a single-file upload.
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  });
}
