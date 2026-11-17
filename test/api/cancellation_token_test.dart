import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit/s3_transfer_kit.dart';

void main() {
  group('CancellationToken', () {
    test('initiates uncancelled', () {
      final token = CancellationToken();
      expect(token.isCancelled, isFalse);
      expect(token.reason, isNull);
    });

    test('cancel sets isCancelled and reason', () {
      final token = CancellationToken();
      token.cancel('User requested cancel');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'User requested cancel');
    });

    test('whenCancelled completes on cancel', () async {
      final token = CancellationToken();
      var completed = false;
      token.whenCancelled.then((_) => completed = true);

      expect(completed, isFalse);
      token.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isTrue);
    });

    test('onCancelled callback fires when cancel is called', () {
      final token = CancellationToken();
      var callbackFired = false;
      token.onCancelled(() => callbackFired = true);

      expect(callbackFired, isFalse);
      token.cancel();
      expect(callbackFired, isTrue);
    });

    test('onCancelled callback fires immediately if already cancelled', () {
      final token = CancellationToken()..cancel('Already cancelled');
      var callbackFired = false;
      token.onCancelled(() => callbackFired = true);
      expect(callbackFired, isTrue);
    });
  });
}
