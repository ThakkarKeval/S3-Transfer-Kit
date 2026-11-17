import 'persistent_transfer_record.dart';

/// Contract for persisting transfer records to support recovery across restarts.
abstract class TransferStore {
  /// Saves or updates a transfer record.
  Future<void> save(PersistentTransferRecord record);

  /// Retrieves a transfer record by its unique [id], or `null` if not found.
  Future<PersistentTransferRecord?> get(String id);

  /// Retrieves all transfer records currently stored.
  Future<List<PersistentTransferRecord>> getAll();

  /// Retrieves all transfer records currently in an active (in-progress, enqueued, or paused) state.
  Future<List<PersistentTransferRecord>> getActive();

  /// Deletes a transfer record by its [id].
  Future<void> delete(String id);

  /// Clears all stored transfer records.
  Future<void> clear();
}
