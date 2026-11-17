import 'package:flutter_test/flutter_test.dart';
import 'package:s3_transfer_kit_example/main.dart';

void main() {
  testWidgets('Verify S3TransferKitExampleApp renders dashboard', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const S3TransferKitExampleApp());
    await tester.pump();

    expect(find.text('S3 Transfer Kit'), findsOneWidget);
    expect(find.text('Single-File Upload (1MB)'), findsOneWidget);
    expect(find.text('S3 Multipart Upload (15MB)'), findsOneWidget);
    expect(find.text('Two-Phase Atomic Download'), findsOneWidget);
  });
}
