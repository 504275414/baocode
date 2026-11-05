import 'code_buddy_storage.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Transport interface for communicating with `codebuddy` via ACP protocol.
abstract interface class CodeBuddyTransport {
  /// Stream of decoded JSON-RPC 2.0 messages from CodeBuddy.
  Stream<Map<String, Object?>> get messages;

  /// Writes a JSON-RPC 2.0 message to CodeBuddy.
  void write(Map<String, Object?> message);

  /// Closes the transport and terminates any associated process.
  void close();
}

/// Spawns and manages `codebuddy --acp` over standard I/O (stdin/stdout).
class ProcessCodeBuddyTransport implements CodeBuddyTransport {
  ProcessCodeBuddyTransport(this._process) {
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onStdoutLine, onError: _onError, onDone: _onStdoutDone);

    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onStderrLine, onError: _onError);

    unawaited(_process.exitCode.then(_onExit));
  }

  final Process _process;
  final StreamController<Map<String, Object?>> _controller =
      StreamController.broadcast();

  @override
  Stream<Map<String, Object?>> get messages => _controller.stream;

  void _onStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, Object?>) {
        _controller.add(decoded);
      } else if (decoded is Map) {
        _controller.add(decoded.cast<String, Object?>());
      }
    } on FormatException {
      // Ignored non-JSON output (e.g. CLI debug logs)
      debugPrint('[CodeBuddy stdout] $trimmed');
    }
  }

  void _onStderrLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      debugPrint('[CodeBuddy stderr] $trimmed');
    }
  }

  void _onError(Object error) {
    debugPrint('[CodeBuddy transport error] $error');
  }

  void _onStdoutDone() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  void _onExit(int code) {
    debugPrint('[CodeBuddy exited with code $code]');
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  @override
  void write(Map<String, Object?> message) {
    final encoded = jsonEncode(message);
    _process.stdin.writeln(encoded);
  }

  @override
  void close() {
    try {
      _process.kill();
    } catch (_) {}
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  /// Resolves the codebuddy executable, taking care of Windows npm global paths.
  static String resolveExecutable() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        final npmCmd = '$appData\\npm\\codebuddy.cmd';
        if (File(npmCmd).existsSync()) return npmCmd;
      }
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        final localCmd = '$localAppData\\Programs\\CodeBuddy\\codebuddy.cmd';
        if (File(localCmd).existsSync()) return localCmd;
      }
    }
    return 'codebuddy';
  }

  /// Starts `codebuddy --acp` child process with optional working directory.
  static Future<CodeBuddyTransport> start({String? cwd, String? configDir}) async {
    String? validCwd = cwd;
    if (validCwd != null && (validCwd.trim().isEmpty || !Directory(validCwd).existsSync())) {
      validCwd = null;
    }

    final executable = resolveExecutable();
    final dir = configDir ?? CodeBuddyStorage.defaultConfigDir;
    CodeBuddyStorage.ensureIsolatedConfigDir(dir);
    debugPrint('[CodeBuddy starting] exe: $executable, cwd: $validCwd, configDir: $dir');

    final process = await Process.start(
      executable,
      ['--acp'],
      workingDirectory: validCwd,
      runInShell: Platform.isWindows,
      environment: {
        ...Platform.environment,
        'CODEBUDDY_CONFIG_DIR': dir,
      },
    );
    return ProcessCodeBuddyTransport(process);
  }
}
