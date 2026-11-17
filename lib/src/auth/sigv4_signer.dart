import 'dart:convert';

import 'package:crypto/crypto.dart';

import 's3_credentials.dart';

/// Implements standard AWS Signature Version 4 (SigV4) request signing for S3 and compatible storage services.
class SigV4Signer {
  /// Constructs a [SigV4Signer].
  const SigV4Signer({required this.region, this.service = 's3'});

  /// AWS or provider region (e.g. 'us-east-1', 'auto').
  final String region;

  /// Service name (defaults to 's3').
  final String service;

  /// Signs an HTTP request and returns the headers required for AWS SigV4 authentication.
  Map<String, String> sign({
    required String method,
    required Uri url,
    required S3Credentials credentials,
    Map<String, String>? headers,
    DateTime? timestamp,
    String payloadHash = 'UNSIGNED-PAYLOAD',
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    final amzDate = _formatAmzDate(now);
    final dateStamp = _formatDateStamp(now);

    final signedHeadersMap = <String, String>{};
    if (headers != null) {
      for (final entry in headers.entries) {
        signedHeadersMap[entry.key.toLowerCase().trim()] = entry.value.trim();
      }
    }

    // Set standard AWS headers
    signedHeadersMap['host'] = url.hasPort
        ? '${url.host}:${url.port}'
        : url.host;
    signedHeadersMap['x-amz-date'] = amzDate;
    signedHeadersMap['x-amz-content-sha256'] = payloadHash;

    if (credentials.sessionToken != null &&
        credentials.sessionToken!.isNotEmpty) {
      signedHeadersMap['x-amz-security-token'] = credentials.sessionToken!;
    }

    // 1. Canonical Headers & Signed Headers
    final sortedHeaderKeys = signedHeadersMap.keys.toList()..sort();
    final canonicalHeaders = sortedHeaderKeys
        .map((k) => '$k:${signedHeadersMap[k]!}\n')
        .join();
    final signedHeaders = sortedHeaderKeys.join(';');

    // 2. Canonical URI
    final canonicalUri = url.path.isEmpty
        ? '/'
        : Uri.encodeFull(url.path).replaceAll('+', '%20');

    // 3. Canonical Query String
    final canonicalQuery = _buildCanonicalQuery(url.queryParametersAll);

    // 4. Canonical Request
    final canonicalRequest = [
      method.toUpperCase(),
      canonicalUri,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final canonicalRequestHash = sha256
        .convert(utf8.encode(canonicalRequest))
        .toString();

    // 5. String to Sign
    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      canonicalRequestHash,
    ].join('\n');

    // 6. Calculate Signature
    final signingKey = _deriveSigningKey(
      credentials.secretAccessKey,
      dateStamp,
      region,
      service,
    );
    final signature = Hmac(
      sha256,
      signingKey,
    ).convert(utf8.encode(stringToSign)).toString();

    // 7. Authorization Header
    final authHeader =
        'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$credentialScope, SignedHeaders=$signedHeaders, Signature=$signature';

    final resultHeaders = Map<String, String>.from(signedHeadersMap);
    resultHeaders['authorization'] = authHeader;

    return resultHeaders;
  }

  List<int> _deriveSigningKey(
    String secretKey,
    String dateStamp,
    String region,
    String service,
  ) {
    final kSecret = utf8.encode('AWS4$secretKey');
    final kDate = Hmac(sha256, kSecret).convert(utf8.encode(dateStamp)).bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode(service)).bytes;
    return Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
  }

  String _buildCanonicalQuery(Map<String, List<String>> queryParametersAll) {
    if (queryParametersAll.isEmpty) return '';

    final sortedKeys = queryParametersAll.keys.toList()..sort();
    final queryPairs = <String>[];

    for (final key in sortedKeys) {
      final values = queryParametersAll[key] ?? const [];
      final encodedKey = Uri.encodeComponent(key);
      if (values.isEmpty) {
        queryPairs.add('$encodedKey=');
      } else {
        final sortedValues = List<String>.from(values)..sort();
        for (final val in sortedValues) {
          queryPairs.add('$encodedKey=${Uri.encodeComponent(val)}');
        }
      }
    }

    return queryPairs.join('&');
  }

  String _formatAmzDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y$m${d}T$h$min${s}Z';
  }

  String _formatDateStamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }
}
