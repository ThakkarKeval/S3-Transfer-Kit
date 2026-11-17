import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 's3_transfer_kit_method_channel.dart';

abstract class S3TransferKitPlatform extends PlatformInterface {
  /// Constructs an [S3TransferKitPlatform].
  S3TransferKitPlatform() : super(token: _token);

  static final Object _token = Object();

  static S3TransferKitPlatform _instance = MethodChannelS3TransferKit();

  /// The default instance of [S3TransferKitPlatform] to use.
  ///
  /// Defaults to [MethodChannelS3TransferKit].
  static S3TransferKitPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [S3TransferKitPlatform] when
  /// they register themselves.
  static set instance(S3TransferKitPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the platform operating system version string.
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// Checks whether native background transfers are supported by the current platform.
  Future<bool> isBackgroundTransferSupported() {
    throw UnimplementedError(
      'isBackgroundTransferSupported() has not been implemented.',
    );
  }
}
