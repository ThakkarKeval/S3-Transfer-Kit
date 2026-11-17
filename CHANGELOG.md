## 0.1.0

Initial production-grade release of `s3_transfer_kit`, featuring:

### Core Transfers
- **Streaming Uploads:** Bounded-memory chunked streaming over HTTP `PUT` with resident heap overhead under 32MB regardless of file size.
- **Atomic Downloads:** Two-phase staging with `.tmp` files and atomic rename on completion, safe directory creation, and automatic temp cleanup on error.
- **Progress Tracking:** Monotonic byte and fractional progress calculation via immutable `TransferProgress` updates.
- **Cancellation:** In-flight cooperative cancellation through `CancellationToken` with active socket abort.

### Concurrency & Queue Management
- **Managed Transfer Queue:** Concurrency limiter (`TransferQueueConfiguration.maxConcurrentTransfers`) preventing connection exhaustion.
- **Priority Scheduling:** `TransferPriority` (`high`, `normal`, `low`) with stable FIFO ordering for identical priorities.
- **Queue Controls:** Task-level and queue-level pause, resume, cancel, and observable broadcast snapshot streams (`TransferQueueSnapshot`).

### Resilient Retry & Fault Tolerance
- **Configurable Retry Policies:** `RetryPolicy.standard` with exponential backoff and randomized full jitter to eliminate thundering herd contention.
- **Error Classification:** `RetryClassifier` classifying transient socket drops, connection timeouts, and HTTP 5xx/429 errors vs. non-retryable 4xx errors.
- **Fail-Fast Mode:** Opt-in `RetryPolicy.none` to allow applications to block or prompt immediate manual re-uploads.

### S3 Multipart Uploads
- **S3 Spec Compliant:** Strict 5MB minimum part size enforcement with logical zero-copy file slicing.
- **Parallel Part Streaming:** Bounded concurrent workers (`maxConcurrentParts`) with independent part-level retries.
- **Cost Protection:** Automatic `abortMultipartUpload` calls on permanent failures or cancellations to prevent orphaned cloud storage fees.
- **Flexible Provider Hooks:** `S3MultipartProvider` contract and `S3MultipartProvider.fromCallbacks` for seamless backend coordination.

### Persistent Transfer Recovery
- **Zero-Dependency Persistence:** Lightweight `TransferStore` abstraction with atomic `FileTransferStore` and `InMemoryTransferStore`.
- **Automatic Resume:** Skips already-completed parts on process restart, resumes aggregate byte progress smoothly, and verifies source file integrity.
- **Orphaned Cleanup:** Automated `cleanOrphanedTransfers` for stale records and abandoned multipart uploads.

### Native Background Execution
- **Opt-In Background Execution:** Transfers execute foreground-only by default, routing to native background services only when requested via `TransferExecutionMode.allowBackground`.
- **Pigeon Platform Channels:** Type-safe messaging interface across Dart, Android (Kotlin), iOS (Swift), and macOS (Swift).
- **Graceful Fallback:** Automatic fallback to in-process foreground transfers on platforms without native background support.

### Multi-Provider & Credential Management
- **Pure Dart SigV4 Signer:** Full AWS SigV4 request signing using HMAC-SHA256 and `UNSIGNED-PAYLOAD` streaming.
- **Dual Authentication:** Presigned URLs or dynamic AWS Cognito/STS credentials (`S3Authorization.cognito`, `S3Authorization.sigV4`).
- **Turnkey S3 Profiles:** Preconfigured endpoints, regions, and path styles for AWS S3, Cloudflare R2, MinIO, Wasabi, and Backblaze B2 via `S3ProviderProfile`.
- **Credential Renewal:** Preemptive expiration buffer checks and reactive token renewal on `403` / `ExpiredToken` errors.
