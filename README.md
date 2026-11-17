# s3_transfer_kit

A resilient, production-grade Flutter plugin for Amazon S3 and compatible object storage services (Cloudflare R2, MinIO, Wasabi, Backblaze B2). Engineered for high reliability, bounded memory overhead, large multipart streaming, background transfers, and network fault tolerance.

[![pub package](https://img.shields.io/pub/v/s3_transfer_kit.svg)](https://pub.dev/packages/s3_transfer_kit)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/ThakkarKeval/S3-Transfer-Kit/blob/main/LICENSE)
[![platform](https://img.shields.io/badge/platform-android%20%7C%20ios%20%7C%20macos%20%7C%20linux%20%7C%20windows-blue.svg)](https://pub.dev/packages/s3_transfer_kit)

---

## ✨ Features

- **Bounded-Memory Streaming:** Streams gigabyte-scale files in discrete 64KB chunks directly from disk. Guarantees $< 32\text{MB}$ resident heap memory regardless of file size.
- **Atomic Two-Phase Downloads:** Streams into temporary staging files (`.tmp`) and atomically renames on completion. Never leaves partial or corrupt files on disk.
- **S3 Multipart Uploads:** Compliant with Amazon S3 specifications ($\ge 5\text{MB}$ minimum part size). Slices files on demand, uploads parts in parallel, collects ETags, and completes or aborts cleanly.
- **Persistent Transfer Resumption:** Survives application restarts and crashes. Automatically skips already-completed parts on resume, verifies local file integrity, and cleans orphaned records.
- **Managed Priority Queue:** Global concurrency limiter (`TransferQueueConfiguration.maxConcurrentTransfers`) with priority scheduling (`TransferPriority.high` > `normal` > `low`) and broadcast state snapshots.
- **Resilient Retry & Backoff:** `RetryPolicy.standard` with exponential backoff and randomized full jitter to eliminate thundering herd contention. Differentiates transient network drops from permanent 4xx errors.
- **Native Background Transfers:** Opt-in background execution on Android (thread pool) and iOS/macOS (`URLSession`) via type-safe Pigeon platform channels, with automatic fallback to in-process foreground streaming on desktop.
- **Dual Authentication & Pure Dart SigV4:** Native support for both presigned URLs and AWS Cognito / STS temporary credentials with pure Dart HMAC-SHA256 SigV4 request signing (`UNSIGNED-PAYLOAD`).
- **Turnkey S3 Provider Profiles:** Built-in profiles and URL builders for **AWS S3**, **Cloudflare R2**, **MinIO**, **Wasabi**, and **Backblaze B2**.

---

## 🏗 Architecture

```
                          ┌──────────────────────────┐
                          │     S3TransferKit        │
                          │   (Unified Facade)       │
                          └─────────────┬────────────┘
                                        │
                         ┌──────────────▼────────────┐
                         │      TransferManager      │
                         │ (Queue / Priority / Store)│
                         └──────────────┬────────────┘
                                        │
           ┌────────────────────────────┼───────────────────────────┐
           │                            │                           │
┌──────────▼──────────┐      ┌──────────▼──────────┐     ┌──────────▼──────────┐
│ HttpStreaming       │      │ RetryingTransport   │     │ NativeBackground    │
│ Transport           │      │ (Backoff & Jitter)  │     │ Transport (Pigeon)  │
└──────────┬──────────┘      └──────────┬──────────┘     └──────────┬──────────┘
           │                            │                           │
           └────────────────────────────┼───────────────────────────┘
                                        │
                         ┌──────────────▼────────────┐
                         │   AWS S3 / Compatible     │
                         │ (R2 / MinIO / Wasabi / B2)│
                         └───────────────────────────┘
```

---

## 📦 Installation

Add `s3_transfer_kit` to your `pubspec.yaml`:

```yaml
dependencies:
  s3_transfer_kit: ^0.1.1
```

Then run:

```bash
flutter pub get
```

---

## 🚀 Quickstart

### 1. Simple Presigned URL Upload

Upload a local file using a backend-issued presigned `PUT` URL:

```dart
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

final s3 = S3TransferKit();

final task = s3.upload(
  S3UploadRequest.fromPresignedUrl(
    filePath: '/path/to/local/file.mp4',
    uploadUrl: Uri.parse('https://my-bucket.s3.amazonaws.com/videos/file.mp4?...'),
    contentType: 'video/mp4',
  ),
);

// Listen to progress
task.progress.listen((progress) {
  print('${(progress.fraction * 100).toStringAsFixed(1)}% (${progress.bytesTransferred} / ${progress.totalBytes} bytes)');
});

// Await completion
final result = await task.result;
print('Upload complete! ETag: ${result.eTag}');
```

---

### 2. Atomic File Download

Download a file safely with staging and atomic finalization:

```dart
final task = s3.download(
  S3DownloadRequest.fromPresignedUrl(
    downloadUrl: Uri.parse('https://my-bucket.s3.amazonaws.com/reports/document.pdf?...'),
    destinationPath: '/path/to/downloads/document.pdf',
    overwrite: true,
  ),
);

task.progress.listen((progress) {
  print('Downloaded: ${progress.fraction * 100}%');
});

final result = await task.result;
print('Saved to: ${result.destinationPath}');
```

---

### 3. Large File Multipart Upload

For files larger than 10MB, use multipart uploads for maximum resilience and speed:

```dart
const filePath = '/path/to/large_video.mp4';
final fileLength = await File(filePath).length();

final provider = S3MultipartProvider.fromCallbacks(
  onInitiate: ({required filePath, required fileLength, required contentType, customHeaders = const {}}) async {
    // Call backend API to initiate multipart upload and return uploadId
    return await myBackendApi.initiateUpload(filePath, contentType);
  },
  onGetPartUrl: ({required uploadId, required partNumber, required partLength}) async {
    // Request a presigned URL for this specific part from your backend
    return await myBackendApi.getPresignedPartUrl(uploadId, partNumber);
  },
  onComplete: ({required uploadId, required parts}) async {
    // Notify your backend to complete the multipart upload with the assembled ETags
    final eTag = await myBackendApi.completeUpload(uploadId, parts);
    return S3UploadResult(bytesTransferred: fileLength, eTag: eTag);
  },
  onAbort: ({required uploadId}) async {
    // Notify your backend to abort the upload if cancelled or failed
    await myBackendApi.abortUpload(uploadId);
  },
);

final task = s3.uploadMultipart(
  S3MultipartUploadRequest(
    filePath: filePath,
    provider: provider,
    partSize: 5 * 1024 * 1024, // 5MB parts (minimum S3 requirement)
    maxConcurrentParts: 3,     // Upload up to 3 parts simultaneously
  ),
);

task.progress.listen((progress) {
  print('Multipart progress: ${(progress.fraction * 100).toStringAsFixed(1)}%');
});

final result = await task.result;
print('Multipart completed: ${result.eTag}');
```

---

### 4. Resuming Interrupted Multipart Uploads

Persist upload states and resume them automatically after app restarts:

```dart
// 1. Initialize S3TransferKit with a persistent store
final store = FileTransferStore(directory: appDocumentsDirectory);
final s3 = S3TransferKit(transferStore: store);

// 2. Query pending/incomplete transfers on app launch
final pendingTransfers = await s3.getPendingTransfers();

for (final record in pendingTransfers) {
  print('Found incomplete transfer: ${record.id} for ${record.filePath}');

  // 3. Resume the transfer (skips parts that were already uploaded)
  final resumedTask = await s3.resumeMultipartUpload(
    taskId: record.id,
    provider: myMultipartProvider,
  );

  resumedTask.progress.listen((progress) {
    print('Resumed progress: ${(progress.fraction * 100).toStringAsFixed(1)}%');
  });

  await resumedTask.result;
}
```

---

### 5. AWS Cognito / STS Dynamic Credentials & SigV4

Authenticate directly using temporary AWS credentials without backend presigning:

```dart
final authorization = S3Authorization.cognito(
  region: 'us-east-1',
  credentialsProvider: () async {
    // Fetch refreshed credentials from AWS Cognito Identity Pool
    return S3Credentials(
      accessKeyId: 'ASIA...',
      secretAccessKey: '...',
      sessionToken: '...',
      expiration: DateTime.now().add(const Duration(hours: 1)),
    );
  },
);

final task = s3.upload(
  S3UploadRequest(
    filePath: '/path/to/data.json',
    authorization: authorization,
    uploadUrl: Uri.parse('https://my-bucket.s3.us-east-1.amazonaws.com/data.json'),
  ),
);
```

---

### 6. S3-Compatible Providers (Cloudflare R2, MinIO, Wasabi, Backblaze B2)

Use preconfigured provider profiles:

```dart
// Cloudflare R2
final r2Profile = S3ProviderProfile.cloudflareR2(
  accountId: 'your-account-id',
  region: 'auto',
);
final uploadUrl = r2Profile.buildUrl(bucket: 'my-bucket', objectKey: 'assets/file.png');

// MinIO (Self-hosted)
final minioProfile = S3ProviderProfile.minio(
  endpoint: 'http://192.168.1.100:9000',
  region: 'us-east-1',
);

// Wasabi
final wasabiProfile = S3ProviderProfile.wasabi(region: 'us-east-1');

// Backblaze B2
final b2Profile = S3ProviderProfile.backblazeB2(region: 'us-west-004');
```

---

### 7. Concurrency Limiting, Priorities, & Queue Control

Control execution volume and prioritize urgent transfers:

```dart
final s3 = S3TransferKit(
  configuration: const TransferQueueConfiguration(
    maxConcurrentTransfers: 4, // Up to 4 simultaneous transfers
    defaultPriority: TransferPriority.normal,
  ),
);

// High priority transfer jumps ahead in the queue
final urgentTask = s3.upload(
  S3UploadRequest.fromPresignedUrl(
    filePath: '/path/to/urgent.jpg',
    uploadUrl: urgentUrl,
    priority: TransferPriority.high,
  ),
);

// Global queue controls
s3.pauseAll();  // Temporarily halts scheduling of new tasks
s3.resumeAll(); // Resumes scheduling
s3.cancelAll(); // Cancels all queued and running tasks

// Observe live queue metrics
s3.snapshotStream.listen((snapshot) {
  print('Queued: ${snapshot.queuedCount}, Running: ${snapshot.runningCount}');
});
```

---

### 8. Native Background Execution

Ensure large transfers complete even when the user leaves the app:

```dart
final isSupported = await s3.isBackgroundTransferSupported();

final task = s3.upload(
  S3UploadRequest.fromPresignedUrl(
    filePath: '/path/to/huge_dataset.zip',
    uploadUrl: presignedUrl,
    // Opt-in to OS background execution (Android Foreground Service / iOS URLSession)
    executionMode: TransferExecutionMode.allowBackground,
  ),
);
```

---

### 9. Cancellation & Cooperative Teardown

Cancel transfers gracefully at any time:

```dart
final token = CancellationToken();

final task = s3.upload(
  S3UploadRequest.fromPresignedUrl(
    filePath: '/path/to/file.mov',
    uploadUrl: presignedUrl,
    cancellationToken: token,
  ),
);

// Cancel after 5 seconds
Future.delayed(const Duration(seconds: 5), () {
  token.cancel('User navigated away');
});

try {
  await task.result;
} on TransferException catch (e) {
  if (e.code == TransferErrorCode.cancelled) {
    print('Transfer cancelled cleanly: ${e.message}');
  }
}
```

---

## ⚠️ Error Codes

All failures are thrown as typed `TransferException` instances containing an actionable `TransferErrorCode`:

| Error Code | Meaning | Retryable |
|---|---|:---:|
| `fileNotFound` | Local source file does not exist. | No |
| `fileAccessDenied` | File permissions or directory creation failed. | No |
| `fileValidationFailed` | Source file length changed mid-transfer or was modified. | No |
| `networkUnavailable` | Device has no internet or DNS resolution failed. | Yes |
| `connectionTimeout` | Socket connection or handshake timed out. | Yes |
| `httpFailure` | HTTP 5xx or 429 response from S3 endpoint. | Yes |
| `authenticationExpired` | Presigned URL or STS session token expired. | No (Auto-renews if provider supported) |
| `cancelled` | Transfer was cancelled via `CancellationToken`. | No |
| `invalidConfiguration` | Malformed parameters or invalid part size (< 5MB). | No |
| `unexpectedFailure` | Unhandled runtime or system exception. | No |

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
