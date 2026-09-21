import 'dart:io';

/// The operating system and its version, read from dart:io.
Map<String, String> platformDetails() {
  return {
    'os': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'dart_version': Platform.version.split(' ').first,
    'locale': Platform.localeName,
    'processors': '${Platform.numberOfProcessors}',
  };
}
