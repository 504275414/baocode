import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';
import '../rpc/resumable_channel.dart';
import '../rpc/rpc_peer.dart';
import 'remote_client.dart';
import 'ssh_launcher.dart';
import 'ssh_servers.dart';

/// An SSH launcher implemented completely in Dart using the [dartssh2] library.
///
/// Unlike [SshLauncher] which relies on the OS `ssh` executable via `Process.start`,
/// this launcher connects directly over TCP sockets and requires no local binaries,
/// making it ideal for sandboxed environments like Android where spawning CLI
/// executables is restricted by SELinux / W^X policies.
class DartSshLauncher extends SshLauncher {
  DartSshLauncher({
    required super.binaries,
    super.prompter,
    this.savedServers,
    super.heartbeat,
    super.silence,
    super.maxBackoff,
  }) : super(ssh: 'dart');

  final Map<String, SshServer> Function()? savedServers;

  @override
  Future<SshConnection> connect(
    SshTarget target, {
    void Function(String message)? onProgress,
  }) async {
    final progress = onProgress ?? (_) {};
    progress('Connecting to ${target.name}');

    final client = await dialClient(target, onProgress: onProgress);

    try {
      progress('Probing ${target.name}');
      final probe = await _run(
        client,
        'sh -s',
        stdin: utf8.encode(probeScript),
      );

      var lines = const LineSplitter().convert(probe.stdout);
      List<String> partsOf(List<String> lines) => lines
          .firstWhere(
            (line) => line.startsWith('BAOCODE-PROBE '),
            orElse: () => '',
          )
          .split(' ');
      var parts = partsOf(lines);

      if (target.wslDistro == null &&
          (parts.length < 3 || SshLauncher.isWindowsSystem(parts[1]))) {
        final windows = await _run(
          client,
          SshLauncher.powershellCommand(windowsProbeScript),
        );
        final windowsLines = const LineSplitter().convert(windows.stdout);
        if (partsOf(windowsLines) case final found when found.length >= 3) {
          (lines, parts) = (windowsLines, found);
        } else if (parts.length < 3) {
          throw SshConnectException(
            SshFailure.server,
            'The host gave no answer the app understands',
            detail:
                '${probe.stdout}\n${probe.stderr}\n${windows.stdout}\n${windows.stderr}',
          );
        }
      }

      if (parts.length < 3) {
        throw SshConnectException(
          SshFailure.server,
          'The host gave no answer the app understands',
          detail: '${probe.stdout}\n${probe.stderr}',
        );
      }

      final (system, machine) = (parts[1], parts[2]);
      final platform = SshLauncher.platform(system, machine);
      if (platform == null) {
        throw SshConnectException(
          SshFailure.unsupported,
          'Only Linux, macOS and Windows hosts on x64 or arm64 are supported, not $system $machine',
        );
      }

      final windows = platform.startsWith('windows-');
      if (!lines.contains('BAOCODE-PRESENT')) {
        progress('Installing the BaoCode server on ${target.name}');
        final binary = await binaries.read(platform);
        if (binary == null) {
          throw SshConnectException(
            SshFailure.server,
            'This build of the app has no server for ${SshLauncher.describe(platform)}',
          );
        }

        if (windows) {
          await _uploadWindows(client, binary);
        } else {
          final gzip = lines.contains('BAOCODE-GZIP');
          final upload = await _run(
            client,
            uploadCommand(SshLauncher.nonce(), gzip: gzip),
            stdin: gzip ? GZipCodec(level: 6).encode(binary) : binary,
          );
          if (upload.exitCode != 0) {
            throw SshConnectException(
              SshFailure.server,
              'The server could not be installed on ${target.name}',
              detail: upload.stderr,
            );
          }
        }
      }

      progress('Starting the BaoCode server on ${target.name}');
      final sessionId = SshLauncher.nonce(16);

      if (windows) {
        final started = await _run(
          client,
          SshLauncher.powershellCommand(windowsSessionScript(sessionId)),
        );
        final sessionParts = const LineSplitter()
            .convert(started.stdout)
            .firstWhere(
              (line) => line.startsWith('BAOCODE-SESSION '),
              orElse: () => '',
            )
            .split(' ');
        final port =
            sessionParts.length == 3 ? int.tryParse(sessionParts[1]) : null;
        if (port == null) {
          throw SshConnectException(
            SshFailure.server,
            'The server on ${target.name} did not start',
            detail: '${started.stdout}\n${started.stderr}',
          );
        }

        final forward = await client.forwardLocal('127.0.0.1', port);
        forward.sink.add(utf8.encode('${sessionParts[2]}\n'));

        final keeper = _DartSshSessionKeeper(
          this,
          target,
          sessionId,
          windows: (port: port, token: sessionParts[2]),
          initialClient: client,
          initialSession: null,
          initialForward: forward,
        );
        return await _connectKeeper(keeper, target);
      } else {
        final session = await client.execute(
          sessionCommand(sessionId, resume: false),
        );
        final keeper = _DartSshSessionKeeper(
          this,
          target,
          sessionId,
          initialClient: client,
          initialSession: session,
          initialForward: null,
        );
        return await _connectKeeper(keeper, target);
      }
    } catch (error) {
      client.close();
      rethrow;
    }
  }

