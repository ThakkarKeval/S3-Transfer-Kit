import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit_method_channel.dart';
import 'package:s3_transfer_kit/src/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelS3TransferKit();
  const channelName =
      'dev.flutter.pigeon.s3_transfer_kit.S3TransferKitHostApi.getPlatformVersion';
  const bgChannelName =
      'dev.flutter.pigeon.s3_transfer_kit.S3TransferKitHostApi.isBackgroundTransferSupported';

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(channelName, (message) async {
          return S3TransferKitHostApi.pigeonChannelCodec.encodeMessage(
            <Object?>['42'],
          );
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(bgChannelName, (message) async {
          return S3TransferKitHostApi.pigeonChannelCodec.encodeMessage(
            <Object?>[true],
          );
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(channelName, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(bgChannelName, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('isBackgroundTransferSupported', () async {
    expect(await platform.isBackgroundTransferSupported(), isTrue);
  });
}
