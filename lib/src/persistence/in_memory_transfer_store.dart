import 'persistent_transfer_record.dart';
import 'transfer_store.dart';

/// In-memory implementation of [TransferStore] useful for unit testing or ephemeral session management.
class InMemoryTransferStore implements TransferStore {
  final Map<String, PersistentTransferRecord> _records = {};

  @override
  Future<void> save(PersistentTransferRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<PersistentTransferRecord?> get(String id) async {
    return _records[id];
  }

  @override
  Future<List<PersistentTransferRecord>> getAll() async {
    return _records.values.toList();
  }

  @override
  Future<List<PersistentTransferRecord>> getActive() async {
    return _records.values.where((r) => r.isActive).toList();
  }

  @override
  Future<void> delete(String id) async {
    _records.remove(id);
  }

  @override
  Future<void> clear() async {
    _records.clear();
  }
}