  Future<SshConnection> _connectKeeper(
    _DartSshSessionKeeper keeper,
    SshTarget target,
  ) async {
    final peer = RpcPeer(keeper.channel.messages, keeper.channel.send);
    final remoteClient = RemoteClient(peer);
    try {
      await remoteClient.initialize().timeout(
        const Duration(seconds: 30),
      );
    } catch (error) {
      await keeper.close();
      throw SshConnectException(
        SshFailure.server,
        'The server on ${target.name} did not initialize: $error',
      );
    }
    return SshConnection(target, remoteClient, keeper);
  }

  Future<void> _uploadWindows(SSHClient client, List<int> binary) async {
    final sftp = await client.sftp();
    final folder = '${SshLauncher.serverRoot}/${binaries.version}';
    final temporary = '$folder/.upload-${SshLauncher.nonce()}';
    try {
      await sftp.mkdir(SshLauncher.serverRoot);
    } catch (_) {}
    try {
      await sftp.mkdir(folder);
    } catch (_) {}
    final file = await sftp.open(
      temporary,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write,
    );
    await file.writeBytes(
      binary is Uint8List ? binary : Uint8List.fromList(binary),
    );
    await file.close();
    try {
      await sftp.remove('$folder/baocode-server.exe');
    } catch (_) {}
    await sftp.rename(temporary, '$folder/baocode-server.exe');
  }

  /// Establishes and authenticates a raw [SSHClient] for [target].
  Future<SSHClient> dialClient(
    SshTarget target, {
    void Function(String message)? onProgress,
  }) async {
    final servers = savedServers?.call() ?? const {};
    final SshServer? server = servers[target.text];

    String host;
    int port;
    String? username;
    String? identityFile;

    if (server != null) {
      host = server.hostName;
      port = server.port ?? 22;
      username = server.user;
      identityFile = server.identityFile;
    } else {
      var dest = target.destination;
      if (dest.contains('@')) {
        final at = dest.indexOf('@');
        username = dest.substring(0, at);
        dest = dest.substring(at + 1);
      } else {
        username = Platform.environment['USER'] ??
            Platform.environment['USERNAME'] ??
            'root';
      }
      host = dest;
      port = target.port ?? 22;
    }

    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }

