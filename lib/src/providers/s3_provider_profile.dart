import '../auth/s3_authorization.dart';
import '../auth/s3_credentials.dart';

/// Predefined profiles and URL builders for Amazon S3 and compatible storage providers.
class S3ProviderProfile {
  /// Constructs an [S3ProviderProfile].
  const S3ProviderProfile({
    required this.name,
    required this.endpoint,
    required this.region,
    this.pathStyle = false,
  });

  /// The name of the storage provider (e.g. AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2).
  final String name;

  /// Root endpoint URL for the object storage cluster.
  final Uri endpoint;

  /// Default region for AWS SigV4 signing.
  final String region;

  /// Whether requests use path-style addressing (`https://endpoint/bucket/key`)
  /// instead of virtual-host addressing (`https://bucket.endpoint/key`).
  final bool pathStyle;

  /// Profile configured for Amazon Web Services (AWS) S3.
  factory S3ProviderProfile.awsS3({
    String region = 'us-east-1',
    bool pathStyle = false,
  }) {
    final host = region == 'us-east-1'
        ? 's3.amazonaws.com'
        : 's3.$region.amazonaws.com';
    return S3ProviderProfile(
      name: 'AWS S3',
      endpoint: Uri.parse('https://$host'),
      region: region,
      pathStyle: pathStyle,
    );
  }

  /// Profile configured for Cloudflare R2 object storage.
  factory S3ProviderProfile.cloudflareR2({required String accountId}) {
    return S3ProviderProfile(
      name: 'Cloudflare R2',
      endpoint: Uri.parse('https://$accountId.r2.cloudflarestorage.com'),
      region: 'auto',
      pathStyle: false,
    );
  }

  /// Profile configured for self-hosted or local MinIO instances.
  factory S3ProviderProfile.minio({
    required Uri endpoint,
    String region = 'us-east-1',
    bool pathStyle = true,
  }) {
    return S3ProviderProfile(
      name: 'MinIO',
      endpoint: endpoint,
      region: region,
      pathStyle: pathStyle,
    );
  }

  /// Profile configured for Wasabi Hot Cloud Storage.
  factory S3ProviderProfile.wasabi({
    String region = 'us-east-1',
    bool pathStyle = false,
  }) {
    final host = region == 'us-east-1'
        ? 's3.wasabisys.com'
        : 's3.$region.wasabisys.com';
    return S3ProviderProfile(
      name: 'Wasabi',
      endpoint: Uri.parse('https://$host'),
      region: region,
      pathStyle: pathStyle,
    );
  }

  /// Profile configured for Backblaze B2 Cloud Storage S3 Compatible API.
  factory S3ProviderProfile.backblazeB2({
    required String region,
    bool pathStyle = false,
  }) {
    return S3ProviderProfile(
      name: 'Backblaze B2',
      endpoint: Uri.parse('https://s3.$region.backblazeb2.com'),
      region: region,
      pathStyle: pathStyle,
    );
  }

  /// Builds the complete URL for an object located at [key] in [bucket].
  Uri buildObjectUrl({required String bucket, required String key}) {
    final cleanKey = key.startsWith('/') ? key.substring(1) : key;

    if (pathStyle) {
      final basePath = endpoint.path.endsWith('/')
          ? endpoint.path.substring(0, endpoint.path.length - 1)
          : endpoint.path;
      return endpoint.replace(path: '$basePath/$bucket/$cleanKey');
    } else {
      final host = '$bucket.${endpoint.host}';
      return endpoint.replace(host: host, path: '/$cleanKey');
    }
  }

  /// Creates a static AWS SigV4 authorization for an object URL.
  S3Authorization createSigV4Authorization({
    required Uri objectUrl,
    required S3Credentials credentials,
    String service = 's3',
  }) {
    return S3Authorization.sigV4(
      endpoint: objectUrl,
      credentials: credentials,
      region: region,
      service: service,
    );
  }

  /// Creates a dynamic Cognito or STS authorization for an object URL with auto-renewal.
  S3Authorization createCognitoAuthorization({
    required Uri objectUrl,
    required Future<S3Credentials> Function() credentialsProvider,
    String service = 's3',
    Duration expirationBuffer = const Duration(minutes: 5),
  }) {
    return S3Authorization.cognito(
      endpoint: objectUrl,
      credentialsProvider: credentialsProvider,
      region: region,
      service: service,
      expirationBuffer: expirationBuffer,
    );
  }
}
