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
