import '../models/transfer_execution_mode.dart';
import '../models/transfer_priority.dart';
import '../retry/retry_policy.dart';

/// Configuration options for transfer queue concurrency, scheduling, and retry behavior.
class TransferQueueConfiguration {
  /// Constructs a [TransferQueueConfiguration].
  const TransferQueueConfiguration({
    this.maxConcurrentTransfers = 4,
    this.defaultExecutionMode = TransferExecutionMode.foregroundOnly,
    this.defaultPriority = TransferPriority.normal,
    this.defaultRetryPolicy = RetryPolicy.standard,
  }) : assert(
         maxConcurrentTransfers > 0,
         'maxConcurrentTransfers must be greater than 0',
       );

  /// Maximum number of transfers allowed to execute concurrently. Defaults to 4.
  final int maxConcurrentTransfers;

  /// Default execution mode for transfers that do not specify one. Defaults to [TransferExecutionMode.foregroundOnly].
  final TransferExecutionMode defaultExecutionMode;

  /// Default scheduling priority for transfers that do not specify one. Defaults to [TransferPriority.normal].
  final TransferPriority defaultPriority;

  /// Default retry policy applied to transfers that do not specify an individual policy.
  ///
  /// Set to [RetryPolicy.none] to make the entire queue fail fast on the first error. Defaults to [RetryPolicy.standard].
  final RetryPolicy defaultRetryPolicy;
}
