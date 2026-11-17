# Architectural Decisions — s3_transfer_kit

## ADR-001: Type-Safe Platform Channel Management via Pigeon

- **Status:** Accepted
- **Context:** Standard Flutter MethodChannels rely on error-prone string identifiers, untyped message dictionaries, and manual runtime type checking across Kotlin, Swift, and Dart.
- **Decision:** Integrate `pigeon` (v30) to generate strongly-typed interfaces and message codecs for all host-to-engine communication.
- **Consequences:** Native code in Android (Kotlin) and iOS/macOS (Swift) implements typed interfaces with zero manual string parsing. Testing is streamlined through typed mock interfaces.

---

## ADR-002: Transport Layer Decoupling for Foreground vs Native Background Transfers

- **Status:** Accepted
- **Context:** Transfers can execute in the application foreground or native OS background services (WorkManager on Android, background URLSession on iOS). Mixing background native task orchestration with core transfer streaming introduces complexity and limits desktop/web support.
- **Decision:** Define an internal `TransferTransport` abstraction. Foreground transfers execute via Dart HTTP chunk streaming (`HttpStreamingTransport`), providing immediate support across Android, iOS, macOS, Windows, Linux, and Web with zero IPC overhead. Native background transfers plug into the same abstraction via Pigeon in Phase 7.
- **Consequences:** Clean separation of concerns, excellent local unit testability, and full multiplatform support without premature native complexity.

---

## ADR-003: Zero AWS Client Credentials & Mandatory URL Redaction

- **Status:** Accepted
- **Context:** Embedding AWS IAM access keys or secret keys in mobile apps is a critical security vulnerability. Logging presigned URLs directly exposes bearer credentials.
- **Decision:** The package strictly forbids accepting static AWS credentials. All authentication is performed via presigned URLs obtained from a trusted backend. Presigned URL query parameters are automatically redacted from error objects, string representations, and logs.
- **Consequences:** Robust security by design that complies with industry standards.

---

## ADR-004: Polymorphic S3 Authorization Strategy (Presigned URL & Cognito)

- **Status:** Accepted
- **Context:** Applications may authenticate either via backend-generated presigned URLs or directly via AWS Cognito Identity Pools (temporary STS credentials requiring SigV4 signing). Hardcoding upload requests to only presigned URL strings would prevent Cognito support or force duplicate APIs.
- **Decision:** Abstract authorization behind `S3Authorization`, yielding an `AuthorizedHttpRequest` containing the target URL and signed headers. Presigned URLs are handled via `S3Authorization.presignedUrl` and `S3Authorization.presignedProvider`; Cognito / STS SigV4 signing plugs in as `S3Authorization.cognito` without modifying the transfer transport.
- **Consequences:** Unified transfer pipeline and identical developer experience across presigned and Cognito authentication flows.

---

## ADR-005: Two-Phase Commit for File Downloads

- **Status:** Accepted
- **Context:** Writing download chunks directly to the target destination path risks leaving partial, corrupted files if an error occurs, the user cancels the transfer, or the process terminates prematurely.
- **Decision:** Downloads stream into a temporary staging file (`<destinationPath>.s3_download_<timestamp>.tmp`). Only upon successful HTTP 2xx completion and file closure is the temporary file atomically renamed to the final destination path. In-flight cancellation or errors immediately purge the staging file.
- **Consequences:** Guaranteed file integrity at destination paths. Zero partially-downloaded files left in user directories.

---

## ADR-006: Transfer Concurrency, Priority Scheduling, and Opt-in Background Execution Mode

- **Status:** Accepted
- **Context:** Applications need concurrency limits to prevent network socket starvation and CPU thrashing when triggering numerous transfers. Certain transfers require prioritization (e.g. user-visible profile photo vs background document sync). Furthermore, developers need explicit control over whether transfers run in the foreground only or can continue in the background.
- **Decision:** Implement a `TransferQueue` coordinated by `TransferManager` supporting:
  1. Configurable `maxConcurrentTransfers` (default: 4).
  2. Priority scheduling via `TransferPriority` (`high`, `normal`, `low`) with stable FIFO ordering within identical priority levels.
  3. Explicit `TransferExecutionMode`: transfers run `foregroundOnly` by default; developers must explicitly opt into `allowBackground` per request or per queue configuration.
  4. Task-level and queue-level pause/resume and cancellation controls with observable state snapshots.
- **Consequences:** Predictable resource utilization, transparent queue inspection, and fine-grained execution control across all supported platforms.

---

## ADR-007: Configurable Retry Policy, Exponential Backoff with Jitter, and Fail-Fast Mode

