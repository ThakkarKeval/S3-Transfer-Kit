import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

class _FakeCompleterTransport implements TransferTransport {
  final Map<String, Completer<S3UploadResult>> uploadCompleters = {};
  final List<String> executionOrder = [];
  int uploadCallCount = 0;

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    uploadCallCount++;
    executionOrder.add(request.filePath);
    onStatusChanged(TransferStatus.inProgress);

    final completer = Completer<S3UploadResult>();
    uploadCompleters[request.filePath] = completer;

    request.cancellationToken?.onCancelled(() {
      if (!completer.isCompleted) {
        onStatusChanged(TransferStatus.cancelled);
        completer.completeError(
          TransferException.cancelled(
            reason: request.cancellationToken?.reason,
          ),
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

void main() {
  group('TransferQueue & Concurrency Limiting', () {
    test('enforces maxConcurrentTransfers limit', () async {
      final fakeTransport = _FakeCompleterTransport();
      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 2,
        ),
        transport: fakeTransport,
      );

      final task1 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'file1',
          uploadUrl: Uri.parse('https://s3.example.com/1'),
        ),
      );
      final task2 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'file2',
          uploadUrl: Uri.parse('https://s3.example.com/2'),
        ),
      );
      final task3 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'file3',
          uploadUrl: Uri.parse('https://s3.example.com/3'),
        ),
      );

      // Allow microtasks to settle
      await Future<void>.delayed(Duration.zero);

      expect(manager.runningCount, equals(2));
      expect(manager.queuedCount, equals(1));
      expect(task1.status, equals(TransferStatus.inProgress));
      expect(task2.status, equals(TransferStatus.inProgress));
      expect(task3.status, equals(TransferStatus.enqueued));

      // Complete task1
      fakeTransport.uploadCompleters['file1']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task1.result;

      // task3 should now be running
      await Future<void>.delayed(Duration.zero);
      expect(manager.runningCount, equals(2));
      expect(manager.queuedCount, equals(0));
      expect(task3.status, equals(TransferStatus.inProgress));

      // Complete task2 and task3
      fakeTransport.uploadCompleters['file2']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      fakeTransport.uploadCompleters['file3']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await Future.wait([task2.result, task3.result]);

      expect(manager.runningCount, equals(0));
      expect(manager.queuedCount, equals(0));
      expect(fakeTransport.executionOrder, equals(['file1', 'file2', 'file3']));

      await manager.dispose();
    });

    test(
      'schedules high priority tasks before normal and low priority',
      () async {
        final fakeTransport = _FakeCompleterTransport();
        final manager = TransferManager(
          configuration: const TransferQueueConfiguration(
            maxConcurrentTransfers: 1,
          ),
          transport: fakeTransport,
        );

        // Task 1 occupies the single running slot
        final task1 = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: 'task1_running',
            uploadUrl: Uri.parse('https://s3.example.com/1'),
          ),
        );

        // Enqueue low, normal, and high tasks while slot is occupied
        final taskLow = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: 'task_low',
            uploadUrl: Uri.parse('https://s3.example.com/low'),
            priority: TransferPriority.low,
          ),
        );
        final taskNormal = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: 'task_normal',
            uploadUrl: Uri.parse('https://s3.example.com/normal'),
            priority: TransferPriority.normal,
          ),
        );
        final taskHigh = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: 'task_high',
            uploadUrl: Uri.parse('https://s3.example.com/high'),
            priority: TransferPriority.high,
          ),
        );

        await Future<void>.delayed(Duration.zero);
        expect(manager.runningCount, equals(1));
        expect(manager.queuedCount, equals(3));

        // Complete task1 -> taskHigh should be chosen first
        fakeTransport.uploadCompleters['task1_running']!.complete(
          const S3UploadResult(bytesTransferred: 100),
        );
        await task1.result;

        await Future<void>.delayed(Duration.zero);
        expect(taskHigh.status, equals(TransferStatus.inProgress));

        // Complete taskHigh -> taskNormal should run next
        fakeTransport.uploadCompleters['task_high']!.complete(
          const S3UploadResult(bytesTransferred: 100),
        );
        await taskHigh.result;

        await Future<void>.delayed(Duration.zero);
        expect(taskNormal.status, equals(TransferStatus.inProgress));

        // Complete taskNormal -> taskLow should run last
        fakeTransport.uploadCompleters['task_normal']!.complete(
          const S3UploadResult(bytesTransferred: 100),
        );
        await taskNormal.result;

        await Future<void>.delayed(Duration.zero);
        expect(taskLow.status, equals(TransferStatus.inProgress));

        fakeTransport.uploadCompleters['task_low']!.complete(
          const S3UploadResult(bytesTransferred: 100),
        );
        await taskLow.result;

        expect(
          fakeTransport.executionOrder,
          equals(['task1_running', 'task_high', 'task_normal', 'task_low']),
        );

        await manager.dispose();
      },
    );

    test(
      'queue-level pause and resume stops and restarts scheduling',
      () async {
        final fakeTransport = _FakeCompleterTransport();
        final manager = TransferManager(
          configuration: const TransferQueueConfiguration(
            maxConcurrentTransfers: 2,
          ),
          transport: fakeTransport,
        );

        manager.pauseAll();
        expect(manager.isPaused, isTrue);

        final task1 = manager.enqueueUpload(
          S3UploadRequest.fromPresignedUrl(
            filePath: 'file_paused_1',
            uploadUrl: Uri.parse('https://s3.example.com/1'),
          ),
        );

        await Future<void>.delayed(Duration.zero);
        // Because queue is paused, task1 should not have started
        expect(manager.runningCount, equals(0));
        expect(manager.queuedCount, equals(1));
        expect(task1.status, equals(TransferStatus.enqueued));

        // Resume queue
        manager.resumeAll();
        expect(manager.isPaused, isFalse);

        await Future<void>.delayed(Duration.zero);
        expect(manager.runningCount, equals(1));
        expect(manager.queuedCount, equals(0));
        expect(task1.status, equals(TransferStatus.inProgress));

        fakeTransport.uploadCompleters['file_paused_1']!.complete(
          const S3UploadResult(bytesTransferred: 50),
        );
        await task1.result;

        await manager.dispose();
      },
    );

    test('task-level pause and resume skips paused task in queue', () async {
      final fakeTransport = _FakeCompleterTransport();
      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 1,
        ),
        transport: fakeTransport,
      );

      final task1 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task1_running',
          uploadUrl: Uri.parse('https://s3.example.com/1'),
        ),
      );
      final task2 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task2_queued',
          uploadUrl: Uri.parse('https://s3.example.com/2'),
        ),
      );
      final task3 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task3_queued',
          uploadUrl: Uri.parse('https://s3.example.com/3'),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      // Pause task2 while waiting in queue
      task2.pause();
      expect(task2.status, equals(TransferStatus.paused));

      // Complete task1
      fakeTransport.uploadCompleters['task1_running']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task1.result;

      await Future<void>.delayed(Duration.zero);
      // task3 should run next because task2 is paused!
      expect(task3.status, equals(TransferStatus.inProgress));
      expect(task2.status, equals(TransferStatus.paused));

      // Resume task2
      task2.resume();
      expect(task2.status, equals(TransferStatus.enqueued));

      fakeTransport.uploadCompleters['task3_queued']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task3.result;

      await Future<void>.delayed(Duration.zero);
      expect(task2.status, equals(TransferStatus.inProgress));

      fakeTransport.uploadCompleters['task2_queued']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task2.result;

      expect(
        fakeTransport.executionOrder,
        equals(['task1_running', 'task3_queued', 'task2_queued']),
      );

      await manager.dispose();
    });

    test('cancelling a queued task removes it from queue and fails result with cancelled error', () async {
      final fakeTransport = _FakeCompleterTransport();
      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 1,
        ),
        transport: fakeTransport,
      );

      final task1 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task1',
          uploadUrl: Uri.parse('https://s3.example.com/1'),
        ),
      );
      final task2 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task2',
          uploadUrl: Uri.parse('https://s3.example.com/2'),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      expect(manager.runningCount, equals(1));
      expect(manager.queuedCount, equals(1));

      // Cancel task2 while queued
      task2.cancel('User changed their mind');
      expect(task2.status, equals(TransferStatus.cancelled));
      expect(manager.queuedCount, equals(0));

      expect(
        () => task2.result,
        throwsA(
          isA<TransferException>()
              .having((e) => e.code, 'code', TransferErrorCode.cancelled)
              .having(
                (e) => e.message,
                'message',
                contains('User changed their mind'),
              ),
        ),
      );

      // Complete task1
      fakeTransport.uploadCompleters['task1']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task1.result;

      // No more tasks should run
      expect(manager.runningCount, equals(0));
      expect(fakeTransport.executionOrder, equals(['task1']));

      await manager.dispose();
    });

    test('cancelAll cancels both running and queued tasks', () async {
      final fakeTransport = _FakeCompleterTransport();
      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 1,
        ),
        transport: fakeTransport,
      );

      final task1 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task1',
          uploadUrl: Uri.parse('https://s3.example.com/1'),
        ),
      );
      final task2 = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'task2',
          uploadUrl: Uri.parse('https://s3.example.com/2'),
        ),
      );

      await Future<void>.delayed(Duration.zero);

      final future1 = expectLater(
        task1.result,
        throwsA(isA<TransferException>()),
      );
      final future2 = expectLater(
        task2.result,
        throwsA(isA<TransferException>()),
      );

      manager.cancelAll('Aborting all operations');

      await Future.wait([future1, future2]);

      expect(task1.status, equals(TransferStatus.cancelled));
      expect(task2.status, equals(TransferStatus.cancelled));
      expect(manager.queuedCount, equals(0));
      expect(manager.runningCount, equals(0));

      await manager.dispose();
    });

    test('snapshotStream emits updates during lifecycle transitions', () async {
      final fakeTransport = _FakeCompleterTransport();
      final manager = TransferManager(
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 1,
        ),
        transport: fakeTransport,
      );

      final snapshots = <TransferQueueSnapshot>[];
      final subscription = manager.snapshotStream.listen(snapshots.add);

      final task = manager.enqueueUpload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'file_snapshot',
          uploadUrl: Uri.parse('https://s3.example.com/snap'),
        ),
      );

      await Future<void>.delayed(Duration.zero);
      fakeTransport.uploadCompleters['file_snapshot']!.complete(
        const S3UploadResult(bytesTransferred: 100),
      );
      await task.result;

      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(snapshots.isNotEmpty, isTrue);
      // Final snapshot has 0 queued and 0 running
      expect(snapshots.last.queuedCount, equals(0));
      expect(snapshots.last.runningCount, equals(0));
      expect(snapshots.last.totalActiveCount, equals(0));

      await manager.dispose();
    });

    test('S3TransferKit delegates seamlessly to TransferManager', () async {
      final fakeTransport = _FakeCompleterTransport();
      final kit = S3TransferKit(
        transport: fakeTransport,
        configuration: const TransferQueueConfiguration(
          maxConcurrentTransfers: 2,
        ),
      );

      final task = kit.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: 'kit_upload',
          uploadUrl: Uri.parse('https://s3.example.com/kit'),
          executionMode: TransferExecutionMode.foregroundOnly,
          priority: TransferPriority.high,
        ),
      );

      expect(task.priority, equals(TransferPriority.high));
      expect(task.executionMode, equals(TransferExecutionMode.foregroundOnly));

      await Future<void>.delayed(Duration.zero);
      expect(kit.snapshot.runningCount, equals(1));

      fakeTransport.uploadCompleters['kit_upload']!.complete(
        const S3UploadResult(bytesTransferred: 256),
      );
      final result = await task.result;
      expect(result.bytesTransferred, equals(256));

      await kit.dispose();
    });
  });
}
