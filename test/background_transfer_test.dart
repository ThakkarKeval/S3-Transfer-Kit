import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';
import 'package:s3_transfer_kit/src/messages.g.dart';

class _MockHostApi implements S3TransferKitHostApi {
  bool supported = true;
  NativeUploadRequest? lastUploadRequest;
  NativeDownloadRequest? lastDownloadRequest;
  String? lastCancelledTaskId;
  String? lastPausedTaskId;
  Completer<void>? uploadStartedCompleter;
  Completer<void>? downloadStartedCompleter;

  @override
  // ignore: non_constant_identifier_names
  BinaryMessenger? get pigeonVar_binaryMessenger => null;

  @override
  // ignore: non_constant_identifier_names
  String get pigeonVar_messageChannelSuffix => '';

  @override
  Future<String?> getPlatformVersion() async => 'TestOS 1.0';

  @override
  Future<bool> isBackgroundTransferSupported() async => supported;

  @override
  Future<void> startBackgroundUpload(NativeUploadRequest request) async {
    lastUploadRequest = request;
    uploadStartedCompleter?.complete();
  }

  @override
  Future<void> startBackgroundDownload(NativeDownloadRequest request) async {
    lastDownloadRequest = request;
    downloadStartedCompleter?.complete();
  }

  @override
  Future<void> cancelBackgroundTransfer(String taskId) async {
    lastCancelledTaskId = taskId;
  }

  @override
  Future<void> pauseBackgroundTransfer(String taskId) async {
    lastPausedTaskId = taskId;
  }

  @override
  Future<void> resumeBackgroundTransfer(String taskId) async {}
}

class _RecordingTransport implements TransferTransport {
  int uploadCalls = 0;
  int downloadCalls = 0;

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    uploadCalls++;
    onStatusChanged(TransferStatus.completed);
    return const S3UploadResult(bytesTransferred: 100);
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    downloadCalls++;
    onStatusChanged(TransferStatus.completed);
    return const S3DownloadResult(
      destinationPath: '/dest/file',
      bytesTransferred: 100,
    );
  }
}

