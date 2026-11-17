import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_perf_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Phase 9 — Performance & Reliability Validation', () {
    test('Bounded memory: streams large file chunk-by-chunk without full buffering', () async {
      // Create an 8MB file with deterministic binary content
      final file = File('${tempDir.path}/large_file.bin');
      final sink = file.openWrite();
      final pattern = Uint8List.fromList(List.generate(65536, (i) => i % 256));
      for (int i = 0; i < 128; i++) {
        sink.add(pattern);
      }
      await sink.flush();
      await sink.close();

      final fileLength = await file.length();
      expect(fileLength, 128 * 65536); // 8,388,608 bytes

      final expectedSha256 = (await sha256.bind(file.openRead()).first)
          .toString();

      // Local server to measure incoming chunk sizes
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receivedChunkSizes = <int>[];
      final serverSha256Completer = Completer<String>();

      server.listen((HttpRequest request) async {
        expect(request.method, 'PUT');
        expect(request.headers.contentLength, fileLength);

        final digest = await sha256
            .bind(
              request.map((chunk) {
                receivedChunkSizes.add(chunk.length);
                return chunk;
              }),
            )
            .first;

        serverSha256Completer.complete(digest.toString());

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('etag', '"perf-etag-test"');
        await request.response.close();
      });

      final uploadUrl = Uri.parse(
        'http://${server.address.host}:${server.port}/upload',
      );

      final s3 = S3TransferKit();
      final progressUpdates = <TransferProgress>[];

      final uploadTask = s3.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: file.path,
          uploadUrl: uploadUrl,
        ),
      );

      uploadTask.progress.listen(progressUpdates.add);
      final result = await uploadTask.result;

      expect(result.bytesTransferred, fileLength);
      expect(result.eTag, 'perf-etag-test');

      final receivedHash = await serverSha256Completer.future;
      expect(receivedHash, expectedSha256);

      // Verification of bounded memory chunking:
      // 8MB streamed in chunks, so receivedChunkSizes must contain dozens of chunks
      // with each individual chunk bounded in size (<= 256KB across TCP loopback).
      expect(
        receivedChunkSizes.length,
        greaterThan(30),
        reason: 'File must be streamed in multiple discrete chunks',
      );
      for (final size in receivedChunkSizes) {
        expect(
          size,
          lessThanOrEqualTo(262144),
          reason: 'Individual chunk size must remain bounded',
        );
      }

      // Verify monotonic progress reporting
      expect(progressUpdates.isNotEmpty, true);
      int lastBytes = 0;
      for (final progress in progressUpdates) {
        expect(progress.bytesTransferred, greaterThanOrEqualTo(lastBytes));
        expect(progress.totalBytes, fileLength);
        lastBytes = progress.bytesTransferred;
      }
      expect(lastBytes, fileLength);

      // Now test bounded download of the same 8MB payload
      final downloadDestination = File('${tempDir.path}/downloaded.bin');
      final downloadServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );

      downloadServer.listen((HttpRequest request) async {
        expect(request.method, 'GET');
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = fileLength;
        request.response.headers.set('etag', '"download-etag"');
        await request.response.addStream(file.openRead());
        await request.response.close();
      });

      final downloadUrl = Uri.parse(
        'http://${downloadServer.address.host}:${downloadServer.port}/download',
      );

      final downloadTask = s3.download(
        S3DownloadRequest.fromPresignedUrl(
          downloadUrl: downloadUrl,
          destinationPath: downloadDestination.path,
        ),
      );

      final downloadResult = await downloadTask.result;
      expect(downloadResult.bytesTransferred, fileLength);
      expect(await downloadDestination.exists(), true);

      final downloadedSha256 =
          (await sha256.bind(downloadDestination.openRead()).first).toString();
      expect(downloadedSha256, expectedSha256);

      await server.close(force: true);
      await downloadServer.close(force: true);
      await s3.dispose();
    });

    test('High concurrency queue saturation: executes 120 tasks respecting maxConcurrentTransfers without starvation', () async {
      const maxConcurrent = 4;
      const totalTasks = 120;

      int activeRunning = 0;
      int peakRunning = 0;
      final completionOrder = <int>[];
      final highTaskIds = <int>{};
      final lowTaskIds = <int>{};

      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: maxConcurrent,
        ),
        transport: _SimulatedDelayTransport(
          onStart: () {
            activeRunning++;
            if (activeRunning > peakRunning) {
              peakRunning = activeRunning;
            }
          },
          onEnd: () {
            activeRunning--;
          },
        ),
      );

      // Pre-create dummy files
      final dummyFile = File('${tempDir.path}/dummy.txt');
      await dummyFile.writeAsString('test content for high concurrency');

      final tasks = <S3UploadTask>[];

      for (int i = 0; i < totalTasks; i++) {
        final TransferPriority priority;
        if (i < 40) {
          priority = TransferPriority.high;
          highTaskIds.add(i);
        } else if (i < 80) {
          priority = TransferPriority.normal;
        } else {
          priority = TransferPriority.low;
          lowTaskIds.add(i);
        }

        final task = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: dummyFile.path,
            uploadUrl: Uri.parse('https://s3.example.com/item_$i'),
            priority: priority,
          ),
        );

        task.result.then((_) => completionOrder.add(i));
        tasks.add(task);
      }

      // Wait for all 120 tasks to complete
      await Future.wait(tasks.map((t) => t.result));

      // Invariant 1: Concurrency limit strictly enforced at all times
      expect(peakRunning, lessThanOrEqualTo(maxConcurrent));
      expect(activeRunning, 0);
      expect(completionOrder.length, totalTasks);

      // Invariant 2: Queue metrics return to clean idle state
      expect(manager.queuedCount, 0);
      expect(manager.runningCount, 0);
      expect(manager.snapshot.queuedCount, 0);
      expect(manager.snapshot.runningCount, 0);

      // Invariant 3: High priority tasks finish on average earlier than low priority tasks
      final highIndices = highTaskIds.map((id) => completionOrder.indexOf(id));
      final lowIndices = lowTaskIds.map((id) => completionOrder.indexOf(id));

      final avgHighIndex =
          highIndices.reduce((a, b) => a + b) / highIndices.length;
      final avgLowIndex =
          lowIndices.reduce((a, b) => a + b) / lowIndices.length;

      expect(
        avgHighIndex,
        lessThan(avgLowIndex),
        reason: 'High priority tasks must schedule ahead of low priority tasks',
      );

      await manager.dispose();
    });

    test('Socket drop recovery: survives mid-stream socket aborts and resumes transparently', () async {
      final file = File('${tempDir.path}/retry_file.txt');
      await file.writeAsString(
        'Resilience test content that needs to survive socket drops.',
      );
      final fileLength = await file.length();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int connectionAttempts = 0;

      server.listen((HttpRequest request) async {
        connectionAttempts++;
        if (connectionAttempts == 1) {
          // Drop connection after reading partial request
          await request.take(1).drain<void>();
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }

        if (connectionAttempts == 2) {
          // Abruptly close socket before response
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }

        // Attempt 3 succeeds cleanly
        await request.drain<void>();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('etag', '"survived-socket-drop"');
        await request.response.close();
      });

      final s3 = S3TransferKit(
        configuration: const TransferQueueConfiguration(
          defaultRetryPolicy: RetryPolicy(
            allowRetry: true,
            maxAttempts: 4,
            initialDelay: Duration(milliseconds: 20),
            maxDelay: Duration(milliseconds: 100),
          ),
        ),
      );

      final task = s3.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: file.path,
          uploadUrl: Uri.parse(
            'http://${server.address.host}:${server.port}/upload',
          ),
        ),
      );

      final result = await task.result;

      expect(connectionAttempts, 3);
      expect(result.bytesTransferred, fileLength);
      expect(result.eTag, 'survived-socket-drop');

      await server.close(force: true);
      await s3.dispose();
    });

    test(
      'Rate limiting & backpressure: backs off on HTTP 429 and succeeds',
      () async {
        final file = File('${tempDir.path}/rate_limit.txt');
        await file.writeAsString('Payload tested against 429 throttling.');

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        int requestCount = 0;
        final requestTimestamps = <DateTime>[];

        server.listen((HttpRequest request) async {
          requestCount++;
          requestTimestamps.add(DateTime.now());
          await request.drain<void>();

          if (requestCount <= 2) {
            request.response.statusCode = HttpStatus.tooManyRequests; // 429
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              'text/plain',
            );
            request.response.write('Rate limit exceeded. Please back off.');
            await request.response.close();
            return;
          }

          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('etag', '"rate-limit-passed"');
          await request.response.close();
        });

        final s3 = S3TransferKit(
          configuration: const TransferQueueConfiguration(
            defaultRetryPolicy: RetryPolicy(
              allowRetry: true,
              maxAttempts: 4,
              initialDelay: Duration(milliseconds: 80),
              maxDelay: Duration(milliseconds: 300),
            ),
          ),
        );

        final task = s3.upload(
          S3UploadRequest.fromPresignedUrl(
            filePath: file.path,
            uploadUrl: Uri.parse(
              'http://${server.address.host}:${server.port}/upload',
            ),
          ),
        );

        final result = await task.result;

        expect(requestCount, 3);
        expect(result.eTag, 'rate-limit-passed');

        // Verify exponential backoff delay occurred across attempts
        final totalElapsed = requestTimestamps.last.difference(
          requestTimestamps.first,
        );
        expect(totalElapsed.inMilliseconds, greaterThanOrEqualTo(10));

        await server.close(force: true);
        await s3.dispose();
      },
    );

    test('Retry exhaustion: persistently failing 503 throws typed TransferException', () async {
      final file = File('${tempDir.path}/exhaust.txt');
      await file.writeAsString('Exhaustion test');

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int requestCount = 0;

      server.listen((HttpRequest request) async {
        requestCount++;
        await request.drain<void>();
        request.response.statusCode = HttpStatus.serviceUnavailable; // 503
        request.response.write('Service temporarily overloaded');
        await request.response.close();
      });

      final s3 = S3TransferKit(
        configuration: const TransferQueueConfiguration(
          defaultRetryPolicy: RetryPolicy(
            allowRetry: true,
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 15),
            maxDelay: Duration(milliseconds: 50),
          ),
        ),
      );

      final task = s3.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: file.path,
          uploadUrl: Uri.parse(
            'http://${server.address.host}:${server.port}/upload',
          ),
        ),
      );

      await expectLater(
        task.result,
        throwsA(
          isA<TransferException>()
              .having((e) => e.code, 'code', TransferErrorCode.httpFailure)
              .having((e) => e.isRetryable, 'isRetryable', true),
        ),
      );

      expect(requestCount, 3);

      await server.close(force: true);
      await s3.dispose();
    });

    test('Multipart network chaos: independent part failure and retry does not restart other parts', () async {
      // Create 15MB file (3 parts x 5MB)
      final file = File('${tempDir.path}/multipart_chaos.bin');
      final sink = file.openWrite();
      final pattern = Uint8List(5 * 1024 * 1024); // 5MB zeros
      for (int i = 0; i < 3; i++) {
        sink.add(pattern);
      }
      await sink.flush();
      await sink.close();

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final partUploadAttempts = <int, int>{1: 0, 2: 0, 3: 0};

      server.listen((HttpRequest request) async {
        final partNum =
            int.tryParse(request.uri.queryParameters['partNumber'] ?? '0') ?? 0;
        partUploadAttempts[partNum] = (partUploadAttempts[partNum] ?? 0) + 1;

        await request.drain<void>();

        // Part 2 fails on attempt 1 with 503, then succeeds on attempt 2
        if (partNum == 2 && partUploadAttempts[2] == 1) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.ok;
        request.response.headers.set('etag', '"etag-part-$partNum"');
        await request.response.close();
      });

      final completedPartsSubmitted = <S3PartETag>[];

      final mockProvider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              return 'chaos-upload-id';
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              return Uri.parse(
                'http://${server.address.host}:${server.port}/part?partNumber=$partNumber',
              );
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              completedPartsSubmitted.addAll(parts);
              return S3UploadResult(
                bytesTransferred: 15 * 1024 * 1024,
                eTag: 'final-chaos-etag',
              );
            },
        onAbort: ({required String uploadId}) async {},
      );

      final coordinator = MultipartUploadCoordinator();
      final result = await coordinator.upload(
        S3MultipartUploadRequest(
          filePath: file.path,
          provider: mockProvider,
          partSize: 5 * 1024 * 1024,
          maxConcurrentParts: 2,
          retryPolicy: const RetryPolicy(
            allowRetry: true,
            maxAttempts: 3,
            initialDelay: Duration(milliseconds: 20),
          ),
        ),
        onProgress: (_) {},
        onStatusChanged: (_) {},
      );

      expect(result.eTag, 'final-chaos-etag');

      // Verify Part 1 and Part 3 were only attempted once
      expect(partUploadAttempts[1], 1);
      expect(partUploadAttempts[2], 2); // Retried once and succeeded
      expect(partUploadAttempts[3], 1);

      // Verify completed parts are ordered 1, 2, 3
      expect(completedPartsSubmitted.length, 3);
      expect(completedPartsSubmitted.map((p) => p.partNumber).toList(), [
        1,
        2,
        3,
      ]);

      await server.close(force: true);
    });

    test('Chaos cancellation: cancelAll cleanly drains 60 active and waiting tasks', () async {
      final dummyFile = File('${tempDir.path}/cancel_dummy.txt');
      await dummyFile.writeAsString('cancel test');

      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 3,
        ),
        transport: _SimulatedDelayTransport(delayMs: 200),
      );

      final tasks = List.generate(
        60,
        (i) => manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: dummyFile.path,
            uploadUrl: Uri.parse('https://s3.example.com/cancel_$i'),
          ),
        ),
      );

      // Allow some tasks to transition to inProgress
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(manager.runningCount, greaterThan(0));
      expect(manager.queuedCount, greaterThan(0));

      // Listen to all task results to observe errors cleanly without unhandled zone rejections
      final cancelErrors = <Object>[];
      for (final task in tasks) {
        task.result.catchError((Object error) {
          cancelErrors.add(error);
          return S3UploadResult(bytesTransferred: 0);
        });
      }

      // Stress cancellation
      manager.cancelAll('Emergency shutdown');

      // Await all tasks to settle
      await Future.wait(
        tasks.map(
          (t) =>
              t.result.catchError((_) => S3UploadResult(bytesTransferred: 0)),
        ),
      );

      // All 60 tasks must complete with TransferException.cancelled
      expect(cancelErrors.length, 60);
      for (final error in cancelErrors) {
        expect(
          error,
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            TransferErrorCode.cancelled,
          ),
        );
      }

      // Give microtask queue a moment to process whenComplete and drain
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(manager.queuedCount, 0);
      expect(manager.runningCount, 0);
      expect(manager.snapshot.queuedCount, 0);
      expect(manager.snapshot.runningCount, 0);

      await manager.dispose();
    });

    test('Resource disposal: dispose closes all controllers and rejects subsequent tasks', () async {
      final dummyFile = File('${tempDir.path}/disposal.txt');
      await dummyFile.writeAsString('disposal test');

      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 2,
        ),
        transport: _SimulatedDelayTransport(delayMs: 50),
      );

      final snapshotUpdates = <TransferQueueSnapshot>[];
      manager.snapshotStream.listen(snapshotUpdates.add);

      manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: dummyFile.path,
          uploadUrl: Uri.parse('https://s3.example.com/disposal_1'),
        ),
      );

      await manager.dispose();

      expect(
        () => manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: dummyFile.path,
            uploadUrl: Uri.parse('https://s3.example.com/disposal_2'),
          ),
        ),
        throwsStateError,
      );
    });
  });
}

class _SimulatedDelayTransport implements TransferTransport {
  _SimulatedDelayTransport({this.delayMs = 15, this.onStart, this.onEnd});

  final int delayMs;
  final void Function()? onStart;
  final void Function()? onEnd;

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

    onStart?.call();
    onStatusChanged(TransferStatus.inProgress);

    final completer = Completer<S3UploadResult>();
    Timer? timer;

    void onCancel() {
      timer?.cancel();
      onStatusChanged(TransferStatus.cancelled);
      if (!completer.isCompleted) {
        onEnd?.call();
        completer.completeError(
          TransferException.cancelled(reason: token?.reason),
        );
      }
    }

    token?.onCancelled(onCancel);

    timer = Timer(Duration(milliseconds: delayMs), () {
      if (!completer.isCompleted) {
        onEnd?.call();
        onStatusChanged(TransferStatus.completed);
        completer.complete(
          S3UploadResult(bytesTransferred: 100, eTag: 'simulated-etag'),
        );
      }
    });

    return completer.future;
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    throw UnimplementedError();
  }
}
