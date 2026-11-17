import '../exceptions/transfer_error_code.dart';
import '../exceptions/transfer_exception.dart';

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
/// Implementations supply either a presigned URL, Cognito STS signed headers,
/// or dynamically refreshed authorization tokens.
abstract class S3Authorization {
  /// Prepares the target URL and headers for a transfer operation.
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  });

  /// Creates an authorization strategy using a pre-generated presigned URL.
  factory S3Authorization.presignedUrl(Uri url) = _PresignedUrlAuthorization;

  /// Creates an authorization strategy with a dynamic callback that fetches a presigned URL on demand.
  factory S3Authorization.presignedProvider(Future<Uri> Function() provider) =
      _DynamicPresignedProviderAuthorization;
}

class _PresignedUrlAuthorization implements S3Authorization {
  const _PresignedUrlAuthorization(this.url);

  final Uri url;

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
  const _DynamicPresignedProviderAuthorization(this.provider);

  final Future<Uri> Function() provider;

  @override
  Future<AuthorizedHttpRequest> authorize({
    required String method,
    required String contentType,
    required int contentLength,
    Map<String, String>? customHeaders,
  }) async {
    try {
      final url = await provider();
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
