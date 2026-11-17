import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  group('S3Authorization', () {
    test('presignedUrl passes through URL and custom headers', () async {
      final url = Uri.parse('https://example.com/upload?key=val');
      final auth = S3Authorization.presignedUrl(url);

      final result = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 100,
        customHeaders: {'x-custom': 'header'},
      );

      expect(result.url, url);
      expect(result.headers['x-custom'], 'header');
    });

    test('presignedProvider resolves dynamic URL on demand', () async {
      final expectedUrl = Uri.parse('https://example.com/dynamic-url');
      var callCount = 0;

      final auth = S3Authorization.presignedProvider(() async {
        callCount++;
        return expectedUrl;
      });

      final result = await auth.authorize(
        method: 'PUT',
        contentType: 'application/json',
        contentLength: 50,
      );

      expect(callCount, 1);
      expect(result.url, expectedUrl);
    });

    test(
      'presignedProvider maps provider errors to TransferException',
      () async {
        final auth = S3Authorization.presignedProvider(() async {
          throw Exception('Network failed while fetching token');
        });

        expect(
          () => auth.authorize(
            method: 'PUT',
            contentType: 'application/json',
            contentLength: 50,
          ),
          throwsA(
            isA<TransferException>().having(
              (e) => e.code,
              'code',
              TransferErrorCode.authenticationExpired,
            ),
          ),
        );
      },
    );
  });
}
