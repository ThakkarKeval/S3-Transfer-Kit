/// Metadata describing a single byte slice in a multipart transfer.
class S3Part {
  /// Constructs an [S3Part].
  const S3Part({
    required this.partNumber,
    required this.startByte,
    required this.endByte,
    required this.length,
  }) : assert(partNumber >= 1, 'partNumber must be >= 1'),
       assert(startByte >= 0, 'startByte must be >= 0'),
       assert(endByte >= startByte, 'endByte must be >= startByte'),
       assert(length > 0, 'length must be > 0');

  /// 1-based part index as required by S3 specification.
  final int partNumber;

  /// Inclusive start byte offset in the source file.
  final int startByte;

  /// Exclusive end byte offset in the source file.
  final int endByte;

  /// Total number of bytes in this part.
  final int length;

  @override
  String toString() =>
      'S3Part(number: $partNumber, bytes: $startByte-$endByte, length: $length)';
}
