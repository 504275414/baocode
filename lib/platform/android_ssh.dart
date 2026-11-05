import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'data_dir.dart';

const _platformChannel = MethodChannel('dev.baocode.baocode/platform');

/// Gets the Android system's native library directory (e.g. /data/app/.../lib/arm64)
Future<String?> getAndroidNativeLibraryDir() async {
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    return await _platformChannel.invokeMethod<String>('getNativeLibraryDir');
  } catch (error) {
    debugPrint('[Android SSH] getNativeLibraryDir error: $error');
    return null;
  }
}

/// Prepares and returns the path to the bundled OpenSSH binary on Android,
/// and ensures the remote server configuration is ready.
Future<String?> ensureAndroidSsh() async {
  if (kIsWeb || !Platform.isAndroid) return null;

  // 1. Ensure remote server config (VERSION, servers.json) is ready
  await ensureAndroidRemoteServer();

  // 2. Ensure application home / .ssh directory exists for OpenSSH known_hosts
  try {
    final sshConfigDir = Directory(p.join(DataDirectory.current.path, '.ssh'));
    if (!sshConfigDir.existsSync()) {
      await sshConfigDir.create(recursive: true);
    }
  } catch (e) {
    debugPrint('[Android SSH] Failed to create .ssh directory: $e');
  }

  // 3. Check native library directory provided by Android applicationInfo
  final nativeDir = await getAndroidNativeLibraryDir();
  if (nativeDir != null && nativeDir.isNotEmpty) {
    final nativeSsh = p.join(nativeDir, 'libssh.so');
    if (File(nativeSsh).existsSync()) {
      debugPrint('[Android SSH] Found native libssh.so at: $nativeSsh');
      return nativeSsh;
    }
  }

  // 4. Check known fallback native paths
  for (final nativeLib in const [
    '/data/data/dev.baocode.baocode/lib/libssh.so',
    '/data/user/0/dev.baocode.baocode/lib/libssh.so',
  ]) {
    if (File(nativeLib).existsSync()) {
      return nativeLib;
    }
  }

  // 5. Otherwise extract bundled binaries from Flutter assets to files/bin/
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
    debugPrint('[Android SSH] Failed to extract bundled ssh: $error');
  }

  return null;
}

/// Ensures that remote server configuration (VERSION and servers.json)
/// is extracted to DataDirectory on Android.
Future<void> ensureAndroidRemoteServer() async {
  if (kIsWeb || !Platform.isAndroid) return;
  final remoteDir = p.join(DataDirectory.current.path, 'remote');
  final versionFile = File(p.join(remoteDir, 'VERSION'));
  final serversFile = File(p.join(remoteDir, 'servers.json'));

  try {
    if (!versionFile.existsSync() || !serversFile.existsSync()) {
      await Directory(remoteDir).create(recursive: true);
      final versionData = await rootBundle.loadString('assets/remote/VERSION');
      await versionFile.writeAsString(versionData.trim());

      final serversData = await rootBundle.loadString('assets/remote/servers.json');
      await serversFile.writeAsString(serversData.trim());
    }
  } catch (error) {
    debugPrint('[Android SSH] Failed to extract Android remote server config: $error');
  }
}
