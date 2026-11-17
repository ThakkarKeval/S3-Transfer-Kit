import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/src/utils/url_sanitizer.dart';

void main() {
  group('UrlSanitizer', () {
    test('redacts AWS query parameters from URL', () {
      final sensitiveUri = Uri.parse(
        'https://my-bucket.s3.amazonaws.com/data.bin'
        '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
        '&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261117%2Fus-east-1%2Fs3%2Faws4_request'
        '&X-Amz-Date=20261117T120000Z'
        '&X-Amz-Signature=d2c2007807f406057112b3218b30e37dff477e814f4ec450577f64f93a49b379'
        '&X-Amz-Security-Token=AQoDYXdzEJr111'
        '&partNumber=1',
      );

      final sanitized = UrlSanitizer.sanitizeUri(sensitiveUri);

      expect(sanitized.queryParameters['X-Amz-Signature'], '[REDACTED]');
      expect(sanitized.queryParameters['X-Amz-Credential'], '[REDACTED]');
      expect(sanitized.queryParameters['X-Amz-Security-Token'], '[REDACTED]');
      expect(sanitized.queryParameters['partNumber'], '1');
      expect(sanitized.queryParameters['X-Amz-Date'], '20261117T120000Z');
      expect(
        sanitized.toString().contains(
          'd2c2007807f406057112b3218b30e37dff477e814f4ec450577f64f93a49b379',
        ),
        isFalse,
      );
    });

    test('redacts sensitive headers', () {
      final headers = {
        'Content-Type': 'image/jpeg',
        'Authorization': 'AWS4-HMAC-SHA256 Credential=secret/token',
        'x-amz-security-token': 'super-secret-token',
        'x-amz-acl': 'public-read',
      };

      final sanitized = UrlSanitizer.sanitizeHeaders(headers);

      expect(sanitized['Authorization'], '[REDACTED]');
      expect(sanitized['x-amz-security-token'], '[REDACTED]');
      expect(sanitized['Content-Type'], 'image/jpeg');
      expect(sanitized['x-amz-acl'], 'public-read');
    });

    test('handles URLs without query parameters', () {
      final uri = Uri.parse('https://example.com/file.txt');
      expect(UrlSanitizer.sanitizeUri(uri), uri);
    });
  });
}
