import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import '../retry/retry_classifier.dart';
import '../retry/retry_policy.dart';
import '../utils/file_validator.dart';
import '../utils/url_sanitizer.dart';
import 'multipart_upload_request.dart';
import 's3_part.dart';
import 's3_part_etag.dart';

/// Coordinates slicing, parallel chunk uploading, progress tracking, and finalization for multipart uploads.
class MultipartUploadCoordinator {
  /// Constructs a [MultipartUploadCoordinator].
  MultipartUploadCoordinator({this.httpClient});

  /// Custom [HttpClient] or null to create one per transfer.
  final HttpClient? httpClient;

  /// Executes the multipart upload for the given [request].
  Future<S3UploadResult> upload(
    S3MultipartUploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    final token = request.cancellationToken;
    if (token != null && token.isCancelled) {
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    final file = File(request.filePath);
    final fileLength = await FileValidator.validateUploadFile(file);

    onProgress(TransferProgress.initial(totalBytes: fileLength));

    // Calculate part slices
    final parts = _calculateParts(fileLength, request.partSize);

    if (token != null && token.isCancelled) {
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    onStatusChanged(TransferStatus.inProgress);

    // Initiate multipart upload
    String? uploadId;
    try {
      uploadId = await request.provider.initiateMultipartUpload(
        filePath: request.filePath,
        fileLength: fileLength,
        contentType: request.contentType,
        customHeaders: request.customHeaders,
      );
    } catch (e, st) {
      onStatusChanged(TransferStatus.failed);
      if (e is TransferException) rethrow;
      throw TransferException(
        code: TransferErrorCode.unexpectedFailure,
        message: 'Failed to initiate multipart upload: $e',
        cause: e,
        stackTrace: st,
      );
    }

    if (token != null && token.isCancelled) {
      await _safeAbort(request, uploadId);
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    final client = httpClient ?? HttpClient();
    final partETags = <S3PartETag>[];
    final partProgress = <int, int>{};
    final activeRequests = <HttpClientRequest>[];

    void cancelCallback() {
      for (final req in activeRequests) {
        try {
          req.abort();
        } catch (_) {}
      }
    }

    token?.onCancelled(cancelCallback);

    int nextPartIndex = 0;
    final workerCount = min(request.maxConcurrentParts, parts.length);

    try {
      Future<void> runWorker() async {
        while (true) {
          if (token != null && token.isCancelled) {
            throw TransferException.cancelled(reason: token.reason);
          }

          int currentIndex;
          if (nextPartIndex >= parts.length) {
            break;
          }
          currentIndex = nextPartIndex++;
          final part = parts[currentIndex];

          final partETag = await _uploadSinglePartWithRetry(
            request: request,
            uploadId: uploadId!,
            part: part,
            file: file,
            client: client,
            activeRequests: activeRequests,
            onBytesTransferred: (partBytes) {
              partProgress[part.partNumber] = partBytes;
              final totalBytes = partProgress.values.fold(0, (a, b) => a + b);
              onProgress(
                TransferProgress(
                  bytesTransferred: totalBytes,
                  totalBytes: fileLength,
                ),
              );
            },
          );

          partETags.add(partETag);
        }
      }

      await Future.wait(List.generate(workerCount, (_) => runWorker()));

      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason);
      }

      // Sort parts by partNumber as required by S3 specification
      partETags.sort();

      // Complete multipart upload
      final result = await request.provider.completeMultipartUpload(
        uploadId: uploadId,
        parts: partETags,
      );

      onStatusChanged(TransferStatus.completed);
      return result;
    } catch (e, st) {
      await _safeAbort(request, uploadId);

      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }

      onStatusChanged(TransferStatus.failed);
      if (e is TransferException) rethrow;

      throw TransferException(
        code: TransferErrorCode.unexpectedFailure,
        message: 'Multipart upload failed: $e',
        cause: e,
        stackTrace: st,
      );
    } finally {
      if (httpClient == null) {
        client.close(force: true);
      }
    }
  }

  List<S3Part> _calculateParts(int fileLength, int partSize) {
    if (fileLength <= partSize) {
      return [
        S3Part(
          partNumber: 1,
          startByte: 0,
          endByte: fileLength,
          length: fileLength,
        ),
      ];
    }

    final parts = <S3Part>[];
    int offset = 0;
    int partNumber = 1;

    while (offset < fileLength) {
      final end = min(offset + partSize, fileLength);
      parts.add(
        S3Part(
          partNumber: partNumber++,
          startByte: offset,
          endByte: end,
          length: end - offset,
        ),
      );
      offset = end;
    }

    return parts;
  }

