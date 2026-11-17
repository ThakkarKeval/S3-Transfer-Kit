/// Lifecycle states of a transfer operation.
enum TransferStatus {
  /// The transfer has been created and enqueued, but has not started sending bytes.
  enqueued,

  /// The transfer is actively transmitting bytes.
  inProgress,

  /// The transfer completed successfully.
  completed,

  /// The transfer failed due to an error.
  failed,

  /// The transfer was cancelled by the caller.
  cancelled,
}
