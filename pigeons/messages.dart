import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/cavernlabs/s3/transfer/kit/s3_transfer_kit/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.cavernlabs.s3.transfer.kit.s3_transfer_kit',
    ),
    swiftOut: [
      'ios/s3_transfer_kit/Sources/s3_transfer_kit/Messages.g.swift',
      'macos/s3_transfer_kit/Sources/s3_transfer_kit/Messages.g.swift',
    ],
    swiftOptions: SwiftOptions(),
  ),
)
@HostApi()
abstract class S3TransferKitHostApi {
  String? getPlatformVersion();
}
