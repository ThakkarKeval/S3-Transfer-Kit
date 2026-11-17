import '../models/transfer_execution_mode.dart';
import '../models/transfer_priority.dart';

/// Configuration options for transfer queue concurrency and scheduling.
class TransferQueueConfiguration {
  /// Constructs a [TransferQueueConfiguration].
  const TransferQueueConfiguration({
    this.maxConcurrentTransfers = 4,
    this.defaultExecutionMode = TransferExecutionMode.foregroundOnly,
    this.defaultPriority = TransferPriority.normal,
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
}
