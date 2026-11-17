/// Holds the part index and S3 ETag verification token for a completed part.
class S3PartETag implements Comparable<S3PartETag> {
  /// Constructs an [S3PartETag].
  const S3PartETag({required this.partNumber, required this.eTag});

  /// 1-based part index.
  final int partNumber;

  /// The MD5-based ETag returned in the S3 response headers for this part.
  final String eTag;

  /// Converts this part ETag into a map suitable for JSON serialization.
  Map<String, dynamic> toJson() => {'partNumber': partNumber, 'eTag': eTag};

  @override
  int compareTo(S3PartETag other) => partNumber.compareTo(other.partNumber);

  @override
  String toString() => 'S3PartETag(part: $partNumber, eTag: $eTag)';
}