- **Status:** Accepted
- **Context:** Transient network and server errors (broken sockets, connection timeouts, HTTP 5xx, HTTP 429) can often be recovered automatically by retrying. However, some user flows (e.g. interactive user uploads) require failing fast without background delays so the app can block or prompt the user to manually re-upload.
- **Decision:** Introduce `RetryPolicy` and `RetryingTransport` with:
  1. `RetryPolicy.none`: Fail-fast mode (`allowRetry = false`). Errors immediately fail the task on the first attempt with zero delay.
  2. `RetryPolicy.standard`: Configurable exponential backoff with full jitter to avoid thundering herd issues.
  3. `RetryClassifier`: Deterministically isolates retryable errors (HTTP 5xx, 429, socket drop, timeout) from permanent errors (HTTP 4xx, file not found, cancellation, auth expired).
  4. Cooperative sleep cancellation: Cancelling during backoff timer immediately aborts without waiting for the sleep duration to elapse.
  5. Configurable both globally on `TransferQueueConfiguration` and per request on `S3UploadRequest` / `S3DownloadRequest`.
- **Consequences:** Complete developer control over retry vs fail-fast behavior with zero code duplication and predictable error recovery.

---

## ADR-008: S3-Compliant Multipart Uploads and Provider Abstraction

- **Status:** Accepted
- **Context:** Uploading large files (> 5MB up to terabytes) via a single HTTP PUT request is fragile: any connection interruption loses all progress, and memory or server limits can reject massive requests. Furthermore, AWS S3 charges customers for orphaned multipart parts if aborted uploads are not explicitly cleaned up.
- **Decision:** Implement `MultipartUploadCoordinator` adhering strictly to AWS S3 specifications:
  1. Slices files logically with minimum part size $\ge 5\text{MB}$ (except final part).
  2. Uploads parts concurrently using bounded parallel workers (`maxConcurrentParts`).
  3. Decouples AWS orchestration behind `S3MultipartProvider` (with functional `fromCallbacks` factory).
  4. Automatic cleanup: Invokes `abortMultipartUpload` upon unrecoverable failure or user cancellation, preventing orphaned S3 storage costs.
  5. Part-level retry resilience: Transient failures in individual parts are retried independently without re-uploading previously completed parts.
- **Consequences:** Resilient, high-throughput uploading of multi-gigabyte files with robust cloud cost protection.

---

## ADR-009: Persistent Transfer Recovery Architecture

- **Status:** Accepted
- **Context:** Mobile and desktop applications are frequently killed by the OS, backgrounded, or encounter abrupt power loss during multi-gigabyte transfers. Re-uploading gigabytes of data from part 1 wastes bandwidth, increases user wait times, and incurs duplicate cloud egress/PUT costs. Third-party database packages (e.g. SQLite, Hive, Isar) introduce heavy native dependencies, build complexity, and potential schema migration fragility.
- **Decision:**
  1. Lightweight, dependency-free storage abstraction via `TransferStore` interface with `PersistentTransferRecord`.
  2. Implement `FileTransferStore` leveraging atomic write-and-rename operations (`<id>.json.tmp` -> `<id>.json`) in an isolated directory to prevent JSON corruption during abrupt crashes.
  3. Provide `InMemoryTransferStore` for fast, hermetic unit testing and ephemeral sessions.
  4. State integrity verification: Before resuming, validate that the local file still exists, is readable, and its size matches `record.fileLength`. If size changed, fail fast with `TransferErrorCode.fileValidationFailed`.
  5. S3 Multipart resumption: Skip already-completed parts recorded in `completedParts`, initialize byte progress to the sum of finished parts, upload only pending slices, and assemble all sorted ETags upon completion.
  6. Orphaned transfer cleanup: Provide `cleanOrphanedTransfers` on `TransferManager` to prune records older than a configurable threshold and invoke `abortMultipartUpload` on S3 to prevent lingering cloud storage charges.
- **Consequences:** Zero third-party database dependencies, instant recovery across process termination, robust cloud cost protection, and smooth progress tracking on resumed transfers.

---

## ADR-010: Native Background Transfers and Opt-In Execution Architecture

- **Status:** Accepted
- **Context:** Mobile OS kernels (Android and iOS) throttle or freeze app processes seconds after backgrounding, halting standard in-process Dart HTTP sockets. However, many applications prefer lightweight in-process foreground transfers to avoid OS background execution overhead or native channel complexity unless explicitly needed.
- **Decision:**
  1. Opt-in background execution: Background execution is strictly optional via `TransferExecutionMode.allowBackground`. Transfers default to `TransferExecutionMode.foregroundOnly` (in-process Dart streaming).
  2. Type-safe Pigeon platform channel: Defines `S3TransferKitHostApi` and `S3TransferKitFlutterApi` transmitting structured `NativeUploadRequest`, `NativeDownloadRequest`, `NativeTransferProgressUpdate`, and `NativeTransferStateUpdate`.
  3. Platform native backends:
     - Android: Worker thread pool with background `HttpURLConnection` streaming and main-thread Pigeon callbacks.
     - iOS & macOS: Native `URLSession` / background tasks with `URLSessionTaskDelegate` and async MainActor message dispatching.
  4. Graceful fallback: If background execution is unsupported on the host platform (e.g. Web or unsupported platforms), `NativeBackgroundTransport` automatically falls back to in-process foreground transport.
  5. Cooperative cancellation: Cancelling via `CancellationToken` in Dart invokes `cancelBackgroundTransfer` on the host platform, terminating native network connections immediately.