    onProgress?.call('Connecting to $host:$port');
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
    } on SocketException catch (e) {
      throw SshConnectException(
        SshFailure.unreachable,
        'Could not reach host $host:$port',
        detail: e.message,
      );
    } catch (e) {
      throw SshConnectException(
        SshFailure.unreachable,
        'Could not connect to $host:$port: $e',
      );
    }

    // Load SSH identities
    final identities = <SSHIdentity>[];
    if (identityFile != null && File(identityFile).existsSync()) {
      try {
        final pem = await File(identityFile).readAsString();
        identities.addAll(SSHKeyPair.fromPem(pem));
      } catch (_) {
        final passphrase = await prompter?.call(
          SshPrompt(
            target,
            'Enter passphrase for $identityFile: ',
          ),
        );
        if (passphrase != null) {
          try {
            final pem = await File(identityFile).readAsString();
            identities.addAll(SSHKeyPair.fromPem(pem, passphrase));
          } catch (_) {}
        }
      }
    }

    final home =
        Platform.environment['HOME'] ?? AppPaths.home(Platform.environment);
    if (home.isNotEmpty) {
      for (final keyName in ['id_ed25519', 'id_rsa', 'id_ecdsa']) {
        final keyFile = File(p.join(home, '.ssh', keyName));
        if (keyFile.existsSync()) {
          try {
            final pem = await keyFile.readAsString();
            identities.addAll(SSHKeyPair.fromPem(pem));
          } catch (_) {}
        }
      }
    }

    var promptCount = 0;
    final client = SSHClient(
      socket,
      username: username ?? 'root',
      identities: identities.isNotEmpty ? identities : null,
      onPasswordRequest: () async {
        final answer = await prompter?.call(
          SshPrompt(
            target,
            '${username ?? target.text}\'s password: ',
            retry: promptCount > 0,
          ),
        );
        promptCount++;
        if (answer == null) {
          throw SSHAuthAbortError(SshLauncher.cancelledMessage);
        }
        return answer;
      },
      onUserInfoRequest: (request) async {
        final answers = <String>[];
        for (final pr in request.prompts) {
          final ans = await prompter?.call(
            SshPrompt(
              target,
              pr.promptText,
              retry: promptCount > 0,
            ),
          );
          promptCount++;
          if (ans == null) {
            throw SSHAuthAbortError(SshLauncher.cancelledMessage);
          }
          answers.add(ans);
        }
        return answers;
      },
      onVerifyHostKey: (type, fingerprint) => true,
    );

    try {
      await client.authenticated;
      return client;
    } on SSHAuthAbortError {
      client.close();
      throw const SshConnectException(
        SshFailure.authentication,
        SshLauncher.cancelledMessage,
      );
    } on SSHAuthFailError catch (e) {
      client.close();
      throw SshConnectException(
        SshFailure.authentication,
        'The host refused to sign in: the key, or the password given.',
        detail: e.message,
      );
    } catch (e) {
      client.close();
      throw SshConnectException(
        SshFailure.unreachable,
        'SSH authentication failed: $e',
      );
    }
  }

  Future<({int exitCode, String stdout, String stderr})> _run(
    SSHClient client,
    String command, {
    List<int>? stdin,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final session = await client.execute(command);
    if (stdin != null) {
      session.stdin.add(Uint8List.fromList(stdin));
    }
    await session.stdin.close();

    final stdoutBuffer = BytesBuilder();
    final stderrBuffer = BytesBuilder();
    final stdoutSub = session.stdout.listen(stdoutBuffer.add);
    final stderrSub = session.stderr.listen(stderrBuffer.add);

    await session.done.timeout(
      timeout,
      onTimeout: () {
        session.channel.close();
        throw TimeoutException('Command timed out: $command');
      },
    );
    await Future.wait([stdoutSub.asFuture<void>(), stderrSub.asFuture<void>()]);

    return (
      exitCode: session.exitCode ?? 0,
      stdout: utf8.decode(stdoutBuffer.takeBytes(), allowMalformed: true),
      stderr: utf8.decode(stderrBuffer.takeBytes(), allowMalformed: true),
    );
  }

  @override
  Future<void> forgetHostKey(SshTarget target) async {
    // In-memory / pure Dart client accepts host keys by default
  }

  @override
  Future<Map<String, String>> configOf(SshTarget target) async => const {};
}

class _DartSshSessionKeeper implements SessionKeeper {
  _DartSshSessionKeeper(
    this.launcher,
    this.target,
    this.sessionId, {
    this.windows,
    required SSHClient initialClient,
    required SSHSession? initialSession,
    required SSHForwardChannel? initialForward,
  }) : _client = initialClient,
       _session = initialSession,
       _forward = initialForward {
    channel.linkChanges.listen((up) {
      if (up) {
        _failures = 0;
        lastError = null;
        retryAt = null;
      } else {
        _schedule();
      }
      _changed();
    });
    unawaited(channel.ended.then((_) => _stop()));
    _attachCurrent();
  }

