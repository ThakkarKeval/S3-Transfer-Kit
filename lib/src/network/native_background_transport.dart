import 'dart:async';
import 'dart:io';

import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';
import '../messages.g.dart';
import '../models/download_request.dart';
import '../models/download_result.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import '../utils/file_validator.dart';
import 'http_streaming_transport.dart';
import 'transfer_transport.dart';

class _ActiveTransferEntry {
  _ActiveTransferEntry({
    required this.onProgress,
    required this.onStatusChanged,
    required this.completer,
    required this.isUpload,
    this.destinationPath,
    this.totalBytes = 0,
  });

  final void Function(TransferProgress) onProgress;
  final void Function(TransferStatus) onStatusChanged;
  final Completer<dynamic> completer;
  final bool isUpload;
  final String? destinationPath;
  int totalBytes;
  int lastTransferredBytes = 0;
}

/// Transport implementation delegating transfers to the platform native background execution services.
class NativeBackgroundTransport
    implements TransferTransport, S3TransferKitFlutterApi {
  /// Constructs a [NativeBackgroundTransport].
  NativeBackgroundTransport({
    S3TransferKitHostApi? hostApi,
    TransferTransport? fallbackTransport,
  }) : _hostApi = hostApi ?? S3TransferKitHostApi(),
       _fallbackTransport = fallbackTransport ?? HttpStreamingTransport() {
    try {
      S3TransferKitFlutterApi.setUp(this);
    } catch (_) {}
  }

  final S3TransferKitHostApi _hostApi;
  final TransferTransport? _fallbackTransport;
  final Map<String, _ActiveTransferEntry> _activeTransfers = {};

  bool? _isSupportedCache;

  /// Checks whether background transfers are supported natively on the current device.
  Future<bool> isSupported() async {
    if (_isSupportedCache != null) return _isSupportedCache!;
    try {
      _isSupportedCache = await _hostApi.isBackgroundTransferSupported();
    } catch (_) {
      _isSupportedCache = false;
    }
    return _isSupportedCache!;
  }

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    final supported = await isSupported();
    if (!supported) {
      final fallback = _fallbackTransport;
      if (fallback != null) {
        return fallback.upload(
          request,
          onProgress: onProgress,
          onStatusChanged: onStatusChanged,
        );
      }
      throw const TransferException(
        code: TransferErrorCode.invalidConfiguration,
        message:
            'Native background transfers are not supported on this platform.',
      );
    }

    final token = request.cancellationToken;
    if (token != null && token.isCancelled) {
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    final file = File(request.filePath);
    final fileLength = await FileValidator.validateUploadFile(file);

    final auth = await request.authorization.authorize(
      method: 'PUT',
      contentType: request.contentType,
      contentLength: fileLength,
      customHeaders: request.customHeaders,
    );

    final taskId = 'bg_up_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<S3UploadResult>();

    final entry = _ActiveTransferEntry(
      onProgress: onProgress,
      onStatusChanged: onStatusChanged,
      completer: completer,
      isUpload: true,
      totalBytes: fileLength,
    );
    _activeTransfers[taskId] = entry;

    token?.onCancelled(() {
      try {
        _hostApi.cancelBackgroundTransfer(taskId);
      } catch (_) {}
    });

    onProgress(TransferProgress.initial(totalBytes: fileLength));
    onStatusChanged(TransferStatus.inProgress);

    try {
      await _hostApi.startBackgroundUpload(
        NativeUploadRequest(
          taskId: taskId,
          url: auth.url.toString(),
          filePath: request.filePath,
          method: 'PUT',
          headers: auth.headers,
        ),
      );
      return await completer.future;
    } catch (e) {
      _activeTransfers.remove(taskId);
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      rethrow;
    }
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    final supported = await isSupported();
    if (!supported) {
      final fallback = _fallbackTransport;
      if (fallback != null) {
        return fallback.download(
          request,
          onProgress: onProgress,
          onStatusChanged: onStatusChanged,
        );
      }
      throw const TransferException(
        code: TransferErrorCode.invalidConfiguration,
        message:
            'Native background transfers are not supported on this platform.',
      );
    }

    final token = request.cancellationToken;
    if (token != null && token.isCancelled) {
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    final destFile = File(request.destinationPath);
    if (!request.overwrite && await destFile.exists()) {
      onStatusChanged(TransferStatus.failed);
      throw TransferException(
        code: TransferErrorCode.fileAccessDenied,
        message:
            'Destination file already exists and overwrite is set to false: ${request.destinationPath}',
      );
    }

    final auth = await request.authorization.authorize(
      method: 'GET',
      contentType: '',
      contentLength: 0,
      customHeaders: request.customHeaders,
    );

    final taskId = 'bg_down_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<S3DownloadResult>();

    final entry = _ActiveTransferEntry(
      onProgress: onProgress,
      onStatusChanged: onStatusChanged,
      completer: completer,
      isUpload: false,
      destinationPath: request.destinationPath,
    );
    _activeTransfers[taskId] = entry;

    token?.onCancelled(() {
      try {
        _hostApi.cancelBackgroundTransfer(taskId);
      } catch (_) {}
    });

    onStatusChanged(TransferStatus.inProgress);

    try {
      await _hostApi.startBackgroundDownload(
        NativeDownloadRequest(
          taskId: taskId,
          url: auth.url.toString(),
          destinationPath: request.destinationPath,
          headers: auth.headers,
        ),
      );
      return await completer.future;
    } catch (e) {
      _activeTransfers.remove(taskId);
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      rethrow;
    }
  }

  @override
  void onTransferProgress(NativeTransferProgressUpdate update) {
    final entry = _activeTransfers[update.taskId];
    if (entry != null) {
      entry.lastTransferredBytes = update.bytesTransferred;
      if (update.totalBytes > 0) {
        entry.totalBytes = update.totalBytes;
      }
      entry.onProgress(
        TransferProgress(
          bytesTransferred: update.bytesTransferred,
          totalBytes: entry.totalBytes,
        ),
      );
    }
  }

  @override
  void onTransferStateChanged(NativeTransferStateUpdate update) {
    final entry = _activeTransfers[update.taskId];
    if (entry != null) {
      switch (update.status) {
        case 'inProgress':
          entry.onStatusChanged(TransferStatus.inProgress);
          break;

        case 'completed':
          entry.onStatusChanged(TransferStatus.completed);
          if (entry.isUpload) {
            entry.completer.complete(
              S3UploadResult(
                bytesTransferred: entry.totalBytes > 0
                    ? entry.totalBytes
                    : entry.lastTransferredBytes,
                eTag: update.eTag,
              ),
            );
          } else {
            entry.completer.complete(
              S3DownloadResult(
                destinationPath: entry.destinationPath ?? '',
                bytesTransferred: entry.totalBytes > 0
                    ? entry.totalBytes
                    : entry.lastTransferredBytes,
                eTag: update.eTag,
              ),
            );
          }
          _activeTransfers.remove(update.taskId);
          break;

        case 'cancelled':
          entry.onStatusChanged(TransferStatus.cancelled);
          if (!entry.completer.isCompleted) {
            entry.completer.completeError(
              TransferException.cancelled(reason: update.error),
            );
          }
          _activeTransfers.remove(update.taskId);
          break;

        case 'failed':
          entry.onStatusChanged(TransferStatus.failed);
          if (!entry.completer.isCompleted) {
            final statusCode = update.httpStatusCode?.toInt();
            final isAuth = statusCode == 401 || statusCode == 403;
            entry.completer.completeError(
              TransferException(
                code: statusCode != null && statusCode >= 400
                    ? (isAuth
                          ? TransferErrorCode.authenticationExpired
                          : TransferErrorCode.httpFailure)
                    : TransferErrorCode.unexpectedFailure,
                message: update.error ?? 'Native background transfer failed.',
                httpStatusCode: statusCode,
              ),
            );
          }
          _activeTransfers.remove(update.taskId);
          break;
      }
    }
  }
}
