#ifndef FLUTTER_PLUGIN_S3_TRANSFER_KIT_PLUGIN_H_
#define FLUTTER_PLUGIN_S3_TRANSFER_KIT_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace s3_transfer_kit {

class S3TransferKitPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  S3TransferKitPlugin();

  virtual ~S3TransferKitPlugin();

  // Disallow copy and assign.
  S3TransferKitPlugin(const S3TransferKitPlugin&) = delete;
  S3TransferKitPlugin& operator=(const S3TransferKitPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace s3_transfer_kit

#endif  // FLUTTER_PLUGIN_S3_TRANSFER_KIT_PLUGIN_H_
