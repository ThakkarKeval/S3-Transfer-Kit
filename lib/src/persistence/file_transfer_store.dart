import 'dart:convert';
import 'dart:io';

import 'persistent_transfer_record.dart';
import 'transfer_store.dart';

/// File-system backed implementation of [TransferStore] providing durable persistence across restarts.
///
/// Uses atomic write operations (writing to a temporary file then renaming) to prevent corruption during unexpected shutdowns.
class FileTransferStore implements TransferStore {
  /// Constructs a [FileTransferStore] storing transfer records in [directory].
  FileTransferStore(this.directory);

  /// Root directory for persisting transfer records.
  final Directory directory;

  Future<void> _ensureDirectoryExists() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  File _recordFile(String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.json');
  File _tempFile(String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.json.tmp');

  @override
  Future<void> save(PersistentTransferRecord record) async {
    await _ensureDirectoryExists();

    final targetFile = _recordFile(record.id);
    final tempFile = _tempFile(record.id);

    final jsonString = jsonEncode(record.toJson());
    await tempFile.writeAsString(jsonString, flush: true);

    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(targetFile.path);
  }

  @override
  Future<PersistentTransferRecord?> get(String id) async {
    final file = _recordFile(id);
    if (!await file.exists()) {
      return null;
    }

    try {
      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      return PersistentTransferRecord.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<PersistentTransferRecord>> getAll() async {
    if (!await directory.exists()) {
      return [];
    }

    final records = <PersistentTransferRecord>[];
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final map = jsonDecode(content) as Map<String, dynamic>;
          records.add(PersistentTransferRecord.fromJson(map));
        } catch (_) {
          // Skip corrupt or unreadable files
        }
      }
    }

    records.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return records;
  }

  @override
  Future<List<PersistentTransferRecord>> getActive() async {
    final all = await getAll();
    return all.where((r) => r.isActive).toList();
  }

  @override
  Future<void> delete(String id) async {
    final target = _recordFile(id);
    if (await target.exists()) {
      await target.delete();
    }
    final temp = _tempFile(id);
    if (await temp.exists()) {
      await temp.delete();
    }
  }

  @override
  Future<void> clear() async {
    if (!await directory.exists()) {
      return;
    }

    await for (final entity in directory.list()) {
      if (entity is File &&
          (entity.path.endsWith('.json') || entity.path.endsWith('.tmp'))) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}
