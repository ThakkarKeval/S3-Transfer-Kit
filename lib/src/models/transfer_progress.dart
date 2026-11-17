/// Represents an immutable snapshot of transfer progress.
class TransferProgress {
  /// Constructs a [TransferProgress] snapshot.
  const TransferProgress({
    required this.bytesTransferred,
    required this.totalBytes,
  }) : assert(bytesTransferred >= 0, 'bytesTransferred cannot be negative'),
       assert(totalBytes >= 0, 'totalBytes cannot be negative');

  /// Initial progress state before any bytes have been transferred.
  const TransferProgress.initial({this.totalBytes = 0}) : bytesTransferred = 0;

  /// The number of bytes transferred so far.
  final int bytesTransferred;

  /// The total expected bytes to transfer.
  final int totalBytes;

  /// The completion ratio between 0.0 and 1.0. Returns 0.0 if [totalBytes] is 0.
  double get fraction {
    if (totalBytes <= 0) return 0.0;
    final ratio = bytesTransferred / totalBytes;
    return ratio.clamp(0.0, 1.0);
  }

  /// The completion percentage formatted from 0.0 to 100.0.
  double get percentage => fraction * 100.0;

  @override
  String toString() =>
      'TransferProgress($bytesTransferred/$totalBytes bytes, ${percentage.toStringAsFixed(1)}%)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TransferProgress &&
        other.bytesTransferred == bytesTransferred &&
        other.totalBytes == totalBytes;
  }

  @override
  int get hashCode => Object.hash(bytesTransferred, totalBytes);
}
