import 'dart:io';

import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';

/// Helper to validate local files prior to starting network transfers.
class FileValidator {
  FileValidator._();

  /// Validates that [file] exists, is a regular file, and can be read.
  ///
  /// Returns the file size in bytes on success.
  /// Throws [TransferException] if validation fails.
  static Future<int> validateUploadFile(File file) async {
    final path = file.path;
    final type = await FileSystemEntity.type(path);

    if (type == FileSystemEntityType.notFound) {
      throw TransferException(
        code: TransferErrorCode.fileNotFound,
        message: 'File does not exist: $path',
      );
    }

    if (type == FileSystemEntityType.directory) {
      throw TransferException(
        code: TransferErrorCode.invalidConfiguration,
        message: 'Specified path is a directory, not a regular file: $path',
      );
    }

    try {
      final length = await file.length();
      return length;
    } on FileSystemException catch (e, st) {
      throw TransferException(
        code: TransferErrorCode.fileAccessDenied,
        message: 'Unable to access file: ${e.message}',
        cause: e,
        stackTrace: st,
      );
    }
  }
}
