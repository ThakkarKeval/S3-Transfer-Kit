import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  group('TransferProgress', () {
    test('calculates fraction and percentage correctly', () {
      const progress = TransferProgress(bytesTransferred: 50, totalBytes: 100);

      expect(progress.fraction, 0.5);
      expect(progress.percentage, 50.0);
    });

    test('handles zero total bytes safely without dividing by zero', () {
      const progress = TransferProgress(bytesTransferred: 0, totalBytes: 0);

      expect(progress.fraction, 0.0);
      expect(progress.percentage, 0.0);
    });

    test('clamps fraction to 1.0 if bytesTransferred exceeds total', () {
      const progress = TransferProgress(bytesTransferred: 150, totalBytes: 100);

      expect(progress.fraction, 1.0);
    });

    test('equality and hashCode work as expected', () {
      const p1 = TransferProgress(bytesTransferred: 10, totalBytes: 20);
      const p2 = TransferProgress(bytesTransferred: 10, totalBytes: 20);
      const p3 = TransferProgress(bytesTransferred: 15, totalBytes: 20);

      expect(p1, equals(p2));
      expect(p1.hashCode, equals(p2.hashCode));
      expect(p1, isNot(equals(p3)));
    });
  });
}
