/// Defines whether a transfer executes in-process or can be delegated to native background subsystems.
enum TransferExecutionMode {
  /// The transfer executes strictly in-process using Dart streaming.
  ///
  /// This is the default mode. It guarantees minimal resource overhead,
  /// zero background service requirements, fine-grained progress updates,
  /// and identical behavior across Android, iOS, Web, macOS, Windows, and Linux.
  foregroundOnly,

  /// The transfer may be delegated to native OS background transfer subsystems
  /// (e.g. WorkManager or Foreground Service on Android, background URLSession on iOS).
  ///
  /// The transfer will continue even if the application is backgrounded or suspended.
  /// Requires opt-in by the caller and platform support.
  allowBackground,
}