  final DartSshLauncher launcher;
  final SshTarget target;
  final String sessionId;
  final ({int port, String token})? windows;

  @override
  late final ResumableChannel channel = ResumableChannel(
    heartbeat: launcher.heartbeat,
    silence: launcher.silence,
  );

  final StreamController<void> _changes = StreamController.broadcast();
  @override
  Stream<void> get changes => _changes.stream;

  @override
  final List<String> stderr = [];

  SSHClient _client;
  SSHSession? _session;
  SSHForwardChannel? _forward;

  Timer? _retry;
  @override
  DateTime? retryAt;
  @override
  SshConnectException? lastError;
  @override
  bool stalled = false;
  @override
  bool closing = false;
  int _failures = 0;
  Future<void>? _dialing;

  Duration get maxBackoff => launcher.maxBackoff;

  void _attachCurrent() {
    final win = windows;
    if (win != null) {
      final fwd = _forward!;
      channel.attach(
        ChannelLink(
          input: fwd.stream,
          write: (bytes) => fwd.sink.add(bytes),
          close: () {
            fwd.close();
          },
        ),
      );
    } else {
      final sess = _session!;
      sess.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            stderr.add(line);
            if (stderr.length > 50) stderr.removeAt(0);
          }, onError: (Object _) {});

      channel.attach(
        ChannelLink(
          input: sess.stdout,
          write: (bytes) => sess.stdin.add(Uint8List.fromList(bytes)),
          close: () {
            sess.channel.close();
          },
        ),
      );
    }
  }

  @override
  Future<void> retryNow() async {
    if (channel.isClosed) throw const RpcClosed();
    if (channel.linked) return;
    stalled = false;
    _retry?.cancel();
    _retry = null;
    await _dialAgain();
    if (channel.isClosed) throw const RpcClosed();
    if (!channel.linked) throw lastError ?? const RpcClosed();
  }

  Future<void> _dialAgain() => _dialing ??= _redial().whenComplete(() {
    _dialing = null;
    _schedule();
  });

  Future<void> _redial() async {
    if (closing || channel.isClosed || channel.linked) return;
    retryAt = null;
    _changed();

    try {
      if (_client.isClosed) {
        _client = await launcher.dialClient(target);
      }
      final win = windows;
      if (win != null) {
        final fwd = await _client.forwardLocal('127.0.0.1', win.port);
        fwd.sink.add(utf8.encode('${win.token}\n'));
        _forward = fwd;
      } else {
        final sess = await _client.execute(
          launcher.sessionCommand(sessionId, resume: true),
        );
        _session = sess;
      }
      _attachCurrent();
    } on SshConnectException catch (error) {
      _failed(error);
    } catch (error) {
      _failed(
        SshConnectException(
          SshFailure.unreachable,
          'Reconnecting failed: $error',
        ),
      );
    }
  }

  void _failed(SshConnectException error) {
    lastError = error;
    _failures++;
    stalled = switch (error.failure) {
      SshFailure.authentication ||
      SshFailure.hostKey ||
      SshFailure.hostKeyChanged ||
      SshFailure.noSsh => true,
      _ => false,
    };
    _changed();
  }

  void _schedule() {
    if (closing || stalled || channel.isClosed || channel.linked) return;
    if (_dialing != null) return;
    final seconds = _failures == 0
        ? 0
        : min(pow(2, _failures - 1).toInt(), maxBackoff.inSeconds);
    final delay = Duration(seconds: seconds);
    retryAt = DateTime.now().add(delay);
    _changed();
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      unawaited(_dialAgain());
    });
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _stop() {
    _retry?.cancel();
    _retry = null;
    retryAt = null;
    _changed();
  }

  @override
  Future<void> close() async {
    closing = true;
    _stop();
    channel.close();
    try {
      _session?.channel.close();
      _forward?.close();
      _client.close();
    } catch (_) {}
  }
}
