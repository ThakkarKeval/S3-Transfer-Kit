# Development Plan — s3_transfer_kit

## 1. Project Overview
- **Package Name:** `s3_transfer_kit`
- **Type:** Production-grade Flutter plugin for Amazon S3 and compatible object storage services.
- **Languages:** Dart (core and multiplatform transfers), Kotlin (Android background execution), Swift (iOS/macOS background execution).

---

## 2. Roadmap Phases & Scope

### Phase 0: Foundation and Architecture *(Current)*
- **Objective:** Establish the package's engineering foundation, architecture boundaries, documentation standards, and development plan.
- **Deliverables:**
  - `docs/DEVELOPMENT_PLAN.md`
  - `docs/ARCHITECTURE.md`
  - `docs/DECISIONS.md`
  - `docs/PROGRESS.md`
  - Analysis and lint configuration review.

### Phase 1: Basic Presigned URL Upload
- **Objective:** Implement single-file foreground uploads using backend-provided presigned PUT URLs.
- **Scope:**
  - File validation (existence, readability, non-empty, path safety).
  - Bounded-memory streaming transfer via HTTP `PUT`.
  - Progress tracking (bytes transferred, total bytes, fractional progress).
  - Cancellation via `CancellationToken`.
  - Typed error model (`TransferException` and `TransferErrorCode`).
  - Unit tests for validation, streaming, progress, error mapping, and cancellation.

### Phase 2: File Downloads
- **Objective:** Implement single-file downloads from authorized URLs.
- **Scope:**
  - Streaming download from authorized HTTP `GET` endpoints.
  - Safe staging in temporary files and atomic finalization.
  - Progress reporting and cancellation.
  - Cleanup of incomplete download files.

### Phase 3: Transfer Lifecycle & Queue Management
- **Objective:** Centralize transfer state and manage concurrent execution.
- **Scope:**
  - Explicit transfer state machine: `enqueued` -> `inProgress` -> `completed` / `failed` / `cancelled`.
  - Task queue and concurrency limiter.
  - Observable state stream per task and across the queue.

### Phase 4: Retry & Network Recovery
- **Objective:** Add resilient network fault tolerance for transient failures.
- **Scope:**
  - Configurable retry policies (exponential backoff with full jitter).
  - Classification of retryable vs non-retryable HTTP and socket errors.
  - Safe retry behavior for idempotent operations.

### Phase 5: Multipart Upload Support
- **Objective:** Support reliable large file uploads via S3 multipart APIs.
- **Scope:**
  - Sizing and chunking (5MB minimum part size per S3 specification).
  - Part uploading and ETag collection.
  - Backend integration hooks for multipart create and complete requests.
  - Abort and cleanup on failure or cancellation.

### Phase 6: Persistent Transfer Recovery
- **Objective:** Support transfer resumption across application restarts.
- **Scope:**
  - Durable transfer metadata storage.
  - Validation of state integrity before resumption.
  - Cleanup of abandoned or orphaned transfer states.

### Phase 7: Native Background Transfers
- **Objective:** Enable transfers to continue while app is backgrounded or suspended.
- **Scope:**
  - Android WorkManager / Foreground Service integration.
  - iOS background `URLSession` integration.
  - State and progress synchronization via Pigeon.

### Phase 8: Credential Renewal & S3-Compatible Providers
- **Objective:** Support on-demand presigned URL refresh and third-party storage compatibility.
- **Scope:**
  - Asynchronous `PresignedUrlProvider` callbacks for renewal prior to expiry.
  - Validation with MinIO, Cloudflare R2, and Wasabi.

### Phase 9: Performance & Reliability Validation
- **Objective:** Benchmark and stress test transfer pipelines.
- **Scope:**
  - Memory profiling under large file transfers.
  - High concurrency stress testing.
  - Network disconnection recovery benchmarks.

### Phase 10: Release Readiness
- **Objective:** Complete pre-publication requirements for pub.dev.
- **Scope:**
  - Example application polishing.
  - Complete API documentation coverage.
  - Platform verification across Android, iOS, Web, and Desktop.
  - Pub package validation (`dart pub publish --dry-run`).
