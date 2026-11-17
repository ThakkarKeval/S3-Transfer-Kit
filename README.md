# s3_transfer_kit

s3_transfer_kit

## Getting Started

This project is a starting point for a Flutter
[plug-in package](https://flutter.dev/to/develop-plugins),
a specialized package that includes platform-specific implementation code for
Android and/or iOS.

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Pigeon Platform Channels

This plugin uses [Pigeon](https://pub.dev/packages/pigeon) for type-safe platform channel communication.

The communication interface is defined in `pigeons/messages.dart`. To regenerate platform channel code across Dart, Android (Kotlin), iOS (Swift), and macOS (Swift), run:

```bash
dart run pigeon --input pigeons/messages.dart
```


