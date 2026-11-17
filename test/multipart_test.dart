import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  late Directory tempDir;
  late HttpServer mockServer;
  late Uri serverBaseUrl;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_multipart_test_');
    mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverBaseUrl = Uri.parse(
      'http://${mockServer.address.host}:${mockServer.port}',
    );
  });

  tearDown(() async {
    await mockServer.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('S3TransferKit.uploadMultipart', () {
    test('slices large file, uploads parts concurrently, and completes multipart upload', () async {
      // 11 MB file: 2 full 5MB parts + 1 partial 1MB part
      const totalSize = 11 * 1024 * 1024;
      final file = File('${tempDir.path}/large_file.bin');
      final sink = file.openWrite();
      for (int i = 0; i < 11; i++) {
        sink.add(List<int>.filled(1024 * 1024, i % 256));
      }
      await sink.flush();
      await sink.close();

      final partsUploaded = <int, List<int>>{};
      final uploadedETags = <int, String>{};

      mockServer.listen((HttpRequest request) async {
        final partNumberStr = request.uri.queryParameters['partNumber'];
        final partNumber = int.parse(partNumberStr!);

        final body = <int>[];
        await for (final chunk in request) {
          body.addAll(chunk);
        }
        partsUploaded[partNumber] = body;

        final eTag = 'etag_for_part_$partNumber';
        uploadedETags[partNumber] = eTag;

        request.response.headers.set('etag', '"$eTag"');
        request.response.statusCode = 200;
        await request.response.close();
      });

      String? initiatedUploadId;
      List<S3PartETag>? completedParts;
      bool abortCalled = false;

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              initiatedUploadId = 'upload_id_xyz_123';
              return initiatedUploadId!;
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              return serverBaseUrl.replace(
                path: '/part_upload',
                queryParameters: {
                  'uploadId': uploadId,
                  'partNumber': partNumber.toString(),
                },
              );
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              completedParts = parts;
              return const S3UploadResult(
                bytesTransferred: totalSize,
                eTag: 'final_multipart_etag_combined',
              );
            },
        onAbort: ({required String uploadId}) async {
          abortCalled = true;
        },
      );

      final kit = S3TransferKit();
      final progressUpdates = <TransferProgress>[];

      final task = kit.uploadMultipart(
        S3MultipartUploadRequest(
          filePath: file.path,
          provider: provider,
          partSize: 5 * 1024 * 1024, // 5 MB
          maxConcurrentParts: 2,
        ),
      );

      task.progress.listen(progressUpdates.add);

      final result = await task.result;

      expect(result.bytesTransferred, equals(totalSize));
      expect(result.eTag, equals('final_multipart_etag_combined'));
      expect(task.status, equals(TransferStatus.completed));
      expect(abortCalled, isFalse);
      expect(initiatedUploadId, equals('upload_id_xyz_123'));

      // Verify parts count and contents
      expect(partsUploaded.length, equals(3));
      expect(partsUploaded[1]!.length, equals(5 * 1024 * 1024));
      expect(partsUploaded[2]!.length, equals(5 * 1024 * 1024));
      expect(partsUploaded[3]!.length, equals(1 * 1024 * 1024));

      // Verify completedParts submitted in order
      expect(completedParts!.length, equals(3));
      expect(completedParts![0].partNumber, equals(1));
      expect(completedParts![0].eTag, equals('etag_for_part_1'));
      expect(completedParts![1].partNumber, equals(2));
      expect(completedParts![1].eTag, equals('etag_for_part_2'));
      expect(completedParts![2].partNumber, equals(3));
      expect(completedParts![2].eTag, equals('etag_for_part_3'));

      // Verify progress reporting
      expect(progressUpdates.isNotEmpty, isTrue);
      expect(progressUpdates.last.bytesTransferred, equals(totalSize));
      expect(progressUpdates.last.fraction, equals(1.0));

      await kit.dispose();
    });

    test('cancelling in-flight multipart upload calls abortMultipartUpload and cleans up', () async {
      // 10 MB file
      const totalSize = 10 * 1024 * 1024;
      final file = File('${tempDir.path}/cancel_file.bin');
      await file.writeAsBytes(List<int>.filled(totalSize, 42));

      final token = CancellationToken();
      bool abortCalled = false;
      String? abortedUploadId;

      mockServer.listen((HttpRequest request) async {
        // Slow response to allow cancellation during transfer
        await Future<void>.delayed(const Duration(milliseconds: 50));
        token.cancel('User cancelled transfer');
        request.response.statusCode = 200;
        request.response.headers.set('etag', '"etag_1"');
        await request.response.close();
      });

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              return 'upload_to_cancel_456';
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              return serverBaseUrl.replace(
                path: '/part',
                queryParameters: {'part': partNumber.toString()},
              );
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              return const S3UploadResult(bytesTransferred: totalSize);
            },
        onAbort: ({required String uploadId}) async {
          abortCalled = true;
          abortedUploadId = uploadId;
        },
      );

      final kit = S3TransferKit();
      final task = kit.uploadMultipart(
        S3MultipartUploadRequest(
          filePath: file.path,
          provider: provider,
          cancellationToken: token,
          partSize: 5 * 1024 * 1024,
        ),
      );

      await expectLater(
        task.result,
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            TransferErrorCode.cancelled,
          ),
        ),
      );

      expect(task.status, equals(TransferStatus.cancelled));
      expect(abortCalled, isTrue);
      expect(abortedUploadId, equals('upload_to_cancel_456'));

      await kit.dispose();
    });

    test(
      'unrecoverable part error aborts multipart upload and fails task',
      () async {
        const totalSize = 10 * 1024 * 1024;
        final file = File('${tempDir.path}/error_file.bin');
        await file.writeAsBytes(List<int>.filled(totalSize, 1));

        bool abortCalled = false;

        mockServer.listen((HttpRequest request) async {
          request.response.statusCode = 500;
          request.response.write('Internal Server Error');
          await request.response.close();
        });

        final provider = S3MultipartProvider.fromCallbacks(
          onInitiate:
              ({
                required String filePath,
                required int fileLength,
                required String contentType,
                Map<String, String> customHeaders = const {},
              }) async {
                return 'upload_to_abort_on_error';
              },
          onGetPartUrl:
              ({
                required String uploadId,
                required int partNumber,
                required int partLength,
              }) async {
                return serverBaseUrl.replace(path: '/part');
              },
          onComplete:
              ({
                required String uploadId,
                required List<S3PartETag> parts,
              }) async {
                return const S3UploadResult(bytesTransferred: totalSize);
              },
          onAbort: ({required String uploadId}) async {
            abortCalled = true;
          },
        );

        final kit = S3TransferKit();
        final task = kit.uploadMultipart(
          S3MultipartUploadRequest(
            filePath: file.path,
            provider: provider,
            partSize: 5 * 1024 * 1024,
            retryPolicy: RetryPolicy.none, // Fail fast without retrying part
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

        expect(task.status, equals(TransferStatus.failed));
        expect(abortCalled, isTrue);

        await kit.dispose();
      },
    );

    test('retries transient part failure transparently and succeeds', () async {
      const totalSize = 10 * 1024 * 1024;
      final file = File('${tempDir.path}/retry_part_file.bin');
      await file.writeAsBytes(List<int>.filled(totalSize, 2));

      int part1Attempts = 0;

      mockServer.listen((HttpRequest request) async {
        final partNumber = request.uri.queryParameters['part'];
        if (partNumber == '1') {
          part1Attempts++;
          if (part1Attempts == 1) {
            request.response.statusCode = 503;
            request.response.write('Service Unavailable');
            await request.response.close();
            return;
          }
        }

        request.response.statusCode = 200;
        request.response.headers.set('etag', '"etag_$partNumber"');
        await request.response.close();
      });

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              return 'upload_with_retry';
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              return serverBaseUrl.replace(
                path: '/part',
                queryParameters: {'part': partNumber.toString()},
              );
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              return const S3UploadResult(
                bytesTransferred: totalSize,
                eTag: 'completed_after_part_retry',
              );
            },
        onAbort: ({required String uploadId}) async {},
      );

      final kit = S3TransferKit();
      final task = kit.uploadMultipart(
        S3MultipartUploadRequest(
          filePath: file.path,
          provider: provider,
          partSize: 5 * 1024 * 1024,
          maxConcurrentParts: 1,
          retryPolicy: const RetryPolicy(
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 1),
            useJitter: false,
          ),
        ),
      );

      final result = await task.result;
      expect(result.eTag, equals('completed_after_part_retry'));
      expect(
        part1Attempts,
        equals(2),
      ); // Part 1 failed once, succeeded on 2nd attempt

      await kit.dispose();
    });

    test('small file (< 5 MB) uploads as single part', () async {
      const smallSize = 1024 * 1024; // 1 MB
      final file = File('${tempDir.path}/small_file.bin');
      await file.writeAsBytes(List<int>.filled(smallSize, 7));

      mockServer.listen((HttpRequest request) async {
        request.response.statusCode = 200;
        request.response.headers.set('etag', '"small_etag_1"');
        await request.response.close();
      });

      List<S3PartETag>? submittedParts;

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              return 'small_upload_id';
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              expect(partNumber, equals(1));
              expect(partLength, equals(smallSize));
              return serverBaseUrl.replace(path: '/small_part');
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              submittedParts = parts;
              return const S3UploadResult(
                bytesTransferred: smallSize,
                eTag: 'small_complete_etag',
              );
            },
        onAbort: ({required String uploadId}) async {},
      );

      final kit = S3TransferKit();
      final task = kit.uploadMultipart(
        S3MultipartUploadRequest(filePath: file.path, provider: provider),
      );

      final result = await task.result;
      expect(result.bytesTransferred, equals(smallSize));
      expect(submittedParts!.length, equals(1));
      expect(submittedParts![0].partNumber, equals(1));
      expect(submittedParts![0].eTag, equals('small_etag_1'));

      await kit.dispose();
    });
  });
}
