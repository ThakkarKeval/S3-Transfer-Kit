import Cocoa
import FlutterMacOS

public class S3TransferKitPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "s3_transfer_kit", binaryMessenger: registrar.messenger)
    let instance = S3TransferKitPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
