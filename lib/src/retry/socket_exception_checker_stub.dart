/// Web and WASM stub implementation for socket exception detection.
bool isSocketException(Object error) {
  // Handles synthetic or mock SocketException instances in web test environments
  // without importing dart:io.
  return error.runtimeType.toString() == 'SocketException';
}
