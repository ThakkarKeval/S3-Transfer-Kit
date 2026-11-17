import '../models/transfer_status.dart';
import '../multipart/s3_part_etag.dart';
import 'transfer_type.dart';

/// Represents a durable snapshot of a transfer's state for recovery across app restarts.
class PersistentTransferRecord {
  /// Constructs a [PersistentTransferRecord].
  const PersistentTransferRecord({
    required this.id,
    required this.type,
    required this.status,
    required this.filePath,
    required this.fileLength,
    required this.createdAt,
    required this.updatedAt,
    this.contentType,
    this.uploadId,
    this.partSize,
    this.completedParts = const <S3PartETag>[],
    this.metadata = const <String, dynamic>{},
  });

  /// Unique transfer identifier.
  final String id;

  /// The type of transfer operation.
  final TransferType type;

  /// Last known lifecycle status of the transfer.
  final TransferStatus status;

  /// Absolute file path on the local file system.
  final String filePath;

  /// Total size of the file in bytes.
  final int fileLength;

  /// Timestamp when the transfer was originally registered.
  final DateTime createdAt;

  /// Timestamp when the record was last modified.
  final DateTime updatedAt;

  /// MIME content type for uploads.
  final String? contentType;

  /// S3 multipart upload ID (if type is [TransferType.multipartUpload]).
  final String? uploadId;

  /// Size of each chunk in bytes for multipart uploads.
  final int? partSize;

  /// List of parts that have already been uploaded successfully and verified with ETags.
  final List<S3PartETag> completedParts;

  /// Arbitrary custom metadata associated with the transfer.
  final Map<String, dynamic> metadata;

  /// Whether the transfer is in an active (resumable or ongoing) state.
  bool get isActive =>
      status == TransferStatus.enqueued ||
      status == TransferStatus.inProgress ||
      status == TransferStatus.paused;

  /// Creates a copy of this record with the given fields replaced.
  PersistentTransferRecord copyWith({
    String? id,
    TransferType? type,
    TransferStatus? status,
    String? filePath,
    int? fileLength,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? contentType,
    String? uploadId,
    int? partSize,
    List<S3PartETag>? completedParts,
    Map<String, dynamic>? metadata,
  }) {
    return PersistentTransferRecord(
      id: id ?? this.id,
      type: type ?? this.type,
      status: status ?? this.status,
      filePath: filePath ?? this.filePath,
      fileLength: fileLength ?? this.fileLength,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      contentType: contentType ?? this.contentType,
      uploadId: uploadId ?? this.uploadId,
      partSize: partSize ?? this.partSize,
      completedParts: completedParts ?? this.completedParts,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Converts this record to a JSON map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'status': status.name,
      'filePath': filePath,
      'fileLength': fileLength,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      if (contentType != null) 'contentType': contentType,
      if (uploadId != null) 'uploadId': uploadId,
      if (partSize != null) 'partSize': partSize,
      'completedParts': completedParts
          .map((p) => {'partNumber': p.partNumber, 'eTag': p.eTag})
          .toList(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  /// Deserializes a [PersistentTransferRecord] from a JSON map.
  factory PersistentTransferRecord.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String;
    final statusName = json['status'] as String;

    final type = TransferType.values.firstWhere(
      (e) => e.name == typeName,
      orElse: () => TransferType.singleUpload,
    );

    final status = TransferStatus.values.firstWhere(
      (e) => e.name == statusName,
      orElse: () => TransferStatus.failed,
    );

    final partsRaw = json['completedParts'] as List<dynamic>? ?? const [];
    final completedParts = partsRaw
        .map(
          (p) => S3PartETag(
            partNumber: (p as Map<String, dynamic>)['partNumber'] as int,
            eTag: p['eTag'] as String,
          ),
        )
        .toList();

    return PersistentTransferRecord(
      id: json['id'] as String,
      type: type,
      status: status,
      filePath: json['filePath'] as String,
      fileLength: json['fileLength'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      contentType: json['contentType'] as String?,
      uploadId: json['uploadId'] as String?,
      partSize: json['partSize'] as int?,
      completedParts: completedParts,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
    );
  }
}
