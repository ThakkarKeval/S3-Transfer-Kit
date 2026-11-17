import 's3_transfer_kit_platform_interface.dart';

/// Provides access to the platform implementation of the S3 Transfer Kit plugin.
class S3TransferKit {
  /// Returns the platform version reported by the registered implementation.
  Future<String?> getPlatformVersion() =>
      S3TransferKitPlatform.instance.getPlatformVersion();
}
