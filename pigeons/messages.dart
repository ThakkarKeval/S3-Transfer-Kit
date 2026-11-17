import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/cavernlabs/s3/transfer/kit/s3_transfer_kit/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.cavernlabs.s3.transfer.kit.s3_transfer_kit',
    ),
    swiftOut: 'ios/s3_transfer_kit/Sources/s3_transfer_kit/Messages.g.swift',
    swiftOptions: SwiftOptions(),
  ),
)
class NativeUploadRequest {
  NativeUploadRequest({
    required this.taskId,
    required this.url,
    required this.filePath,
    required this.method,
    required this.headers,
  });

  String taskId;
  String url;
  String filePath;
  String method;
  Map<String, String> headers;
}

class NativeDownloadRequest {
  NativeDownloadRequest({
    required this.taskId,
    required this.url,
    required this.destinationPath,
    required this.headers,
  });

  String taskId;
  String url;
  String destinationPath;
  Map<String, String> headers;
}

class NativeTransferProgressUpdate {
  NativeTransferProgressUpdate({
    required this.taskId,
    required this.bytesTransferred,
    required this.totalBytes,
  });

  String taskId;
  int bytesTransferred;
  int totalBytes;
}

class NativeTransferStateUpdate {
  NativeTransferStateUpdate({
    required this.taskId,
    required this.status,
    this.error,
    this.httpStatusCode,
    this.eTag,
  });

  String taskId;
  String status;
  String? error;
  int? httpStatusCode;
  String? eTag;
}

@HostApi()
abstract class S3TransferKitHostApi {
  String? getPlatformVersion();
  bool isBackgroundTransferSupported();
  void startBackgroundUpload(NativeUploadRequest request);
  void startBackgroundDownload(NativeDownloadRequest request);
  void cancelBackgroundTransfer(String taskId);
  void pauseBackgroundTransfer(String taskId);
  void resumeBackgroundTransfer(String taskId);
}

@FlutterApi()
abstract class S3TransferKitFlutterApi {
  void onTransferProgress(NativeTransferProgressUpdate update);
  void onTransferStateChanged(NativeTransferStateUpdate update);
}
