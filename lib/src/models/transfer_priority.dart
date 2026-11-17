/// Scheduling priority for queued transfers.
enum TransferPriority implements Comparable<TransferPriority> {
  /// Low priority task. Processed after normal and high priority tasks.
  low(0),

  /// Normal priority task. Default priority for all transfers.
  normal(1),

  /// High priority task. Scheduled ahead of normal and low priority tasks.
  high(2);

  const TransferPriority(this.value);

  /// Numeric priority level for sorting. Higher values have precedence.
  final int value;

  @override
  int compareTo(TransferPriority other) => value.compareTo(other.value);
}
