/// Utility for sanitizing sensitive credentials from URLs and headers.
class UrlSanitizer {
  UrlSanitizer._();

  static const _sensitiveQueryParams = {
    'x-amz-signature',
    'x-amz-credential',
    'x-amz-security-token',
    'x-amz-server-side-encryption-customer-key',
    'signature',
    'token',
    'sig',
  };

  static const _sensitiveHeaders = {
    'authorization',
    'x-amz-security-token',
    'x-amz-server-side-encryption-customer-key',
    'cookie',
  };

  /// Sanitizes a [Uri] by replacing sensitive query parameter values with `[REDACTED]`.
  static Uri sanitizeUri(Uri uri) {
    if (uri.queryParameters.isEmpty) return uri;

    final sanitizedParams = <String, String>{};
    for (final entry in uri.queryParameters.entries) {
      if (_sensitiveQueryParams.contains(entry.key.toLowerCase())) {
        sanitizedParams[entry.key] = '[REDACTED]';
      } else {
        sanitizedParams[entry.key] = entry.value;
      }
    }

    return uri.replace(queryParameters: sanitizedParams);
  }

  /// Sanitizes HTTP headers by replacing sensitive header values with `[REDACTED]`.
  static Map<String, String> sanitizeHeaders(Map<String, String> headers) {
    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      if (_sensitiveHeaders.contains(entry.key.toLowerCase())) {
        sanitized[entry.key] = '[REDACTED]';
      } else {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized;
  }
}
