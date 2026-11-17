import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';
import '../models/transfer_progress.dart';
import '../models/transfer_request.dart';
import '../models/transfer_result.dart';
import '../models/transfer_status.dart';
import '../utils/file_validator.dart';
import '../utils/url_sanitizer.dart';
import 'transfer_transport.dart';

/// Transport implementation that uploads files via bounded chunk streaming over HTTP.
class HttpStreamingTransport implements TransferTransport {
  /// Constructs an [HttpStreamingTransport].
  HttpStreamingTransport({this.httpClient});

  /// Custom [HttpClient] instance, or null to create a default client per transfer.
  final HttpClient? httpClient;

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
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

    final authorizedRequest = await request.authorization.authorize(
      method: 'PUT',
      contentType: request.contentType,
      contentLength: fileLength,
      customHeaders: request.customHeaders,
    );

    if (token != null && token.isCancelled) {
      onStatusChanged(TransferStatus.cancelled);
      throw TransferException.cancelled(reason: token.reason);
    }

    onStatusChanged(TransferStatus.inProgress);

    final client = httpClient ?? HttpClient();
    HttpClientRequest? clientRequest;

    void cancelCallback() {
      try {
        clientRequest?.abort();
      } catch (_) {}
    }

    token?.onCancelled(cancelCallback);

    try {
      clientRequest = await client.openUrl('PUT', authorizedRequest.url);
      clientRequest.contentLength = fileLength;
      clientRequest.headers.set(
        HttpHeaders.contentTypeHeader,
        request.contentType,
      );

      for (final entry in authorizedRequest.headers.entries) {
        clientRequest.headers.set(entry.key, entry.value);
      }

      int bytesTransferred = 0;
      final fileStream = file.openRead();

      await for (final chunk in fileStream) {
        if (token != null && token.isCancelled) {
          clientRequest.abort();
          onStatusChanged(TransferStatus.cancelled);
          throw TransferException.cancelled(reason: token.reason);
        }

        clientRequest.add(chunk);
        bytesTransferred += chunk.length;

        onProgress(
          TransferProgress(
            bytesTransferred: bytesTransferred,
            totalBytes: fileLength,
          ),
        );
      }

      final response = await clientRequest.close();
      final statusCode = response.statusCode;

      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });

      if (statusCode >= 200 && statusCode < 300) {
        // Drain response body to free socket
        await response.drain<void>();

        final rawEtag = responseHeaders['etag'];
        final eTag = rawEtag?.replaceAll('"', '');

        onStatusChanged(TransferStatus.completed);
        return S3UploadResult(
          bytesTransferred: bytesTransferred,
          eTag: eTag,
          responseHeaders: responseHeaders,
        );
      } else {
        final errorBody = await utf8.decoder.bind(response).join();
        final sanitizedUrl = UrlSanitizer.sanitizeUri(authorizedRequest.url);

        final isAuthFailure =
            statusCode == 401 ||
            statusCode == 403 ||
            errorBody.contains('ExpiredToken') ||
            errorBody.contains('RequestTimeTooSkewed') ||
            errorBody.contains('SignatureDoesNotMatch');

        final errorCode = isAuthFailure
            ? TransferErrorCode.authenticationExpired
            : TransferErrorCode.httpFailure;

        final isRetryable = statusCode >= 500 || statusCode == 429;

        final exception = TransferException(
          code: errorCode,
          message:
              'Upload to $sanitizedUrl failed with HTTP $statusCode: $errorBody',
          httpStatusCode: statusCode,
          isRetryable: isRetryable,
        );

        onStatusChanged(TransferStatus.failed);
        throw exception;
      }
    } on SocketException catch (e, st) {
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      onStatusChanged(TransferStatus.failed);
      throw TransferException(
        code: TransferErrorCode.networkUnavailable,
        message: 'Network socket failure: ${e.message}',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    } on TimeoutException catch (e, st) {
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      onStatusChanged(TransferStatus.failed);
      throw TransferException(
        code: TransferErrorCode.networkTimeout,
        message: 'Network connection or write timed out.',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    } on HttpException catch (e, st) {
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      onStatusChanged(TransferStatus.failed);
      throw TransferException(
        code: TransferErrorCode.httpFailure,
        message: 'HTTP transport error: ${e.message}',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    } on TransferException {
      rethrow;
    } catch (e, st) {
      if (token != null && token.isCancelled) {
        onStatusChanged(TransferStatus.cancelled);
        throw TransferException.cancelled(reason: token.reason, cause: e);
      }
      onStatusChanged(TransferStatus.failed);
      throw TransferException(
        code: TransferErrorCode.unexpectedFailure,
        message: 'Unexpected upload failure: $e',
        cause: e,
        stackTrace: st,
      );
    } finally {
      if (httpClient == null) {
        client.close(force: true);
      }
    }
  }
}