  Future<S3PartETag> _uploadSinglePartWithRetry({
    required S3MultipartUploadRequest request,
    required String uploadId,
    required S3Part part,
    required File file,
    required HttpClient client,
    required List<HttpClientRequest> activeRequests,
    required void Function(int) onBytesTransferred,
  }) async {
    final policy = request.retryPolicy ?? RetryPolicy.standard;
    final maxAttempts = policy.allowRetry ? policy.maxAttempts : 1;
    final token = request.cancellationToken;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason);
      }

      try {
        return await _uploadSinglePart(
          request: request,
          uploadId: uploadId,
          part: part,
          file: file,
          client: client,
          activeRequests: activeRequests,
          onBytesTransferred: onBytesTransferred,
        );
      } catch (error) {
        if (token != null && token.isCancelled) {
          rethrow;
        }

        final isRetryable = RetryClassifier.isRetryable(error);
        if (!isRetryable || attempt >= maxAttempts) {
          rethrow;
        }

        final delay = policy.calculateDelay(attempt);
        if (delay > Duration.zero) {
          await Future<void>.delayed(delay);
        }
      }
    }

    throw StateError('Unreachable part retry loop exit');
  }

  Future<S3PartETag> _uploadSinglePart({
    required S3MultipartUploadRequest request,
    required String uploadId,
    required S3Part part,
    required File file,
    required HttpClient client,
    required List<HttpClientRequest> activeRequests,
    required void Function(int) onBytesTransferred,
  }) async {
    final token = request.cancellationToken;
    final partUrl = await request.provider.getPartUploadUrl(
      uploadId: uploadId,
      partNumber: part.partNumber,
      partLength: part.length,
    );

    if (token != null && token.isCancelled) {
      throw TransferException.cancelled(reason: token.reason);
    }

    HttpClientRequest? clientRequest;
    try {
      clientRequest = await client.openUrl('PUT', partUrl);
      activeRequests.add(clientRequest);

      clientRequest.contentLength = part.length;
      clientRequest.headers.set(
        HttpHeaders.contentTypeHeader,
        request.contentType,
      );

      int partTransferred = 0;
      final partStream = file.openRead(part.startByte, part.endByte);

      await for (final chunk in partStream) {
        if (token != null && token.isCancelled) {
          clientRequest.abort();
          throw TransferException.cancelled(reason: token.reason);
        }

        clientRequest.add(chunk);
        partTransferred += chunk.length;
        onBytesTransferred(partTransferred);
      }

      final response = await clientRequest.close();
      final statusCode = response.statusCode;

      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });

      if (statusCode >= 200 && statusCode < 300) {
        await response.drain<void>();

        final rawEtag = responseHeaders['etag'];
        if (rawEtag == null || rawEtag.isEmpty) {
          throw TransferException(
            code: TransferErrorCode.httpFailure,
            message:
                'S3 Part ${part.partNumber} upload succeeded but returned no ETag header.',
            httpStatusCode: statusCode,
            isRetryable: true,
          );
        }

        final cleanETag = rawEtag.replaceAll('"', '');
        return S3PartETag(partNumber: part.partNumber, eTag: cleanETag);
      } else {
        final errorBody = await utf8.decoder.bind(response).join();
        final sanitizedUrl = UrlSanitizer.sanitizeUri(partUrl);

        final isAuthFailure =
            statusCode == 401 ||
            statusCode == 403 ||
            errorBody.contains('ExpiredToken') ||
            errorBody.contains('SignatureDoesNotMatch');

        final errorCode = isAuthFailure
            ? TransferErrorCode.authenticationExpired
            : TransferErrorCode.httpFailure;

        final isRetryable = statusCode >= 500 || statusCode == 429;

        throw TransferException(
          code: errorCode,
          message:
              'Part ${part.partNumber} upload to $sanitizedUrl failed with HTTP $statusCode: $errorBody',
          httpStatusCode: statusCode,
          isRetryable: isRetryable,
        );
      }
    } on SocketException catch (e, st) {
      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      throw TransferException(
        code: TransferErrorCode.networkUnavailable,
        message: 'Socket error uploading part ${part.partNumber}: ${e.message}',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    } on TimeoutException catch (e, st) {
      if (token != null && token.isCancelled) {
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      throw TransferException(
        code: TransferErrorCode.networkTimeout,
        message: 'Timeout uploading part ${part.partNumber}',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    } finally {
      if (clientRequest != null) {
        activeRequests.remove(clientRequest);
      }
    }
  }

  Future<void> _safeAbort(
    S3MultipartUploadRequest request,
    String? uploadId,
  ) async {
    if (uploadId == null) return;
    try {
      await request.provider.abortMultipartUpload(uploadId: uploadId);
    } catch (_) {
      // Best-effort abort; ignore errors during abort cleanup
    }
  }
}
