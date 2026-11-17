import 'dart:io';

/// Platform IO implementation for socket exception detection.
bool isSocketException(Object error) => error is SocketException;
