/// Lifecycle states of a transfer operation.
enum TransferStatus {
  /// The transfer has been created and enqueued, but has not started sending or receiving bytes.
  enqueued,

  /// The transfer is actively transmitting bytes.
  inProgress,

  /// The transfer is paused and can be resumed.
  paused,

  /// The transfer completed successfully.
  completed,

  /// The transfer failed due to an error.
  failed,

  /// The transfer was cancelled by the caller.
  cancelled,
}
