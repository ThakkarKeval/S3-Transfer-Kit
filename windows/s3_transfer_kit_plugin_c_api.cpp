#include "include/s3_transfer_kit/s3_transfer_kit_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "s3_transfer_kit_plugin.h"

void S3TransferKitPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  s3_transfer_kit::S3TransferKitPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
