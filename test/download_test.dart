import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  late Directory tempDir;
  late HttpServer mockServer;
  late Uri serverUrl;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_download_test_');
    mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverUrl = Uri.parse(
      'http://${mockServer.address.host}:${mockServer.port}/download',
    );
  });

  tearDown(() async {
    await mockServer.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('S3TransferKit.download', () {
    test('successfully downloads file and emits progress', () async {
      const serverPayload = 'Downloaded content from Amazon S3 bucket.';
      final payloadBytes = utf8.encode(serverPayload);

      mockServer.listen((HttpRequest request) async {
        expect(request.method, 'GET');
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('etag', '"download-etag-999"');
        request.response.headers.contentLength = payloadBytes.length;
        request.response.add(payloadBytes);
        await request.response.close();
      });

      final destinationPath = '${tempDir.path}/output_file.txt';
      final s3 = S3TransferKit();
      final progressEvents = <TransferProgress>[];

      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
      );

      final task = s3.download(request);
      task.progress.listen(progressEvents.add);

      final result = await task.result;

      expect(result.destinationPath, destinationPath);
      expect(result.bytesTransferred, payloadBytes.length);
      expect(result.eTag, 'download-etag-999');
      expect(task.status, TransferStatus.completed);

      final destinationFile = File(destinationPath);
      expect(await destinationFile.exists(), isTrue);
      expect(await destinationFile.readAsString(), serverPayload);

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.first.bytesTransferred, 0);
      expect(progressEvents.last.bytesTransferred, payloadBytes.length);
      expect(progressEvents.last.fraction, 1.0);

      // Verify no temporary .tmp files left in directory
      final leftoverFiles = tempDir.listSync().where(
        (f) => f.path.endsWith('.tmp'),
      );
      expect(leftoverFiles, isEmpty);
    });

    test(
      'throws invalidConfiguration when file exists and overwrite is false',
      () async {
        final destinationPath = '${tempDir.path}/existing.txt';
        await File(destinationPath).writeAsString('Existing content');

        final s3 = S3TransferKit();
        final request = S3DownloadRequest.fromPresignedUrl(
          destinationPath: destinationPath,
          downloadUrl: serverUrl,
          overwrite: false,
        );

        final task = s3.download(request);

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

        // Existing file content preserved
        expect(await File(destinationPath).readAsString(), 'Existing content');
      },
    );

    test('replaces existing file when overwrite is true', () async {
      final destinationPath = '${tempDir.path}/existing.txt';
      await File(destinationPath).writeAsString('Old content');

      const newContent = 'Replaced new content';
      final newBytes = utf8.encode(newContent);

      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = newBytes.length;
        request.response.add(newBytes);
        await request.response.close();
      });

      final s3 = S3TransferKit();
      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
        overwrite: true,
      );

      final task = s3.download(request);
      final result = await task.result;

      expect(result.bytesTransferred, newBytes.length);
      expect(await File(destinationPath).readAsString(), newContent);
    });

    test('creates nested parent directories automatically', () async {
      const content = 'Nested directory test content';
      final contentBytes = utf8.encode(content);

      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = contentBytes.length;
        request.response.add(contentBytes);
        await request.response.close();
      });

      final destinationPath = '${tempDir.path}/deep/nested/sub/folder/file.txt';
      final s3 = S3TransferKit();
      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
      );

      final task = s3.download(request);
      final result = await task.result;

      expect(result.destinationPath, destinationPath);
      expect(await File(destinationPath).exists(), isTrue);
      expect(await File(destinationPath).readAsString(), content);
    });

    test('throws fileNotFound when S3 responds with 404', () async {
      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(
          '<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>',
        );
        await request.response.close();
      });

      final destinationPath = '${tempDir.path}/not_found.txt';
      final s3 = S3TransferKit();
      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
      );

      final task = s3.download(request);

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>()
              .having((e) => e.code, 'code', TransferErrorCode.fileNotFound)
              .having((e) => e.httpStatusCode, 'httpStatusCode', 404),
        ),
      );

      // Verify no file created
      expect(await File(destinationPath).exists(), isFalse);
    });

    test('throws authenticationExpired when S3 responds with 403', () async {
      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(
          '<Error><Code>ExpiredToken</Code><Message>The provided token has expired.</Message></Error>',
        );
        await request.response.close();
      });

      final destinationPath = '${tempDir.path}/expired.txt';
      final s3 = S3TransferKit();
      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
      );

      final task = s3.download(request);

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

      expect(await File(destinationPath).exists(), isFalse);
    });

    test(
      'cancelling before download starts throws TransferException.cancelled',
      () async {
        final cancellationToken = CancellationToken()
          ..cancel('Aborted before download');

        final destinationPath = '${tempDir.path}/cancelled.txt';
        final s3 = S3TransferKit();
        final request = S3DownloadRequest.fromPresignedUrl(
          destinationPath: destinationPath,
          downloadUrl: serverUrl,
          cancellationToken: cancellationToken,
        );

        final task = s3.download(request);

        expect(
          () => task.result,
          throwsA(
            isA<TransferException>()
                .having((e) => e.code, 'code', TransferErrorCode.cancelled)
                .having((e) => e.isCancelled, 'isCancelled', isTrue),
          ),
        );

        expect(await File(destinationPath).exists(), isFalse);
      },
    );

    test('cancelling in-flight download cleans up staging file and throws cancelled', () async {
      final cancellationToken = CancellationToken();
      final destinationPath = '${tempDir.path}/in_flight_cancelled.txt';

      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = 100000;
        // Write a small chunk then pause
        request.response.add(utf8.encode('partial initial bytes'));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        request.response.add(utf8.encode('more bytes'));
        await request.response.close();
      });

      final s3 = S3TransferKit();
      final request = S3DownloadRequest.fromPresignedUrl(
        destinationPath: destinationPath,
        downloadUrl: serverUrl,
        cancellationToken: cancellationToken,
      );

      final task = s3.download(request);
      task.cancel('User aborted');

      expect(
        () => task.result,
        throwsA(
          isA<TransferException>()
              .having((e) => e.code, 'code', TransferErrorCode.cancelled)
              .having((e) => e.isCancelled, 'isCancelled', isTrue),
        ),
      );

      // Verify neither destination nor any .tmp files exist
      expect(await File(destinationPath).exists(), isFalse);
      final tmpFiles = tempDir.listSync().where((f) => f.path.endsWith('.tmp'));
      expect(tmpFiles, isEmpty);
    });
  });
}
