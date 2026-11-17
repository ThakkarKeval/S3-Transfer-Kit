package com.cavernlabs.s3.transfer.kit.s3_transfer_kit

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** S3TransferKitPlugin */
class S3TransferKitPlugin : FlutterPlugin, S3TransferKitHostApi {
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        S3TransferKitHostApi.setUp(flutterPluginBinding.binaryMessenger, this)
    }

    override fun getPlatformVersion(): String {
        return "Android ${android.os.Build.VERSION.RELEASE}"
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        S3TransferKitHostApi.setUp(binding.binaryMessenger, null)
    }
}
