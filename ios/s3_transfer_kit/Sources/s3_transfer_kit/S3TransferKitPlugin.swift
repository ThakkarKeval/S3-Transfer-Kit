import Flutter
import UIKit

public class S3TransferKitPlugin: NSObject, FlutterPlugin, S3TransferKitHostApi {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = S3TransferKitPlugin()
    S3TransferKitHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
  }

  public func getPlatformVersion() throws -> String? {
    return "iOS \(UIDevice.current.systemVersion)"
  }
}