void main() {
  late Directory tempDir;
  late File testFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_bg_test_');
    testFile = File('${tempDir.path}/test_upload.dat');
    await testFile.writeAsString('native background test content');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('NativeBackgroundTransport', () {
    test(
      'starts background upload and receives progress and completion',
      () async {
        final mockHost = _MockHostApi();
        mockHost.uploadStartedCompleter = Completer<void>();
        final transport = NativeBackgroundTransport(hostApi: mockHost);

        final progressEvents = <TransferProgress>[];
        final statuses = <TransferStatus>[];

        final uploadFuture = transport.upload(
          S3UploadRequest(
            filePath: testFile.path,
            authorization: S3Authorization.presignedUrl(
              Uri.parse('https://example.com/s3/upload'),
            ),
            contentType: 'text/plain',
          ),
          onProgress: progressEvents.add,
          onStatusChanged: statuses.add,
        );

        await mockHost.uploadStartedCompleter!.future;

        // Verify native request was dispatched
        expect(mockHost.lastUploadRequest, isNotNull);
        final taskId = mockHost.lastUploadRequest!.taskId;
        expect(mockHost.lastUploadRequest!.filePath, equals(testFile.path));
        expect(
          mockHost.lastUploadRequest!.url,
          equals('https://example.com/s3/upload'),
        );

        // Simulate native platform progress callback
        transport.onTransferProgress(
          NativeTransferProgressUpdate(
            taskId: taskId,
            bytesTransferred: 15,
            totalBytes: 30,
          ),
        );

        expect(progressEvents.last.bytesTransferred, equals(15));
        expect(progressEvents.last.totalBytes, equals(30));

        // Simulate native platform completion callback
        transport.onTransferStateChanged(
          NativeTransferStateUpdate(
            taskId: taskId,
            status: 'completed',
            eTag: 'native_etag_abc',
            httpStatusCode: 200,
          ),
        );

        final result = await uploadFuture;
        expect(result.eTag, equals('native_etag_abc'));
        expect(statuses, contains(TransferStatus.completed));
      },
    );

    test('starts background download and receives completion', () async {
      final mockHost = _MockHostApi();
      mockHost.downloadStartedCompleter = Completer<void>();
      final transport = NativeBackgroundTransport(hostApi: mockHost);

      final downloadDest = '${tempDir.path}/downloaded.dat';
      final statuses = <TransferStatus>[];

      final downloadFuture = transport.download(
        S3DownloadRequest(
          destinationPath: downloadDest,
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/s3/download'),
          ),
        ),
        onProgress: (_) {},
        onStatusChanged: statuses.add,
      );

      await mockHost.downloadStartedCompleter!.future;

      expect(mockHost.lastDownloadRequest, isNotNull);
      final taskId = mockHost.lastDownloadRequest!.taskId;
      expect(
        mockHost.lastDownloadRequest!.destinationPath,
        equals(downloadDest),
      );

      // Simulate completion
      transport.onTransferStateChanged(
        NativeTransferStateUpdate(
          taskId: taskId,
          status: 'completed',
          eTag: 'download_etag_xyz',
          httpStatusCode: 200,
        ),
      );

      final result = await downloadFuture;
      expect(result.destinationPath, equals(downloadDest));
      expect(result.eTag, equals('download_etag_xyz'));
      expect(statuses, contains(TransferStatus.completed));
    });

    test(
      'cancels background transfer when cancellation token is triggered',
      () async {
        final mockHost = _MockHostApi();
        mockHost.uploadStartedCompleter = Completer<void>();
        final transport = NativeBackgroundTransport(hostApi: mockHost);

        final token = CancellationToken();
        final uploadFuture = transport.upload(
          S3UploadRequest(
            filePath: testFile.path,
            authorization: S3Authorization.presignedUrl(
              Uri.parse('https://example.com/s3/upload'),
            ),
            cancellationToken: token,
          ),
          onProgress: (_) {},
          onStatusChanged: (_) {},
        );

        await mockHost.uploadStartedCompleter!.future;

        final taskId = mockHost.lastUploadRequest!.taskId;
        token.cancel('User requested cancel');

        expect(mockHost.lastCancelledTaskId, equals(taskId));

        // Simulate native state update from cancel
        transport.onTransferStateChanged(
          NativeTransferStateUpdate(
            taskId: taskId,
            status: 'cancelled',
            error: 'User requested cancel',
          ),
        );

        expect(
          () => uploadFuture,
          throwsA(
            isA<TransferException>().having(
              (e) => e.code,
              'code',
              equals(TransferErrorCode.cancelled),
            ),
          ),
        );
      },
    );

    test('maps native failure state to TransferException', () async {
      final mockHost = _MockHostApi();
      mockHost.uploadStartedCompleter = Completer<void>();
      final transport = NativeBackgroundTransport(hostApi: mockHost);

      final uploadFuture = transport.upload(
        S3UploadRequest(
          filePath: testFile.path,
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/s3/upload'),
          ),
        ),
        onProgress: (_) {},
        onStatusChanged: (_) {},
      );

      await mockHost.uploadStartedCompleter!.future;

      final taskId = mockHost.lastUploadRequest!.taskId;

      // Simulate HTTP 403 Expired Token failure
      transport.onTransferStateChanged(
        NativeTransferStateUpdate(
          taskId: taskId,
          status: 'failed',
          httpStatusCode: 403,
          error: 'AccessDenied: Request has expired',
        ),
      );

      expect(
        () => uploadFuture,
        throwsA(
          isA<TransferException>()
              .having(
                (e) => e.code,
                'code',
                equals(TransferErrorCode.authenticationExpired),
              )
              .having((e) => e.httpStatusCode, 'httpStatusCode', equals(403)),
        ),
      );
    });

    test(
      'falls back to foreground transport when background is unsupported',
      () async {
        final mockHost = _MockHostApi()..supported = false;
        final fallback = _RecordingTransport();
        final transport = NativeBackgroundTransport(
          hostApi: mockHost,
          fallbackTransport: fallback,
        );

        final result = await transport.upload(
          S3UploadRequest(
            filePath: testFile.path,
            authorization: S3Authorization.presignedUrl(
              Uri.parse('https://example.com/s3/upload'),
            ),
          ),
          onProgress: (_) {},
          onStatusChanged: (_) {},
        );

        expect(fallback.uploadCalls, equals(1));
        expect(result.bytesTransferred, equals(100));
      },
    );
  });

  group('TransferExecutionMode Routing in TransferManager', () {
    test('routes foregroundOnly to standard transport and allowBackground to background transport', () async {
      final foregroundTransport = _RecordingTransport();
      final backgroundTransport = _RecordingTransport();

      final manager = TransferManager(
        transport: foregroundTransport,
        backgroundTransport: backgroundTransport,
      );

      // 1. Foreground default request
      final fgTask = manager.enqueueUpload(
        S3UploadRequest(
          filePath: testFile.path,
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/fg'),
          ),
          executionMode: TransferExecutionMode.foregroundOnly,
        ),
      );
      await fgTask.result;

      expect(foregroundTransport.uploadCalls, equals(1));
      expect(backgroundTransport.uploadCalls, equals(0));

      // 2. Background opt-in request
      final bgTask = manager.enqueueUpload(
        S3UploadRequest(
          filePath: testFile.path,
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/bg'),
          ),
          executionMode: TransferExecutionMode.allowBackground,
        ),
      );
      await bgTask.result;

      expect(foregroundTransport.uploadCalls, equals(1));
      expect(backgroundTransport.uploadCalls, equals(1));

      // 3. Download routing
      final fgDown = manager.enqueueDownload(
        S3DownloadRequest(
          destinationPath: '${tempDir.path}/fg.dat',
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/fg_down'),
          ),
          executionMode: TransferExecutionMode.foregroundOnly,
        ),
      );
      await fgDown.result;

      final bgDown = manager.enqueueDownload(
        S3DownloadRequest(
          destinationPath: '${tempDir.path}/bg.dat',
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/bg_down'),
          ),
          executionMode: TransferExecutionMode.allowBackground,
        ),
      );
      await bgDown.result;

      expect(foregroundTransport.downloadCalls, equals(1));
      expect(backgroundTransport.downloadCalls, equals(1));

      await manager.dispose();
    });
  });
}
