import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

class _MockFlakyTransport implements TransferTransport {
  int uploadCallCount = 0;
  int downloadCallCount = 0;

  final List<Object Function()> uploadBehaviors = [];
  final List<Object Function()> downloadBehaviors = [];

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    uploadCallCount++;
    if (uploadBehaviors.isNotEmpty) {
      final behavior = uploadBehaviors.removeAt(0);
      final result = behavior();
      if (result is Exception) {
        throw result;
      } else if (result is Error) {
        throw result;
      } else if (result is S3UploadResult) {
        return result;
      }
    }
    return const S3UploadResult(bytesTransferred: 100);
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    downloadCallCount++;
    if (downloadBehaviors.isNotEmpty) {
      final behavior = downloadBehaviors.removeAt(0);
      final result = behavior();
      if (result is Exception) {
        throw result;
      } else if (result is Error) {
        throw result;
      } else if (result is S3DownloadResult) {
        return result;
      }
    }
    return const S3DownloadResult(
      destinationPath: 'dest',
      bytesTransferred: 100,
    );
  }
}

void main() {
  group('RetryClassifier', () {
    test('classifies transient errors as retryable', () {
      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.networkUnavailable,
            message: 'No internet',
          ),
        ),
        isTrue,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.networkTimeout,
            message: 'Timed out',
          ),
        ),
        isTrue,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '500 Server Error',
            httpStatusCode: 500,
          ),
        ),
        isTrue,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '429 Rate Limit',
            httpStatusCode: 429,
          ),
        ),
        isTrue,
      );

      expect(
        RetryClassifier.isRetryable(const SocketException('Connection lost')),
        isTrue,
      );

      expect(
        RetryClassifier.isRetryable(TimeoutException('Socket timed out')),
        isTrue,
      );
    });

    test('classifies non-transient errors as non-retryable', () {
      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.cancelled,
            message: 'Cancelled',
          ),
        ),
        isFalse,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.fileNotFound,
            message: 'Not found',
            httpStatusCode: 404,
          ),
        ),
        isFalse,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.authenticationExpired,
            message: 'Expired',
            httpStatusCode: 403,
          ),
        ),
        isFalse,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.fileAccessDenied,
            message: 'Permission denied',
          ),
        ),
        isFalse,
      );

      expect(
        RetryClassifier.isRetryable(
          const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '400 Bad Request',
            httpStatusCode: 400,
          ),
        ),
        isFalse,
      );
    });
  });

  group('RetryingTransport & RetryPolicy', () {
    test(
      'RetryPolicy.none fails fast on first error without retrying',
      () async {
        final mock = _MockFlakyTransport();
        mock.uploadBehaviors.add(
          () => const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '503 Service Unavailable',
            httpStatusCode: 503,
            isRetryable: true,
          ),
        );

        final transport = RetryingTransport(
          mock,
          defaultRetryPolicy: RetryPolicy.none,
        );

        final request = S3UploadRequest.fromPresignedUrl(
          filePath: 'test_file',
          uploadUrl: Uri.parse('https://s3.example.com/upload'),
          retryPolicy: RetryPolicy.none,
        );

        expect(
          () => transport.upload(
            request,
            onProgress: (_) {},
            onStatusChanged: (_) {},
          ),
          throwsA(
            isA<TransferException>().having(
              (e) => e.httpStatusCode,
              'httpStatusCode',
              503,
            ),
          ),
        );

        // Verify it was only attempted once!
        expect(mock.uploadCallCount, equals(1));
      },
    );

    test(
      'retries transient failure and succeeds on subsequent attempt',
      () async {
        final mock = _MockFlakyTransport();
        // Attempt 1 fails with 500, attempt 2 succeeds
        mock.uploadBehaviors.add(
          () => const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '500 Internal Error',
            httpStatusCode: 500,
            isRetryable: true,
          ),
        );
        mock.uploadBehaviors.add(
          () => const S3UploadResult(bytesTransferred: 512, eTag: 'etag123'),
        );

        final transport = RetryingTransport(
          mock,
          defaultRetryPolicy: const RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
            useJitter: false,
          ),
        );

        final request = S3UploadRequest.fromPresignedUrl(
          filePath: 'test_file',
          uploadUrl: Uri.parse('https://s3.example.com/upload'),
        );

        final result = await transport.upload(
          request,
          onProgress: (_) {},
          onStatusChanged: (_) {},
        );

        expect(result.bytesTransferred, equals(512));
        expect(result.eTag, equals('etag123'));
        expect(mock.uploadCallCount, equals(2));
      },
    );

    test('rethrows error after exceeding maxAttempts', () async {
      final mock = _MockFlakyTransport();
      // 3 consecutive 503 errors
      for (int i = 0; i < 3; i++) {
        mock.uploadBehaviors.add(
          () => const TransferException(
            code: TransferErrorCode.httpFailure,
            message: '503 Service Unavailable',
            httpStatusCode: 503,
            isRetryable: true,
          ),
        );
      }

      final transport = RetryingTransport(
        mock,
        defaultRetryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      );

      final request = S3UploadRequest.fromPresignedUrl(
        filePath: 'test_file',
        uploadUrl: Uri.parse('https://s3.example.com/upload'),
      );

      await expectLater(
        transport.upload(request, onProgress: (_) {}, onStatusChanged: (_) {}),
        throwsA(
          isA<TransferException>().having(
            (e) => e.httpStatusCode,
            'httpStatusCode',
            503,
          ),
        ),
      );

      expect(mock.uploadCallCount, equals(3));
    });

    test(
      'non-retryable error fails immediately on attempt 1 despite maxAttempts',
      () async {
        final mock = _MockFlakyTransport();
        mock.uploadBehaviors.add(
          () => const TransferException(
            code: TransferErrorCode.authenticationExpired,
            message: '403 Forbidden',
            httpStatusCode: 403,
            isRetryable: false,
          ),
        );

        final transport = RetryingTransport(
          mock,
          defaultRetryPolicy: const RetryPolicy(
            maxAttempts: 5,
            initialDelay: Duration(milliseconds: 1),
          ),
        );

        final request = S3UploadRequest.fromPresignedUrl(
          filePath: 'test_file',
          uploadUrl: Uri.parse('https://s3.example.com/upload'),
        );

        await expectLater(
          transport.upload(
            request,
            onProgress: (_) {},
            onStatusChanged: (_) {},
          ),
          throwsA(
            isA<TransferException>().having(
              (e) => e.code,
              'code',
              TransferErrorCode.authenticationExpired,
            ),
          ),
        );

        expect(mock.uploadCallCount, equals(1));
      },
    );

    test(
      'cancellation during backoff sleep aborts retry loop immediately',
      () async {
        final mock = _MockFlakyTransport();
        mock.uploadBehaviors.add(
          () => const TransferException(
            code: TransferErrorCode.networkUnavailable,
            message: 'Socket disconnected',
            isRetryable: true,
          ),
        );

        final token = CancellationToken();

        final transport = RetryingTransport(
          mock,
          defaultRetryPolicy: const RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration(seconds: 10), // Long delay
            useJitter: false,
          ),
        );

        final request = S3UploadRequest.fromPresignedUrl(
          filePath: 'test_file',
          uploadUrl: Uri.parse('https://s3.example.com/upload'),
          cancellationToken: token,
        );

        final uploadFuture = transport.upload(
          request,
          onProgress: (_) {},
          onStatusChanged: (_) {},
        );

        // Cancel token while sleeping in backoff
        await Future<void>.delayed(const Duration(milliseconds: 10));
        token.cancel('User stopped retry');

        await expectLater(
          uploadFuture,
          throwsA(
            isA<TransferException>().having(
              (e) => e.code,
              'code',
              TransferErrorCode.cancelled,
            ),
          ),
        );

        // Should have only executed attempt 1
        expect(mock.uploadCallCount, equals(1));
      },
    );

    test('retries downloads transparently on transient error', () async {
      final mock = _MockFlakyTransport();
      mock.downloadBehaviors.add(
        () => const TransferException(
          code: TransferErrorCode.httpFailure,
          message: '502 Bad Gateway',
          httpStatusCode: 502,
          isRetryable: true,
        ),
      );
      mock.downloadBehaviors.add(
        () => const S3DownloadResult(
          destinationPath: '/path/to/downloaded',
          bytesTransferred: 1024,
          eTag: 'download_etag',
        ),
      );

      final transport = RetryingTransport(
        mock,
        defaultRetryPolicy: const RetryPolicy(
          maxAttempts: 2,
          initialDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      );

      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: '/path/to/downloaded',
        downloadUrl: Uri.parse('https://s3.example.com/download'),
      );

      final result = await transport.download(
        request,
        onProgress: (_) {},
        onStatusChanged: (_) {},
      );

      expect(result.bytesTransferred, equals(1024));
      expect(mock.downloadCallCount, equals(2));
    });

    test('per-request retryPolicy overrides queue configuration', () async {
      final mock = _MockFlakyTransport();
      // 500 error
      mock.uploadBehaviors.add(
        () => const TransferException(
          code: TransferErrorCode.httpFailure,
          message: '500 Server Error',
          httpStatusCode: 500,
          isRetryable: true,
        ),
      );

      // Queue is configured with standard retry (maxAttempts 3)
      final kit = S3TransferKit(
        transport: mock,
        configuration: const TransferQueueConfiguration(
          defaultRetryPolicy: RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
          ),
        ),
      );

      // Request explicitly overrides with RetryPolicy.none
      final task = kit.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'fail_fast_file',
          uploadUrl: Uri.parse('https://s3.example.com/upload'),
          retryPolicy: RetryPolicy.none,
        ),
      );

      await expectLater(
        task.result,
        throwsA(
          isA<TransferException>().having(
            (e) => e.httpStatusCode,
            'httpStatusCode',
            500,
          ),
        ),
      );

      // Must have failed immediately on 1 attempt
      expect(mock.uploadCallCount, equals(1));

      await kit.dispose();
    });
  });
}
