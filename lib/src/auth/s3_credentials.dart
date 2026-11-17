/// Represents AWS or S3-compatible IAM/Cognito/STS credentials.
class S3Credentials {
  /// Constructs an [S3Credentials] object.
  const S3Credentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
    this.expiration,
  });

  /// AWS access key ID.
  final String accessKeyId;

  /// AWS secret access key.
  final String secretAccessKey;

  /// Security token required for temporary credentials (e.g. from AWS STS, Cognito, or IAM roles).
  final String? sessionToken;

  /// Expiration timestamp of temporary credentials, if applicable.
  final DateTime? expiration;

  /// Whether these credentials are expired or within [buffer] of expiring.
  bool isExpired({Duration buffer = Duration.zero}) {
    if (expiration == null) return false;
    final now = DateTime.now();
    return now.isAfter(expiration!.subtract(buffer));
  }
}
