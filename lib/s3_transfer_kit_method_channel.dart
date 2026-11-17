import 'package:flutter/foundation.dart';

import 's3_transfer_kit_platform_interface.dart';
import 'src/messages.g.dart';

/// An implementation of [S3TransferKitPlatform] that uses Pigeon.
class MethodChannelS3TransferKit extends S3TransferKitPlatform {
  /// Constructs a [MethodChannelS3TransferKit].
  MethodChannelS3TransferKit({@visibleForTesting S3TransferKitHostApi? hostApi})
    : _hostApi = hostApi ?? S3TransferKitHostApi();

  final S3TransferKitHostApi _hostApi;

  @override
  Future<String?> getPlatformVersion() {
    return _hostApi.getPlatformVersion();
  }
}
