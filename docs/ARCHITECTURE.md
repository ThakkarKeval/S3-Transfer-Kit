# Architecture Specification — s3_transfer_kit

## 1. Architectural Principles

1. **Separation of Concerns:**
   - **Public API:** Minimal, stable facade (`S3TransferKit`) and immutable value objects.
   - **Orchestration:** Transfer coordinator managing lifecycle, queueing, and streams.
   - **Transport Layer:** Decoupled via `TransferTransport` interface, enabling pure Dart streaming in foreground and native background engines when needed.
   - **Security Layer:** URL parameter sanitization and token redaction isolated from business logic.

2. **Bounded Resource Consumption:**
   - Files are never read into memory as a whole.
   - Streaming is conducted with fixed chunk buffers (default 64 KB).

3. **Dependency Inversion:**
   - Core transfer coordinators depend on the `TransferTransport` contract, never on concrete HTTP or platform channel implementations directly.

---

## 2. Layered Architecture Diagram

```text
┌───────────────────────────────────────────────────────────────────┐
│                           Public API                              │
│  - S3TransferKit (facade)                                         │
│  - S3UploadRequest / S3DownloadRequest                            │
│  - S3TransferTask / CancellationToken                             │
│  - TransferProgress / TransferStatus                              │
│  - TransferException / TransferErrorCode                          │
└─────────────────────────────────┬─────────────────────────────────┘
                                  │
┌─────────────────────────────────▼─────────────────────────────────┐
│                     Transfer Coordinator                          │
│  - Validates transfer requests and file accessibility             │
│  - Manages task lifecycle transitions                             │
│  - Exposes progress and completion streams                        │
└──────────────────┬───────────────────────────────┬────────────────┘
                   │                               │
┌──────────────────▼─────────────┐ ┌───────────────▼────────────────┐
│   HttpStreamingTransport       │ │     NativeBackgroundTransport  │
│   (Dart I/O Chunk Streaming)   │ │     (Pigeon: Android/iOS)      │
│   - Foreground execution       │ │     - WorkManager (Android)    │
│   - Multiplatform support      │ │     - URLSession (iOS)         │
└────────────────────────────────┘ └────────────────────────────────┘
```

---

## 3. Security Architecture

1. **Zero Client Secret Storage:**
   - AWS Access Key IDs and Secret Keys are strictly forbidden in client configuration.
   - Transfers must use backend-provided presigned URLs or explicit authorization providers.
2. **Sensitive Token Redaction:**
   - Presigned query parameters (such as `X-Amz-Signature`, `X-Amz-Credential`, `X-Amz-Security-Token`) are redacted from all exception messages, stack traces, and debug logs.
3. **Transport Security:**
   - Requires HTTPS for all remote transfer destinations by default.
   - Rejects plain HTTP unless explicitly enabled for local development/testing (e.g., local MinIO).
4. **File System Safety:**
   - Path existence, directory bounds, and read permissions are validated before establishing connections.

---

## 4. Error Hierarchy

All package exceptions derive from `TransferException`:

```dart
class TransferException implements Exception {
  final TransferErrorCode code;
  final String message;
  final int? httpStatusCode;
  final bool isRetryable;
  final Object? cause;
  final StackTrace? stackTrace;
}
```

Standard error categories include:
- `invalidConfiguration`
- `fileNotFound`
- `fileAccessDenied`
- `networkUnavailable`
- `networkTimeout`
- `httpFailure`
- `authenticationExpired`
- `cancelled`
- `unexpectedFailure`
