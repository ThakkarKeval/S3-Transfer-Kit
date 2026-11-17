import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

class _FakeRenewableTransport implements TransferTransport {
  int uploadAttempts = 0;
  int downloadAttempts = 0;
  bool returnAuthErrorOnFirstAttempt = true;

  @override
  Future<S3UploadResult> upload(
    S3UploadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    uploadAttempts++;
    final auth = await request.authorization.authorize(
      method: 'PUT',
      contentType: request.contentType,
      contentLength: 100,
    );

    if (returnAuthErrorOnFirstAttempt && uploadAttempts == 1) {
      throw TransferException(
        code: TransferErrorCode.authenticationExpired,
        message: 'ExpiredToken: The provided token has expired',
        httpStatusCode: 403,
      );
    }

    onStatusChanged(TransferStatus.completed);
    return S3UploadResult(
      bytesTransferred: 100,
      eTag: 'etag_success',
      responseHeaders: auth.headers,
    );
  }

  @override
  Future<S3DownloadResult> download(
    S3DownloadRequest request, {
    required void Function(TransferProgress) onProgress,
    required void Function(TransferStatus) onStatusChanged,
  }) async {
    downloadAttempts++;
    final auth = await request.authorization.authorize(
      method: 'GET',
      contentType: '',
      contentLength: 0,
    );

    if (returnAuthErrorOnFirstAttempt && downloadAttempts == 1) {
      throw TransferException(
        code: TransferErrorCode.authenticationExpired,
        message: 'ExpiredToken: The provided token has expired',
        httpStatusCode: 403,
      );
    }

    onStatusChanged(TransferStatus.completed);
    return S3DownloadResult(
      destinationPath: request.destinationPath,
      bytesTransferred: 100,
      eTag: 'down_etag_success',
      responseHeaders: auth.headers,
    );
  }
}

