import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  late Directory tempDir;
  late File sampleFile;
  late HttpServer mockServer;
  late Uri serverUrl;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_test_');
    sampleFile = File('${tempDir.path}/test_upload.txt');
    await sampleFile.writeAsString(
      'Hello S3 Transfer Kit! Testing bounded streaming.',
    );

    mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverUrl = Uri.parse(
      'http://${mockServer.address.host}:${mockServer.port}/upload',
    );
  });

  tearDown(() async {
    await mockServer.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('S3TransferKit.upload', () {
    test('successfully streams file and returns ETag', () async {
      final fileLength = await sampleFile.length();
      final expectedContent = await sampleFile.readAsString();

      mockServer.listen((HttpRequest request) async {
        expect(request.method, 'PUT');
        expect(request.headers.value('content-type'), 'text/plain');
        expect(request.headers.contentLength, fileLength);

        final receivedBytes = <int>[];
        await for (final chunk in request) {
          receivedBytes.addAll(chunk);
        }

        expect(utf8.decode(receivedBytes), expectedContent);

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('etag', '"mock-etag-12345"');
        await request.response.close();
      });

      final s3 = S3TransferKit();
      final progressEvents = <TransferProgress>[];

      final request = S3UploadRequest.fromPresignedUrl(
        filePath: sampleFile.path,
        uploadUrl: serverUrl,
        contentType: 'text/plain',
      );

      final task = s3.upload(request);
      task.progress.listen(progressEvents.add);

      final result = await task.result;

      expect(result.bytesTransferred, fileLength);
      expect(result.eTag, 'mock-etag-12345');
      expect(task.status, TransferStatus.completed);

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.first.bytesTransferred, 0);
      expect(progressEvents.last.bytesTransferred, fileLength);
      expect(progressEvents.last.fraction, 1.0);
    });

    test('throws authenticationExpired when S3 responds with 403', () async {
      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(
          '<Error><Code>ExpiredToken</Code><Message>The provided token has expired.</Message></Error>',
        );
        await request.response.close();
      });

      final s3 = S3TransferKit();
      final request = S3UploadRequest.fromPresignedUrl(
        filePath: sampleFile.path,
        uploadUrl: serverUrl,
      );

      final task = s3.upload(request);

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>()
              .having(
                (e) => e.code,
                'code',
                TransferErrorCode.authenticationExpired,
              )
              .having((e) => e.httpStatusCode, 'httpStatusCode', 403)
              .having((e) => e.isAuthError, 'isAuthError', isTrue),
        ),
      );
    });

    test(
      'throws httpFailure with retryable flag when S3 responds with 500',
      () async {
        mockServer.listen((HttpRequest request) async {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('<Error><Code>InternalError</Code></Error>');
          await request.response.close();
        });

        final s3 = S3TransferKit();
        final request = S3UploadRequest.fromPresignedUrl(
          filePath: sampleFile.path,
          uploadUrl: serverUrl,
        );

        final task = s3.upload(request);

        expect(
          () => task.result,
          throwsA(
            isA<TransferException>()
                .having((e) => e.code, 'code', TransferErrorCode.httpFailure)
                .having((e) => e.httpStatusCode, 'httpStatusCode', 500)
                .having((e) => e.isRetryable, 'isRetryable', isTrue),
          ),
        );
      },
    );

    test(
      'cancelling before upload starts throws TransferException.cancelled',
      () async {
        final cancellationToken = CancellationToken()
          ..cancel('Aborted before start');
        final s3 = S3TransferKit();

        final request = S3UploadRequest.fromPresignedUrl(
          filePath: sampleFile.path,
          uploadUrl: serverUrl,
          cancellationToken: cancellationToken,
        );

        final task = s3.upload(request);

        expect(
          () => task.result,
          throwsA(
            isA<TransferException>()
                .having((e) => e.code, 'code', TransferErrorCode.cancelled)
                .having((e) => e.isCancelled, 'isCancelled', isTrue)
                .having((e) => e.message, 'message', 'Aborted before start'),
          ),
        );
      },
    );

    test('cancelling via task handle cancels in-flight upload', () async {
      final cancellationToken = CancellationToken();

      mockServer.listen((HttpRequest request) async {
        // Delay response to allow cancellation to take effect
        await Future<void>.delayed(const Duration(milliseconds: 50));
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
      });

      final s3 = S3TransferKit();
      final request = S3UploadRequest.fromPresignedUrl(
        filePath: sampleFile.path,
        uploadUrl: serverUrl,
        cancellationToken: cancellationToken,
      );

      final task = s3.upload(request);
      task.cancel('User cancelled');

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>()
              .having((e) => e.code, 'code', TransferErrorCode.cancelled)
              .having((e) => e.isCancelled, 'isCancelled', isTrue),
        ),
      );
    });

    test('throws fileNotFound when file does not exist', () async {
      final s3 = S3TransferKit();
      final request = S3UploadRequest.fromPresignedUrl(
        filePath: '${tempDir.path}/non_existent_file.txt',
        uploadUrl: serverUrl,
      );

      final task = s3.upload(request);

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            TransferErrorCode.fileNotFound,
          ),
        ),
      );
    });

    test('throws invalidConfiguration when filePath is a directory', () async {
      final s3 = S3TransferKit();
      final request = S3UploadRequest.fromPresignedUrl(
        filePath: tempDir.path,
        uploadUrl: serverUrl,
      );

      final task = s3.upload(request);

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            TransferErrorCode.invalidConfiguration,
          ),
        ),
      );
    });
  });
}
