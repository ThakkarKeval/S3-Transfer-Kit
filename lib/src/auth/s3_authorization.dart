import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';
import 's3_credentials.dart';
import 'sigv4_signer.dart';

const _contentTypeHeader = 'content-type';
const _contentLengthHeader = 'content-length';

/// Represents an authorized HTTP request target with destination URL and required headers.
class AuthorizedHttpRequest {
  /// Constructs an [AuthorizedHttpRequest].
  const AuthorizedHttpRequest({
    required this.url,
    this.headers = const <String, String>{},
  });

  /// The target destination URL, optionally including query credentials (e.g. presigned URL).
  final Uri url;

  /// HTTP headers required for authorization or transfer metadata.
  final Map<String, String> headers;
}

/// Abstract contract for authorizing S3 requests.
///
/// Implementations supply either a presigned URL, AWS SigV4 signed headers from static or
/// dynamically refreshed temporary credentials (e.g. AWS Cognito or STS), or custom provider callbacks.
abstract class S3Authorization {
  /// Prepares the target URL and headers for a transfer operation.
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  });

  /// Whether this authorization strategy supports dynamic renewal when expired.
  bool get canRenew => false;

  /// Invalidates cached tokens or fetches fresh credentials from the provider.
  Future<void> renew() async {}

  /// Creates an authorization strategy using a pre-generated presigned URL.
  factory S3Authorization.presignedUrl(Uri url) = _PresignedUrlAuthorization;

  /// Creates an authorization strategy with a dynamic callback that fetches a presigned URL on demand.
  factory S3Authorization.presignedProvider(
    Future<Uri> Function() provider, {
    Duration expirationBuffer,
  }) = _DynamicPresignedProviderAuthorization;

  /// Creates an authorization strategy using static AWS IAM or S3 credentials with SigV4 signing.
  factory S3Authorization.sigV4({
    required Uri endpoint,
    required S3Credentials credentials,
    required String region,
    String service,
  }) = _StaticSigV4Authorization;

  /// Creates an authorization strategy using dynamic temporary credentials (such as AWS Cognito or STS).
  ///
  /// Automatically refreshes credentials when they are within [expirationBuffer] of expiring,
  /// or when authorization fails on the remote server.
  factory S3Authorization.cognito({
    required Uri endpoint,
    required Future<S3Credentials> Function() credentialsProvider,
    required String region,
    String service,
    Duration expirationBuffer,
  }) = _DynamicCredentialsAuthorization;

  /// Generic alias for dynamic credentials providers.
  factory S3Authorization.credentialsProvider({
    required Uri endpoint,
    required Future<S3Credentials> Function() credentialsProvider,
    required String region,
    String service,
    Duration expirationBuffer,
  }) = _DynamicCredentialsAuthorization;
}

class _PresignedUrlAuthorization implements S3Authorization {
  const _PresignedUrlAuthorization(this.url);

  final Uri url;

  @override
  bool get canRenew => false;

  @override
  Future<void> renew() async {}

  @override
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  }) async {
    return AuthorizedHttpRequest(
      url: url,
      headers: customHeaders ?? const <String, String>{},
    );
  }
}

class _DynamicPresignedProviderAuthorization implements S3Authorization {
  _DynamicPresignedProviderAuthorization(
    this.provider, {
    this.expirationBuffer = const Duration(seconds: 30),
  });

  final Future<Uri> Function() provider;
  final Duration expirationBuffer;
  Uri? _cachedUrl;

  @override
  bool get canRenew => true;

  @override
  Future<void> renew() async {
    _cachedUrl = null;
  }

  @override
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  }) async {
    try {
      final url = _cachedUrl ?? await provider();
      _cachedUrl = url;
      return AuthorizedHttpRequest(
        url: url,
        headers: customHeaders ?? const <String, String>{},
      );
    } catch (e, st) {
      throw TransferException(
        code: TransferErrorCode.authenticationExpired,
        message: 'Failed to retrieve presigned URL from provider: $e',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    }
  }
}

class _StaticSigV4Authorization implements S3Authorization {
  _StaticSigV4Authorization({
    required this.endpoint,
    required this.credentials,
    required this.region,
    this.service = 's3',
  }) : _signer = SigV4Signer(region: region, service: service);

  final Uri endpoint;
  final S3Credentials credentials;
  final String region;
  final String service;
  final SigV4Signer _signer;

  @override
  bool get canRenew => false;

  @override
  Future<void> renew() async {}

  @override
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  }) async {
    final headersToSign = Map<String, String>.from(customHeaders ?? {});
    if (contentType.isNotEmpty) {
      headersToSign[_contentTypeHeader] = contentType;
    }
    if (contentLength > 0) {
      headersToSign[_contentLengthHeader] = contentLength.toString();
    }

    final signedHeaders = _signer.sign(
      method: method,
      url: endpoint,
      credentials: credentials,
      headers: headersToSign,
    );

    return AuthorizedHttpRequest(url: endpoint, headers: signedHeaders);
  }
}

class _DynamicCredentialsAuthorization implements S3Authorization {
  _DynamicCredentialsAuthorization({
    required this.endpoint,
    required this.credentialsProvider,
    required this.region,
    this.service = 's3',
    this.expirationBuffer = const Duration(minutes: 5),
  }) : _signer = SigV4Signer(region: region, service: service);

  final Uri endpoint;
  final Future<S3Credentials> Function() credentialsProvider;
  final String region;
  final String service;
  final Duration expirationBuffer;
  final SigV4Signer _signer;

  S3Credentials? _cachedCredentials;

  @override
  bool get canRenew => true;

  @override
  Future<void> renew() async {
    _cachedCredentials = null;
  }

  Future<S3Credentials> _getEffectiveCredentials() async {
    final cached = _cachedCredentials;
    if (cached != null && !cached.isExpired(buffer: expirationBuffer)) {
      return cached;
    }

    try {
      final creds = await credentialsProvider();
      _cachedCredentials = creds;
      return creds;
    } catch (e, st) {
      throw TransferException(
        code: TransferErrorCode.authenticationExpired,
        message: 'Failed to obtain fresh S3 credentials: $e',
        cause: e,
        stackTrace: st,
        isRetryable: true,
      );
    }
  }

  @override
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  }) async {
    final creds = await _getEffectiveCredentials();

    final headersToSign = Map<String, String>.from(customHeaders ?? {});
    if (contentType.isNotEmpty) {
      headersToSign[_contentTypeHeader] = contentType;
    }
    if (contentLength > 0) {
      headersToSign[_contentLengthHeader] = contentLength.toString();
    }

    final signedHeaders = _signer.sign(
      method: method,
      url: endpoint,
      credentials: creds,
      headers: headersToSign,
    );

    return AuthorizedHttpRequest(url: endpoint, headers: signedHeaders);
  }
}