- **Consequences:** Seamless transfers surviving app backgrounding on supported native platforms while giving developers complete control to keep transfers foreground-only with zero unnecessary overhead.

---

## ADR-011: Credential Renewal, SigV4 Signing, and Multi-Provider Storage Profiles

- **Status:** Accepted
- **Context:** Cloud transfers require diverse authorization mechanisms. Some applications use backend-issued presigned URLs, while others authenticate directly via AWS Cognito Identity Pools, AWS STS, or static IAM credentials. Temporary credentials and presigned URLs expire, causing transfers to abort mid-stream with `ExpiredToken` / `403 Forbidden` unless transparently renewed. Furthermore, developers need turnkey support for S3-compatible providers (Cloudflare R2, MinIO, Wasabi, Backblaze B2) without manually assembling bespoke endpoints, regions, and path styles.
- **Decision:**
  1. Universal `S3Authorization` hierarchy: Supports static presigned URLs (`S3Authorization.presignedUrl`), dynamic URL providers (`S3Authorization.presignedProvider`), static IAM SigV4 (`S3Authorization.sigV4`), and temporary STS/Cognito credentials (`S3Authorization.cognito`).
  2. Pure Dart AWS SigV4 implementation via `SigV4Signer`: Implements canonical request hashing, credential scoping, and HMAC-SHA256 signature calculation using `UNSIGNED-PAYLOAD` streaming, avoiding buffering large files in RAM.
  3. Preemptive & reactive credential renewal:
     - Preemptive: Automatically checks credential `expiration` with a configurable buffer window (e.g. 5 minutes) before signing requests.
     - Reactive: `RetryingTransport` intercepts `TransferErrorCode.authenticationExpired` when `request.authorization.canRenew == true`, invokes `authorization.renew()`, and re-signs fresh requests for transparent recovery.
  4. Predefined S3 provider profiles: `S3ProviderProfile` supplies preconfigured profiles and URL builders for AWS S3, Cloudflare R2, MinIO, Wasabi, and Backblaze B2, supporting both virtual-host and path-style addressing.
- **Consequences:** End-to-end support for both presigned URLs and AWS Cognito/STS credentials with zero downtime across token expirations and seamless multi-provider compatibility.

---

## ADR-012: Performance Benchmarking, Memory Boundedness, and Stress Invariants

- **Status:** Accepted
- **Context:** Production transfer SDKs must endure harsh conditions: gigabyte-scale transfers on constrained devices, high queue saturation (100+ concurrent requests), abrupt TCP socket resets, S3 rate limiting (HTTP 429/503), and sudden user cancellations. Without strict invariants, memory consumption can balloon, race conditions can cause deadlocks, and cancelled tasks can leak background timers and network connections.
- **Decision:**
  1. Bounded memory invariant: `HttpStreamingTransport` and `MultipartUploadCoordinator` must stream files and parts via `file.openRead()` in discrete chunks ($\le 64\text{KB}$) without loading files into memory buffers. Downloads stream directly into `.tmp` staging sinks on disk.
  2. Strict concurrency limiter: `TransferQueue` enforces `runningItems.length <= maxConcurrentTransfers` across arbitrary task volumes (tested up to 120+ concurrent tasks), draining queues via priority order (`high` > `normal` > `low`) and sequence number FIFO.
  3. Resilient socket drop recovery: In-flight socket aborts, broken pipes, and connection resets trigger automatic re-attempts up to `maxAttempts`, re-streaming the payload cleanly from byte 0 without corrupted partial states.
  4. Non-cascading multipart retries: In `MultipartUploadCoordinator`, failures during a single part retry independently and do not restart or invalidate already completed parts.
  5. Deterministic queue teardown: Calling `dispose()` clears pending item queues, cancels active timers, cleans up streams, and rejects subsequent enqueue attempts with `StateError`.
- **Consequences:** Provable $<32\text{MB}$ heap overhead during multi-megabyte transfers, zero task starvation under high queue saturation, transparent recovery from network drops, and clean teardown during lifecycle transitions.

