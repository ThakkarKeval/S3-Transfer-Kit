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
