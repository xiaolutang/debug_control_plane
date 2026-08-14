import 'dart:io' as io;

/// IO implementation for the channel-protocol alignment test.
class FileHelperIo {
  /// Read [path] (relative to the package root, i.e. the test runner CWD).
  static String read(String path) => io.File(path).readAsStringSync();
}