void main() {
  group('S3Credentials', () {
    test('isExpired detects expiration with buffer', () {
      final now = DateTime.now();
      final expiredCreds = S3Credentials(
        accessKeyId: 'AKIA_EXPIRED',
        secretAccessKey: 'secret_1',
        expiration: now.subtract(const Duration(minutes: 1)),
      );
      expect(expiredCreds.isExpired(), isTrue);

      final expiringSoonCreds = S3Credentials(
        accessKeyId: 'AKIA_SOON',
        secretAccessKey: 'secret_2',
        expiration: now.add(const Duration(minutes: 2)),
      );
      // Without buffer, it is not yet expired
      expect(expiringSoonCreds.isExpired(), isFalse);
      // With 5 minute buffer, it is considered expired
      expect(
        expiringSoonCreds.isExpired(buffer: const Duration(minutes: 5)),
        isTrue,
      );

      final staticCreds = const S3Credentials(
        accessKeyId: 'AKIA_STATIC',
        secretAccessKey: 'secret_3',
      );
      expect(
        staticCreds.isExpired(buffer: const Duration(minutes: 60)),
        isFalse,
      );
    });
  });

  group('SigV4Signer', () {
    test('generates valid AWS4-HMAC-SHA256 headers', () {
      const signer = SigV4Signer(region: 'us-west-2');
      final creds = const S3Credentials(
        accessKeyId: 'ASIAEXAMPLEKEY',
        secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        sessionToken: 'token123_session',
      );

      final url = Uri.parse(
        'https://mybucket.s3.us-west-2.amazonaws.com/photos/image.jpg?param2=b&param1=a',
      );
      final fixedDate = DateTime.utc(2026, 11, 17, 12, 0, 0);

      final headers = signer.sign(
        method: 'PUT',
        url: url,
        credentials: creds,
        headers: {'content-type': 'image/jpeg'},
        timestamp: fixedDate,
      );

      expect(headers['host'], equals('mybucket.s3.us-west-2.amazonaws.com'));
      expect(headers['x-amz-date'], equals('20261117T120000Z'));
      expect(headers['x-amz-content-sha256'], equals('UNSIGNED-PAYLOAD'));
      expect(headers['x-amz-security-token'], equals('token123_session'));
      expect(headers['content-type'], equals('image/jpeg'));

      final auth = headers['authorization']!;
      expect(
        auth,
        startsWith(
          'AWS4-HMAC-SHA256 Credential=ASIAEXAMPLEKEY/20261117/us-west-2/s3/aws4_request',
        ),
      );
      expect(
        auth,
        contains(
          'SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token',
        ),
      );
      expect(auth, contains('Signature='));
    });
  });

  group('S3Authorization Strategies', () {
    test('presignedUrl strategy does not allow renewal', () async {
      final auth = S3Authorization.presignedUrl(
        Uri.parse('https://example.com/presigned'),
      );
      expect(auth.canRenew, isFalse);

      final req = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 50,
      );
      expect(req.url.toString(), equals('https://example.com/presigned'));
    });

    test('presignedProvider allows renewal and refreshes URL', () async {
      int callCount = 0;
      final auth = S3Authorization.presignedProvider(() async {
        callCount++;
        return Uri.parse('https://example.com/url_v$callCount');
      });

      expect(auth.canRenew, isTrue);

      final req1 = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 50,
      );
      expect(req1.url.toString(), equals('https://example.com/url_v1'));

      // Cached on immediate next call
      final req1Cached = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 50,
      );
      expect(req1Cached.url.toString(), equals('https://example.com/url_v1'));
      expect(callCount, equals(1));

      // Force renew
      await auth.renew();
      final req2 = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 50,
      );
      expect(req2.url.toString(), equals('https://example.com/url_v2'));
      expect(callCount, equals(2));
    });

    test('cognito dynamic credentials auto-refreshes when expired', () async {
      int providerCalls = 0;
      final auth = S3Authorization.cognito(
        endpoint: Uri.parse('https://mybucket.s3.amazonaws.com/file.txt'),
        region: 'us-east-1',
        expirationBuffer: const Duration(minutes: 5),
        credentialsProvider: () async {
          providerCalls++;
          return S3Credentials(
            accessKeyId: 'AKIA_COGNITO_$providerCalls',
            secretAccessKey: 'secret_$providerCalls',
            expiration: DateTime.now().add(
              const Duration(minutes: 2),
            ), // Under 5 min buffer!
          );
        },
      );

      expect(auth.canRenew, isTrue);

      final req1 = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 100,
      );
      expect(req1.headers['authorization'], contains('AKIA_COGNITO_1'));
      expect(providerCalls, equals(1));

      // Because expiration was 2 mins and buffer was 5 mins, next call detects expired buffer and refreshes!
      final req2 = await auth.authorize(
        method: 'PUT',
        contentType: 'text/plain',
        contentLength: 100,
      );
      expect(req2.headers['authorization'], contains('AKIA_COGNITO_2'));
      expect(providerCalls, equals(2));
    });
  });

  group('Auto-Renewal with RetryingTransport', () {
    test(
      'automatically renews credentials and retries on ExpiredToken',
      () async {
        int credentialFetches = 0;
        final fakeTransport = _FakeRenewableTransport();
        final retryingTransport = RetryingTransport(
          fakeTransport,
          defaultRetryPolicy: const RetryPolicy(maxAttempts: 3),
        );

        final auth = S3Authorization.cognito(
          endpoint: Uri.parse('https://bucket.s3.amazonaws.com/doc.pdf'),
          region: 'us-east-1',
          credentialsProvider: () async {
            credentialFetches++;
            return S3Credentials(
              accessKeyId: 'AKIA_TOKEN_$credentialFetches',
              secretAccessKey: 'sec_$credentialFetches',
            );
          },
        );

        final result = await retryingTransport.upload(
          S3UploadRequest(filePath: '/dummy/doc.pdf', authorization: auth),
          onProgress: (_) {},
          onStatusChanged: (_) {},
        );

        // Attempt 1 failed with expired token, RetryingTransport called auth.renew(), attempt 2 succeeded!
        expect(fakeTransport.uploadAttempts, equals(2));
        expect(credentialFetches, equals(2));
        expect(result.eTag, equals('etag_success'));
      },
    );

    test(
      'does not retry authenticationExpired if authorization cannot renew',
      () async {
        final fakeTransport = _FakeRenewableTransport();
        final retryingTransport = RetryingTransport(
          fakeTransport,
          defaultRetryPolicy: const RetryPolicy(maxAttempts: 3),
        );

        final auth = S3Authorization.presignedUrl(
          Uri.parse('https://bucket.s3.amazonaws.com/doc.pdf'),
        );

        expect(
          () => retryingTransport.upload(
            S3UploadRequest(filePath: '/dummy/doc.pdf', authorization: auth),
            onProgress: (_) {},
            onStatusChanged: (_) {},
          ),
          throwsA(
            isA<TransferException>().having(
              (e) => e.code,
              'code',
              equals(TransferErrorCode.authenticationExpired),
            ),
          ),
        );

        // Only 1 attempt because static URL cannot renew
        expect(fakeTransport.uploadAttempts, equals(1));
      },
    );
  });

  group('S3ProviderProfile', () {
    test('AWS S3 builds virtual-host URL', () {
      final profile = S3ProviderProfile.awsS3(region: 'eu-west-1');
      final url = profile.buildObjectUrl(
        bucket: 'my-bucket',
        key: 'folder/file.png',
      );
      expect(
        url.toString(),
        equals('https://my-bucket.s3.eu-west-1.amazonaws.com/folder/file.png'),
      );
    });

    test('Cloudflare R2 builds correct R2 URL', () {
      final profile = S3ProviderProfile.cloudflareR2(accountId: 'acc123456');
      final url = profile.buildObjectUrl(bucket: 'assets', key: 'video.mp4');
      expect(
        url.toString(),
        equals('https://assets.acc123456.r2.cloudflarestorage.com/video.mp4'),
      );
      expect(profile.region, equals('auto'));
    });

    test('MinIO builds path-style URL', () {
      final profile = S3ProviderProfile.minio(
        endpoint: Uri.parse('http://192.168.1.100:9000'),
      );
      final url = profile.buildObjectUrl(bucket: 'data', key: 'report.csv');
      expect(
        url.toString(),
        equals('http://192.168.1.100:9000/data/report.csv'),
      );
    });

    test('Wasabi builds Wasabi region URL', () {
      final profile = S3ProviderProfile.wasabi(region: 'us-central-1');
      final url = profile.buildObjectUrl(bucket: 'backups', key: 'db.tar.gz');
      expect(
        url.toString(),
        equals('https://backups.s3.us-central-1.wasabisys.com/db.tar.gz'),
      );
    });

    test('Backblaze B2 builds B2 S3 endpoint URL', () {
      final profile = S3ProviderProfile.backblazeB2(region: 'us-west-004');
      final url = profile.buildObjectUrl(bucket: 'media', key: 'track.mp3');
      expect(
        url.toString(),
        equals('https://media.s3.us-west-004.backblazeb2.com/track.mp3'),
      );
    });

    test('profile helper creates SigV4 authorization', () async {
      final profile = S3ProviderProfile.cloudflareR2(accountId: 'test_acc');
      final objectUrl = profile.buildObjectUrl(bucket: 'b', key: 'k');
      final auth = profile.createSigV4Authorization(
        objectUrl: objectUrl,
        credentials: const S3Credentials(
          accessKeyId: 'R2_ACCESS',
          secretAccessKey: 'R2_SECRET',
        ),
      );

      final req = await auth.authorize(
        method: 'PUT',
        contentType: 'application/json',
        contentLength: 200,
      );

      expect(
        req.headers['authorization'],
        contains('AWS4-HMAC-SHA256 Credential=R2_ACCESS/'),
      );
      expect(req.headers['authorization'], contains('/auto/s3/aws4_request'));
    });
  });
}
