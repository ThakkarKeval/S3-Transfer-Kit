import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';
import 'package:s3_transfer_kit/s3_transfer_kit_method_channel.dart';
import 'package:s3_transfer_kit/s3_transfer_kit_platform_interface.dart';

class MockS3TransferKitPlatform
    with MockPlatformInterfaceMixin
    implements S3TransferKitPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final S3TransferKitPlatform initialPlatform = S3TransferKitPlatform.instance;

  test('$MethodChannelS3TransferKit is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelS3TransferKit>());
  });

  test('getPlatformVersion', () async {
    final s3TransferKitPlugin = S3TransferKit();
    final fakePlatform = MockS3TransferKitPlatform();
    S3TransferKitPlatform.instance = fakePlatform;

    expect(await s3TransferKitPlugin.getPlatformVersion(), '42');
  });
}
