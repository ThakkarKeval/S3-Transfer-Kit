import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

class FakeTransport implements TransferTransport {
  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    onStatusChanged(TransferStatus.inProgress);
    onProgress(const TransferProgress(bytesTransferred: 100, totalBytes: 100));
    onStatusChanged(TransferStatus.completed);
    return const S3UploadResult(bytesTransferred: 100, eTag: 'etag_single');
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    onStatusChanged(TransferStatus.inProgress);
    onProgress(const TransferProgress(bytesTransferred: 250, totalBytes: 250));
    onStatusChanged(TransferStatus.completed);
    return const S3DownloadResult(
      destinationPath: '/dest/file.dat',
      bytesTransferred: 250,
      eTag: 'etag_down',
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('s3_persistence_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PersistentTransferRecord', () {
    test('serializes to and from JSON correctly', () {
      final now = DateTime.now();
      final record = PersistentTransferRecord(
        id: 'test_task_1',
        type: TransferType.multipartUpload,
        status: TransferStatus.inProgress,
        filePath: '/tmp/test.dat',
        fileLength: 10485760,
        createdAt: now,
        updatedAt: now,
        contentType: 'application/octet-stream',
        uploadId: 'upload_123',
        partSize: 5242880,
        completedParts: const [
          S3PartETag(partNumber: 1, eTag: 'etag1'),
          S3PartETag(partNumber: 2, eTag: 'etag2'),
        ],
        metadata: {'customKey': 'customVal'},
      );

      final json = record.toJson();
      final restored = PersistentTransferRecord.fromJson(json);

      expect(restored.id, equals(record.id));
      expect(restored.type, equals(TransferType.multipartUpload));
      expect(restored.status, equals(TransferStatus.inProgress));
      expect(restored.filePath, equals(record.filePath));
      expect(restored.fileLength, equals(record.fileLength));
      expect(
        restored.createdAt.millisecondsSinceEpoch,
        equals(record.createdAt.millisecondsSinceEpoch),
      );
      expect(restored.uploadId, equals('upload_123'));
      expect(restored.partSize, equals(5242880));
      expect(restored.completedParts.length, equals(2));
      expect(restored.completedParts[0].partNumber, equals(1));
      expect(restored.completedParts[0].eTag, equals('etag1'));
      expect(restored.completedParts[1].partNumber, equals(2));
      expect(restored.completedParts[1].eTag, equals('etag2'));
      expect(restored.metadata['customKey'], equals('customVal'));
      expect(restored.isActive, isTrue);
    });

    test('isActive returns false for terminal states', () {
      final now = DateTime.now();
      for (final status in [
        TransferStatus.completed,
        TransferStatus.failed,
        TransferStatus.cancelled,
      ]) {
        final record = PersistentTransferRecord(
          id: 'test_terminal',
          type: TransferType.singleUpload,
          status: status,
          filePath: '/tmp/f.dat',
          fileLength: 100,
          createdAt: now,
          updatedAt: now,
        );
        expect(record.isActive, isFalse);
      }
    });
  });

  group('InMemoryTransferStore', () {
    test('supports save, get, getAll, getActive, delete, and clear', () async {
      final store = InMemoryTransferStore();
      final now = DateTime.now();

      final record1 = PersistentTransferRecord(
        id: 't1',
        type: TransferType.singleUpload,
        status: TransferStatus.inProgress,
        filePath: '/tmp/file1',
        fileLength: 100,
        createdAt: now,
        updatedAt: now,
      );

      final record2 = PersistentTransferRecord(
        id: 't2',
        type: TransferType.download,
        status: TransferStatus.completed,
        filePath: '/tmp/file2',
        fileLength: 200,
        createdAt: now,
        updatedAt: now,
      );

      await store.save(record1);
      await store.save(record2);

      expect((await store.get('t1'))?.filePath, equals('/tmp/file1'));
      expect((await store.get('t2'))?.filePath, equals('/tmp/file2'));
      expect((await store.getAll()).length, equals(2));
      expect((await store.getActive()).length, equals(1));
      expect((await store.getActive()).first.id, equals('t1'));

      await store.delete('t1');
      expect(await store.get('t1'), isNull);
      expect((await store.getAll()).length, equals(1));

      await store.clear();
      expect((await store.getAll()).isEmpty, isTrue);
    });
  });

  group('FileTransferStore', () {
    test('persists records atomically across re-instantiation', () async {
      final storeDir = Directory('${tempDir.path}/records');
      final store1 = FileTransferStore(storeDir);
      final now = DateTime.now();

      final record = PersistentTransferRecord(
        id: 'mp_task_42',
        type: TransferType.multipartUpload,
        status: TransferStatus.inProgress,
        filePath: '/tmp/data.bin',
        fileLength: 15000000,
        createdAt: now,
        updatedAt: now,
        uploadId: 'aws_up_id_99',
        partSize: 5242880,
        completedParts: const [S3PartETag(partNumber: 1, eTag: 'etag_alpha')],
      );

      await store1.save(record);

      // Re-instantiate store pointing to same directory
      final store2 = FileTransferStore(storeDir);
      final retrieved = await store2.get('mp_task_42');

      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals('mp_task_42'));
      expect(retrieved.uploadId, equals('aws_up_id_99'));
      expect(retrieved.completedParts.length, equals(1));
      expect(retrieved.completedParts.first.eTag, equals('etag_alpha'));

      // Update record with second part
      final updated = retrieved.copyWith(
        completedParts: [
          ...retrieved.completedParts,
          const S3PartETag(partNumber: 2, eTag: 'etag_beta'),
        ],
      );
      await store2.save(updated);

      final retrieved2 = await store2.get('mp_task_42');
      expect(retrieved2!.completedParts.length, equals(2));

      await store2.delete('mp_task_42');
      expect(await store2.get('mp_task_42'), isNull);
    });

    test('ignores corrupted json files gracefully', () async {
      final storeDir = Directory('${tempDir.path}/corrupt_records');
      await storeDir.create(recursive: true);

      // Write corrupt file
      final corruptFile = File('${storeDir.path}/bad.json');
      await corruptFile.writeAsString('{ invalid_json: ');

      final store = FileTransferStore(storeDir);
      final all = await store.getAll();
      expect(all, isEmpty);
      expect(await store.get('bad'), isNull);
    });
  });

