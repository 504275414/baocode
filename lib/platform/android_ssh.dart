import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'data_dir.dart';

/// Prepares and returns the path to the bundled OpenSSH binary on Android.
Future<String?> ensureAndroidSsh() async {
  if (kIsWeb || !Platform.isAndroid) return null;

  // 1. Check if the native library extracted by Android OS exists and is ready.
  for (final nativeLib in const [
    '/data/data/dev.baocode.baocode/lib/libssh.so',
    '/data/user/0/dev.baocode.baocode/lib/libssh.so',
  ]) {
    if (File(nativeLib).existsSync()) {
      return nativeLib;
    }
  }

  // 2. Otherwise extract bundled binaries from Flutter assets to files/bin/
  final binDir = p.join(DataDirectory.current.path, 'bin');
  final sshFile = File(p.join(binDir, 'ssh'));
  final keygenFile = File(p.join(binDir, 'ssh-keygen'));

  try {
    if (!sshFile.existsSync() || !keygenFile.existsSync()) {
      await Directory(binDir).create(recursive: true);

      // Extract ssh
      final sshBytes = await rootBundle.load('assets/android/bin/arm64-v8a/ssh');
      await sshFile.writeAsBytes(
        sshBytes.buffer.asUint8List(
          sshBytes.offsetInBytes,
          sshBytes.lengthInBytes,
        ),
        flush: true,
      );

      // Extract ssh-keygen
      final keygenBytes = await rootBundle.load(
        'assets/android/bin/arm64-v8a/ssh-keygen',
      );
      await keygenFile.writeAsBytes(
        keygenBytes.buffer.asUint8List(
          keygenBytes.offsetInBytes,
          keygenBytes.lengthInBytes,
        ),
        flush: true,
      );

      // Make executable
      await Process.run('chmod', ['755', sshFile.path, keygenFile.path]);
    }

    if (sshFile.existsSync()) {
      return sshFile.path;
    }
  } catch (error) {
    debugPrint('Failed to extract bundled Android ssh: $error');
  }

  return null;
}
