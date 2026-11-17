import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 's3_transfer_kit_platform_interface.dart';

/// A web implementation of the S3TransferKitPlatform of the S3TransferKit plugin.
class S3TransferKitWeb extends S3TransferKitPlatform {
  /// Constructs an [S3TransferKitWeb].
  S3TransferKitWeb();

  static void registerWith(Registrar registrar) {
    S3TransferKitPlatform.instance = S3TransferKitWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async => web.window.navigator.userAgent;
}
