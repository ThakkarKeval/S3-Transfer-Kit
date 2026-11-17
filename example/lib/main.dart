import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  runApp(const S3TransferKitExampleApp());
}

class S3TransferKitExampleApp extends StatelessWidget {
  const S3TransferKitExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'S3 Transfer Kit Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE27D60),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE27D60),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TransferKitDashboardScreen(),
    );
  }
}

class TransferKitDashboardScreen extends StatefulWidget {
  const TransferKitDashboardScreen({super.key});

  @override
  State<TransferKitDashboardScreen> createState() =>
      _TransferKitDashboardScreenState();
}

class _TransferKitDashboardScreenState
    extends State<TransferKitDashboardScreen> {
  late final S3TransferKit _s3;
  HttpServer? _localServer;
  Uri? _localServerUrl;

  String _platformVersion = 'Checking...';
  bool _backgroundSupported = false;

  TransferQueueSnapshot _snapshot = const TransferQueueSnapshot(
    queuedCount: 0,
    runningCount: 0,
    isPaused: false,
  );

  final List<String> _eventLogs = [];
  final ScrollController _logScrollController = ScrollController();

  // Active single upload task state
  S3UploadTask? _activeUploadTask;
  double _uploadProgress = 0.0;
  String _uploadStatus = 'Idle';

  // Active multipart upload task state
  S3UploadTask? _activeMultipartTask;
  double _multipartProgress = 0.0;
  String _multipartStatus = 'Idle';

  // Active download task state
  S3DownloadTask? _activeDownloadTask;
  double _downloadProgress = 0.0;
  String _downloadStatus = 'Idle';

  @override
  void initState() {
    super.initState();
    _s3 = S3TransferKit(
      configuration: const TransferQueueConfiguration(
        maxConcurrentTransfers: 3,
        defaultPriority: TransferPriority.normal,
      ),
      transferStore: InMemoryTransferStore(),
    );

    _s3.snapshotStream.listen((snapshot) {
      if (mounted) {
        setState(() => _snapshot = snapshot);
      }
    });

    _initializeEnvironment();
  }

  Future<void> _initializeEnvironment() async {
    try {
      final version = await _s3.getPlatformVersion() ?? 'Unknown';
      final bgSupported = await _s3.isBackgroundTransferSupported();

      // Launch local loopback HTTP server to safely handle demo uploads/downloads
      _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localServerUrl = Uri.parse(
        'http://${_localServer!.address.host}:${_localServer!.port}',
      );

      _localServer!.listen((HttpRequest request) async {
        if (request.method == 'PUT') {
          await request.drain<void>();
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('etag', '"demo-etag-12345"');
          await request.response.close();
        } else if (request.method == 'GET') {
          final dummyBytes = Uint8List(512 * 1024); // 512KB payload
          request.response.statusCode = HttpStatus.ok;
          request.response.contentLength = dummyBytes.length;
          request.response.add(dummyBytes);
          await request.response.close();
        }
      });

      if (mounted) {
        setState(() {
          _platformVersion = version;
          _backgroundSupported = bgSupported;
        });
        _log('Initialized local demo server on $_localServerUrl');
      }
    } catch (e) {
      _log('Init error: $e');
    }
  }

  @override
  void dispose() {
    _localServer?.close(force: true);
    _s3.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _eventLogs.insert(0, '[$timestamp] $message');
      if (_eventLogs.length > 100) {
        _eventLogs.removeLast();
      }
    });
  }

  Future<File> _createSampleFile(String name, int sizeBytes) async {
    final tempDir = await Directory.systemTemp.createTemp('s3_sample_');
    final file = File('${tempDir.path}/$name');
    final sink = file.openWrite();
    final chunk = Uint8List(65536);
    int written = 0;
    while (written < sizeBytes) {
      final len = (sizeBytes - written) > 65536 ? 65536 : (sizeBytes - written);
      sink.add(chunk.sublist(0, len));
      written += len;
    }
    await sink.flush();
    await sink.close();
    return file;
  }

  Future<void> _startSingleUpload() async {
    if (_localServerUrl == null) return;
    _log('Preparing 1MB sample file for upload...');

    final sampleFile = await _createSampleFile(
      'single_upload.bin',
      1024 * 1024,
    );
    final targetUrl = _localServerUrl!.resolve('/upload');

    final task = _s3.upload(
      S3UploadRequest.fromPresignedUrl(
        filePath: sampleFile.path,
        uploadUrl: targetUrl,
        contentType: 'application/octet-stream',
      ),
    );

    setState(() {
      _activeUploadTask = task;
      _uploadProgress = 0.0;
      _uploadStatus = 'Uploading...';
    });

    task.progress.listen((progress) {
      if (mounted) {
        setState(() => _uploadProgress = progress.fraction);
      }
    });

    try {
      final result = await task.result;
      _log('Single upload finished! ETag: ${result.eTag}');
      if (mounted) {
        setState(() => _uploadStatus = 'Completed (ETag: ${result.eTag})');
      }
    } catch (e) {
      _log('Single upload error: $e');
      if (mounted) {
        setState(() => _uploadStatus = 'Failed: $e');
      }
    }
  }

  Future<void> _startSingleDownload() async {
    if (_localServerUrl == null) return;
    _log('Initiating download from local demo server...');

    final tempDir = await Directory.systemTemp.createTemp('s3_download_');
    final destFile = File('${tempDir.path}/downloaded.bin');
    final downloadUrl = _localServerUrl!.resolve('/download');

    final task = _s3.download(
      S3DownloadRequest.fromPresignedUrl(
        downloadUrl: downloadUrl,
        destinationPath: destFile.path,
        overwrite: true,
      ),
    );

    setState(() {
      _activeDownloadTask = task;
      _downloadProgress = 0.0;
      _downloadStatus = 'Downloading...';
    });

    task.progress.listen((progress) {
      if (mounted) {
        setState(() => _downloadProgress = progress.fraction);
      }
    });

    try {
      final result = await task.result;
      _log('Download completed! Size: ${result.bytesTransferred} bytes');
      if (mounted) {
        setState(
          () =>
              _downloadStatus = 'Completed (${result.bytesTransferred} bytes)',
        );
      }
    } catch (e) {
      _log('Download error: $e');
      if (mounted) {
        setState(() => _downloadStatus = 'Failed: $e');
      }
    }
  }

  Future<void> _startMultipartUpload() async {
    if (_localServerUrl == null) return;
    _log('Generating 15MB file for multipart test (3 x 5MB parts)...');

    final sampleFile = await _createSampleFile(
      'multipart_file.bin',
      15 * 1024 * 1024,
    );

    final provider = S3MultipartProvider.fromCallbacks(
      onInitiate:
          ({
            required filePath,
            required fileLength,
            required contentType,
            customHeaders = const {},
          }) async {
            _log('Multipart: Initiating upload ID...');
            return 'demo-multipart-id-${DateTime.now().millisecondsSinceEpoch}';
          },
      onGetPartUrl:
          ({
            required uploadId,
            required partNumber,
            required partLength,
          }) async {
            _log('Multipart: Requesting URL for Part $partNumber...');
            return _localServerUrl!.resolve('/part_$partNumber');
          },
      onComplete: ({required uploadId, required parts}) async {
        _log('Multipart: Assembling and completing ${parts.length} parts...');
        return S3UploadResult(
          bytesTransferred: 15 * 1024 * 1024,
          eTag: 'completed-multipart-etag',
        );
      },
      onAbort: ({required uploadId}) async {
        _log('Multipart: Aborted upload $uploadId');
      },
    );

    final task = _s3.uploadMultipart(
      S3MultipartUploadRequest(
        filePath: sampleFile.path,
        provider: provider,
        partSize: 5 * 1024 * 1024,
        maxConcurrentParts: 2,
      ),
    );

    setState(() {
      _activeMultipartTask = task;
      _multipartProgress = 0.0;
      _multipartStatus = 'Multipart in-progress...';
    });

    task.progress.listen((progress) {
      if (mounted) {
        setState(() => _multipartProgress = progress.fraction);
      }
    });

    try {
      final result = await task.result;
      _log('Multipart upload complete! ETag: ${result.eTag}');
      if (mounted) {
        setState(() => _multipartStatus = 'Completed (ETag: ${result.eTag})');
      }
    } catch (e) {
      _log('Multipart error: $e');
      if (mounted) {
        setState(() => _multipartStatus = 'Failed: $e');
      }
    }
  }

  Future<void> _enqueuePriorityBatch() async {
    if (_localServerUrl == null) return;
    _log('Enqueuing 9 transfers across High, Normal, and Low priorities...');

    final sampleFile = await _createSampleFile('batch_item.bin', 256 * 1024);
    final uploadUrl = _localServerUrl!.resolve('/batch');

    for (int i = 1; i <= 9; i++) {
      final TransferPriority priority;
      if (i <= 3) {
        priority = TransferPriority.high;
      } else if (i <= 6) {
        priority = TransferPriority.normal;
      } else {
        priority = TransferPriority.low;
      }

      final task = _s3.upload(
        S3UploadRequest.fromPresignedUrl(
          filePath: sampleFile.path,
          uploadUrl: uploadUrl,
          priority: priority,
        ),
      );

      task.result
          .then((_) {
            _log('Task #$i (${priority.name.toUpperCase()}) completed');
          })
          .catchError((error) {
            _log('Task #$i failed: $error');
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('S3 Transfer Kit'),
        actions: [
          IconButton(
            icon: Icon(_snapshot.isPaused ? Icons.play_arrow : Icons.pause),
            tooltip: _snapshot.isPaused ? 'Resume All' : 'Pause All',
            onPressed: () {
              if (_snapshot.isPaused) {
                _s3.resumeAll();
                _log('Queue resumed');
              } else {
                _s3.pauseAll();
                _log('Queue paused');
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.cancel_outlined),
            tooltip: 'Cancel All',
            onPressed: () {
              _s3.cancelAll('User requested bulk cancellation');
              _log('Bulk cancellation issued');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Queue & System Metric Cards
          Container(
            padding: const EdgeInsets.all(12),
            color: theme.colorScheme.surfaceContainerHighest.withAlpha(80),
            child: Row(
              children: [
                _buildMetricTile(
                  'Running',
                  '${_snapshot.runningCount}',
                  Icons.trending_up,
                  Colors.blue,
                ),
                _buildMetricTile(
                  'Queued',
                  '${_snapshot.queuedCount}',
                  Icons.queue,
                  Colors.orange,
                ),
                _buildMetricTile(
                  'State',
                  _snapshot.isPaused ? 'Paused' : 'Active',
                  Icons.speed,
                  _snapshot.isPaused ? Colors.red : Colors.green,
                ),
                _buildMetricTile(
                  'Background',
                  _backgroundSupported ? 'Native' : 'Fallback',
                  Icons.cloud_sync,
                  Colors.purple,
                ),
              ],
            ),
          ),

          // Main Action List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Single Upload Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Single-File Upload (1MB)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              _uploadStatus,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _uploadProgress),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _startSingleUpload,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Upload'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: _activeUploadTask != null
                                  ? () {
                                      _activeUploadTask!.cancel(
                                        'User cancelled',
                                      );
                                      _log('Single upload cancelled');
                                    }
                                  : null,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Multipart Upload Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'S3 Multipart Upload (15MB)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              _multipartStatus,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _multipartProgress),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _startMultipartUpload,
                              icon: const Icon(Icons.cloud_upload),
                              label: const Text('Start Multipart'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: _activeMultipartTask != null
                                  ? () {
                                      _activeMultipartTask!.cancel(
                                        'User cancelled multipart',
                                      );
                                      _log('Multipart upload cancelled');
                                    }
                                  : null,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Single Download Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Two-Phase Atomic Download',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              _downloadStatus,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: _downloadProgress),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _startSingleDownload,
                              icon: const Icon(Icons.download),
                              label: const Text('Download'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: _activeDownloadTask != null
                                  ? () {
                                      _activeDownloadTask!.cancel(
                                        'User cancelled download',
                                      );
                                      _log('Download cancelled');
                                    }
                                  : null,
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Priority Queue Stress Demo Card
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Priority Queue Scheduler Demo',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Enqueues 9 mixed-priority tasks (3 High, 3 Normal, 3 Low). High priority tasks schedule first.',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: _enqueuePriorityBatch,
                          icon: const Icon(Icons.low_priority),
                          label: const Text('Enqueue Batch (9 Tasks)'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Event Log Terminal at bottom
          Container(
            height: 140,
            padding: const EdgeInsets.all(8),
            color: Colors.black.withAlpha(220),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Live Event Log (Platform: $_platformVersion)',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => _eventLogs.clear()),
                      child: const Text(
                        'Clear',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24, height: 8),
                Expanded(
                  child: ListView.builder(
                    controller: _logScrollController,
                    reverse: true,
                    itemCount: _eventLogs.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _eventLogs[index],
                        style: const TextStyle(
                          color: Colors.lightGreenAccent,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile(
    String title,
    String value,
    IconData icon,
    Color color,
  ) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          Text(title, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}
