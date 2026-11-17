import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 's3_transfer_kit_platform_interface.dart';

/// An implementation of [S3TransferKitPlatform] that uses method channels.
class MethodChannelS3TransferKit extends S3TransferKitPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('s3_transfer_kit');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