  group('Multipart Upload Resumption', () {
    late HttpServer server;
    late Uri serverUri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverUri = Uri.parse('http://${server.address.host}:${server.port}');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('resumes multipart upload by skipping finished parts', () async {
      final requestedParts = <int>[];

      server.listen((HttpRequest request) async {
        if (request.method == 'PUT') {
          final partNum = int.parse(request.uri.pathSegments.last);
          requestedParts.add(partNum);

          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('etag', '"etag_for_part_$partNum"');
          await request.response.close();
        }
      });

      // Prepare a 12MB file (partSize = 5MB, so 3 parts: 5MB, 5MB, 2MB)
      final testFile = File('${tempDir.path}/large_test.bin');
      final totalLength = 12 * 1024 * 1024;
      final sink = testFile.openWrite();
      for (int i = 0; i < 12; i++) {
        sink.add(List<int>.filled(1024 * 1024, 65 + i));
      }
      await sink.flush();
      await sink.close();

      final store = InMemoryTransferStore();
      final coordinator = MultipartUploadCoordinator(store: store);

      bool initiateCalled = false;
      bool completeCalled = false;
      List<S3PartETag>? submittedParts;

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate:
            ({
              required String filePath,
              required int fileLength,
              required String contentType,
              Map<String, String> customHeaders = const {},
            }) async {
              initiateCalled = true;
              return 'upload_id_xyz';
            },
        onGetPartUrl:
            ({
              required String uploadId,
              required int partNumber,
              required int partLength,
            }) async {
              return serverUri.replace(path: '/part/$partNumber');
            },
        onComplete:
            ({
              required String uploadId,
              required List<S3PartETag> parts,
            }) async {
              completeCalled = true;
              submittedParts = parts;
              return S3UploadResult(
                bytesTransferred: totalLength,
                eTag: 'final_etag_123',
                responseHeaders: {},
              );
            },
        onAbort: ({required String uploadId}) async {},
      );

      // Simulate a prior interrupted state where Part 1 already completed
      final priorRecord = PersistentTransferRecord(
        id: 'interrupted_task_1',
        type: TransferType.multipartUpload,
        status: TransferStatus.inProgress,
        filePath: testFile.path,
        fileLength: totalLength,
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        uploadId: 'upload_id_xyz',
        partSize: 5 * 1024 * 1024,
        completedParts: const [
          S3PartETag(partNumber: 1, eTag: 'etag_for_part_1'),
        ],
      );
      await store.save(priorRecord);

      final progressEvents = <TransferProgress>[];
      final statuses = <TransferStatus>[];

      final request = S3MultipartUploadRequest(
        filePath: testFile.path,
        provider: provider,
        partSize: 5 * 1024 * 1024,
      );

      final result = await coordinator.upload(
        request,
        taskId: 'interrupted_task_1',
        resumeRecord: priorRecord,
        onProgress: progressEvents.add,
        onStatusChanged: statuses.add,
      );

      // Verify initiate was NOT called again since we resumed existing uploadId
      expect(initiateCalled, isFalse);
      expect(completeCalled, isTrue);
      expect(result.eTag, equals('final_etag_123'));

      // Verify that Part 1 was SKIPPED and only Parts 2 and 3 were uploaded!
      expect(requestedParts, containsAll([2, 3]));
      expect(requestedParts.contains(1), isFalse);

      // Verify that complete was called with ALL 3 parts sorted
      expect(submittedParts?.length, equals(3));
      expect(submittedParts?[0].partNumber, equals(1));
      expect(submittedParts?[0].eTag, equals('etag_for_part_1'));
      expect(submittedParts?[1].partNumber, equals(2));
      expect(submittedParts?[1].eTag, equals('etag_for_part_2'));
      expect(submittedParts?[2].partNumber, equals(3));
      expect(submittedParts?[2].eTag, equals('etag_for_part_3'));

      // Verify progress started with initial 5MB from part 1
      expect(progressEvents.first.bytesTransferred, equals(5 * 1024 * 1024));
      expect(progressEvents.last.bytesTransferred, equals(totalLength));

      // Verify record is marked completed in store
      final finalRecord = await store.get('interrupted_task_1');
      expect(finalRecord?.status, equals(TransferStatus.completed));
      expect(finalRecord?.completedParts.length, equals(3));
    });

    test('fails to resume if local file size changed', () async {
      final testFile = File('${tempDir.path}/modified_test.bin');
      await testFile.writeAsString('small content');

      final store = InMemoryTransferStore();
      final coordinator = MultipartUploadCoordinator(store: store);

      final priorRecord = PersistentTransferRecord(
        id: 'modified_task',
        type: TransferType.multipartUpload,
        status: TransferStatus.inProgress,
        filePath: testFile.path,
        fileLength: 10485760, // Recorded as 10MB, but current file is small
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        uploadId: 'up_123',
        partSize: 5242880,
      );

      final provider = S3MultipartProvider.fromCallbacks(
        onInitiate: ({
          required String filePath,
          required int fileLength,
          required String contentType,
          Map<String, String> customHeaders = const {},
        }) async => 'up_123',
        onGetPartUrl: ({
          required String uploadId,
          required int partNumber,
          required int partLength,
        }) async => serverUri,
        onComplete: ({
          required String uploadId,
          required List<S3PartETag> parts,
        }) async => const S3UploadResult(bytesTransferred: 0),
        onAbort: ({required String uploadId}) async {},
      );

      final request = S3MultipartUploadRequest(
        filePath: testFile.path,
        provider: provider,
      );

      expect(
        () => coordinator.upload(
          request,
          taskId: 'modified_task',
          resumeRecord: priorRecord,
          onProgress: (_) {},
          onStatusChanged: (_) {},
        ),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            equals(TransferErrorCode.fileValidationFailed),
          ),
        ),
      );
    });
  });

  group('TransferManager Persistence & Recovery', () {
    test(
      'getPendingTransfers, resumeMultipartUpload, and cleanOrphanedTransfers',
      () async {
        final store = InMemoryTransferStore();
        final manager = TransferManager(transferStore: store);

        final testFile = File('${tempDir.path}/tm_test.bin');
        await testFile.writeAsBytes(List<int>.filled(6 * 1024 * 1024, 42));

        bool abortCalled = false;
        final provider = S3MultipartProvider.fromCallbacks(
          onInitiate: ({
            required String filePath,
            required int fileLength,
            required String contentType,
            Map<String, String> customHeaders = const {},
          }) async => 'up_tm',
          onGetPartUrl: ({
            required String uploadId,
            required int partNumber,
            required int partLength,
          }) async => Uri.parse('http://localhost:9999'),
          onComplete: ({
            required String uploadId,
            required List<S3PartETag> parts,
          }) async => const S3UploadResult(bytesTransferred: 0),
          onAbort: ({required String uploadId}) async {
            abortCalled = true;
          },
        );

        // Save an old orphaned record (> 2 days old)
        final oldRecord = PersistentTransferRecord(
          id: 'orphaned_1',
          type: TransferType.multipartUpload,
          status: TransferStatus.failed,
          filePath: testFile.path,
          fileLength: 6 * 1024 * 1024,
          createdAt: DateTime.now().subtract(const Duration(days: 3)),
          updatedAt: DateTime.now().subtract(const Duration(days: 3)),
          uploadId: 'up_orphaned',
        );
        await store.save(oldRecord);

        // Save an active resumable record (10 minutes old)
        final activeRecord = PersistentTransferRecord(
          id: 'active_1',
          type: TransferType.multipartUpload,
          status: TransferStatus.inProgress,
          filePath: testFile.path,
          fileLength: 6 * 1024 * 1024,
          createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
          updatedAt: DateTime.now().subtract(const Duration(minutes: 10)),
          uploadId: 'up_active',
          partSize: 5242880,
        );
        await store.save(activeRecord);

        // 1. Check getPendingTransfers
        final pending = await manager.getPendingTransfers();
        expect(pending.length, equals(1));
        expect(pending.first.id, equals('active_1'));

        // 2. Clean orphaned transfers older than 1 day
        final cleanedCount = await manager.cleanOrphanedTransfers(
          olderThan: const Duration(days: 1),
          provider: provider,
        );
        expect(cleanedCount, equals(1));
        expect(abortCalled, isTrue);
        expect(await store.get('orphaned_1'), isNull);
        expect(await store.get('active_1'), isNotNull);

        await manager.dispose();
      },
    );

    test('persists single upload and download lifecycles via facade', () async {
      final store = InMemoryTransferStore();
      final transport = FakeTransport();
      final kit = S3TransferKit(transport: transport, transferStore: store);

      final testFile = File('${tempDir.path}/single_test.bin');
      await testFile.writeAsString('hello single upload');

      final uploadTask = kit.upload(
        S3UploadRequest(
          filePath: testFile.path,
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/put'),
          ),
        ),
      );
      final uploadResult = await uploadTask.result;
      expect(uploadResult.eTag, equals('etag_single'));

      // Check store has completed upload record
      final all = await store.getAll();
      final uploadRecord = all.firstWhere(
        (r) => r.type == TransferType.singleUpload,
      );
      expect(uploadRecord.status, equals(TransferStatus.completed));
      expect(uploadRecord.filePath, equals(testFile.path));

      final downloadTask = kit.download(
        S3DownloadRequest(
          destinationPath: '/dest/file.dat',
          authorization: S3Authorization.presignedUrl(
            Uri.parse('https://example.com/get'),
          ),
        ),
      );
      final downloadResult = await downloadTask.result;
      expect(downloadResult.bytesTransferred, equals(250));

      final allAfter = await store.getAll();
      final downloadRecord = allAfter.firstWhere(
        (r) => r.type == TransferType.download,
      );
      expect(downloadRecord.status, equals(TransferStatus.completed));
      expect(downloadRecord.fileLength, equals(250));

      await kit.dispose();
    });
  });
}
