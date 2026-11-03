import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'code_buddy_transport.dart';
import '../../browser/browser_bridge.dart';
import '../../browser/browser_tools.dart';
import '../claude_code/claude_sdk_tools.dart';

/// Adapts `codebuddy --acp` to [AgentKernel] using the Agent Client Protocol.
class CodeBuddyKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        SelectsPermission,
        ProvidesCommands,
        ReportsContext,
        AcceptsImages {
  CodeBuddyKernel(
    this.descriptor,
    this.context, {
    Future<CodeBuddyTransport> Function({String? cwd})? startTransport,
  }) : _startTransport = startTransport ?? ProcessCodeBuddyTransport.start {
    final initialModel = context.settings[KernelChoiceKind.model.name];
    final initialMode = context.settings[KernelChoiceKind.mode.name];
    final initialPermission = context.settings[KernelChoiceKind.permission.name];
    if (initialModel != null) _pendingModel = initialModel;
    if (initialMode != null || initialPermission != null) {
      final isPlan = initialMode == 'plan';
      _pendingMode = isPlan ? 'plan' : (initialPermission ?? 'default');
    }

    // Model choices
    model = LocalChoice(
      _models,
      onChanged: (id) => _onModelChanged(id),
    );
    if (_pendingModel != null) model.reported = _pendingModel;

    // Working mode: Agent vs Plan
    mode = LocalChoice(
      _modes,
      onChanged: (id) => _onModeOrPermissionChanged(),
    );
    if (initialMode != null) mode.reported = initialMode;

    // Approval ways (default / auto / acceptEdits / dontAsk / bypassPermissions)
    permission = LocalChoice(
      _permissions,
      onChanged: (id) => _onModeOrPermissionChanged(),
    );
    if (initialPermission != null) permission.reported = initialPermission;
  }

  @override
  final KernelDescriptor descriptor;
  final KernelContext context;
  final Future<CodeBuddyTransport> Function({String? cwd}) _startTransport;

  CodeBuddyTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  final Completer<void> _stoppedCompleter = Completer<void>();

  @override
  late final LocalChoice model;

  @override
  late final LocalChoice mode;

  @override
  late final LocalChoice permission;

  @override
  KernelHealth health = KernelHealth.ready;

  @override
  String? get sessionId => _sessionId;
  String? _sessionId;
  String? _pendingModel;
  String? _pendingMode;

  @override
  Future<void> get stopped => _stoppedCompleter.future;

  @override
  int get contextWindow => _contextWindow;
  int _contextWindow = 200000;

  int _requests = 0;
  final Map<Object, Completer<Map<String, Object?>>> _responses = {};
  bool _initialized = false;
  Future<void>? _connecting;

  /// Currently active turn
  String? _turn;
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  /// Streaming state
  String? _currentThoughtId;
  StringBuffer? _thoughtBuffer;
  Stopwatch? _thoughtClock;

  String? _currentMessageId;
  StringBuffer? _messageBuffer;

  /// Pending approvals: requestId -> interruptionId
  final Map<String, String> _approvals = {};
  final Map<String, _PendingPermissionRequest> _pendingRpcApprovals = {};
  HttpServer? _mcpServer;
  int? _mcpPort;

  final List<KernelOption> _models = [
    const KernelOption(
      'hy4-preview',
      'Hy4 Preview',
      Icons.bolt_rounded,
      'Flagship Code Model',
    ),
    const KernelOption(
      'deepseek-v4.1-flash',
      'DeepSeek V4.1 Flash',
      Icons.bolt_rounded,
      'Fast and Accurate',
    ),
    const KernelOption(
      'glm-5.3',
      'GLM 5.3',
      Icons.auto_awesome_rounded,
      'General Purpose',
    ),
  ];

  final List<KernelOption> _modes = [
    const KernelOption(
      'agent',
      'Agent',
      Icons.smart_toy_outlined,
      'Full agent mode with tool executions',
    ),
    const KernelOption(
      'plan',
      'Plan',
      Icons.assignment_outlined,
      'Analyze and propose plans without modifying files',
    ),
  ];

  final List<KernelOption> _permissions = [
    const KernelOption(
      'default',
      'Always Ask',
      Icons.lock_outline_rounded,
      'Prompts for permission on first use of each tool',
    ),
    const KernelOption(
      'auto',
      'Auto',
      Icons.auto_mode_rounded,
      'An AI reviewer checks and approves safe actions',
    ),
    const KernelOption(
      'acceptEdits',
      'Accept Edits',
      Icons.edit_note_rounded,
      'Automatically accepts file edit permissions',
    ),
    const KernelOption(
      'dontAsk',
      "Don't Ask",
      Icons.visibility_outlined,
      'Pre-approved read actions run, other actions denied',
    ),
    const KernelOption(
      'bypassPermissions',
      'Bypass Permissions',
      Icons.all_inclusive_rounded,
      'Skips all permission prompts',
    ),
  ];

  List<KernelCommand> _commands = const [
    KernelCommand(
      'goal',
      'Keep working until a condition is met',
      Icons.flag_outlined,
    ),
    KernelCommand(
      'plan',
      'Preview current plan file content',
      Icons.assignment_outlined,
    ),
    KernelCommand(
      'review',
      'Review a pull request or changes',
      Icons.rate_review_outlined,
    ),
    KernelCommand(
      'compact',
      'Summarize conversation history',
      Icons.compress_rounded,
    ),
  ];

  @override
  List<KernelCommand> get commands => _commands;

  // --- Lifecycle -------------------------------------------------------------

  @override
  void prepare() {
    unawaited(_ensureSession());
  }

  @override
  void release() {}

  @override
  void restart() {
    _transport?.close();
    _transport = null;
    _subscription?.cancel();
    _subscription = null;
    _initialized = false;
    _sessionId = null;
    _connecting = null;
    health = KernelHealth.ready;
    emit(KernelInfoChanged(nextSeq));
    prepare();
  }

  @override
  void dispose() {
    unawaited(_mcpServer?.close(force: true));
    _mcpServer = null;
    _mcpPort = null;
    unawaited(_subscription?.cancel());
    _transport?.close();
    if (!_stoppedCompleter.isCompleted) {
      _stoppedCompleter.complete();
    }
    closeEvents();
  }

  // --- Transport & JSON-RPC --------------------------------------------------

  Future<void> _ensureSession() async {
    if (_sessionId != null) return;
    return _connecting ??= _connect();
  }

  Future<void> _connect() async {
    try {
      String workingDir = context.cwd ?? '';
      if (workingDir.trim().isEmpty || !Directory(workingDir).existsSync()) {
        workingDir = Directory.current.path;
      }

      final transport = await _startTransport(cwd: workingDir);
      _transport = transport;
      _subscription = transport.messages.listen(_receive, onDone: _onDisconnected);

      if (!_initialized) {
        _initialized = true;
        await _request('initialize', {
          'protocolVersion': 1,
          'clientInfo': {'name': 'CodeBuddy IDE', 'version': '1.0.0'},
          'clientCapabilities': {
            'fs': {'readTextFile': false, 'writeTextFile': false},
            'terminal': false,
          },
        });
      }

      await _ensureMcpServer(workingDir);
      final mcpPort = _mcpPort;

      final sessionResult = await _request('session/new', {
        'cwd': workingDir.replaceAll(r'\', '/'),
        'mcpServers': [
          if (mcpPort != null)
            {
              'name': 'baocode',
              'type': 'http',
              'url': 'http://127.0.0.1:$mcpPort/mcp',
              'headers': <Object>[],
            },
        ],
      });

      if (sessionResult['sessionId'] case final String sid) {
        _sessionId = sid;
        if (_pendingModel case final targetModel?) {
          unawaited(_request('session/set_model', {'sessionId': sid, 'modelId': targetModel}));
        }
        if (_pendingMode case final targetMode?) {
          unawaited(_request('session/set_mode', {'sessionId': sid, 'modeId': targetMode}));
        }
      }

      if (sessionResult['models'] case final Map modelsMap) {
        _populateModelsFromSessionResult(modelsMap.cast<String, Object?>());
      }

      if (sessionResult['modes'] case final Map modesMap) {
        _populateModesFromSessionResult(modesMap.cast<String, Object?>());
      }

      if (sessionResult['configOptions'] case final List configList) {
        _handleConfigOptions({'configOptions': configList});
      }
      emit(KernelInfoChanged(nextSeq));
    } catch (e) {
      health = KernelHealth(KernelHealthStatus.failed, message: e.toString());
      emit(KernelInfoChanged(nextSeq));
      rethrow;
    } finally {
      _connecting = null;
    }
  }

  KernelOption _formatModelOption(
    String modelId,
    String rawName,
    String? rawDesc,
  ) {
    String label;
    String desc = rawDesc ?? '';

    if (modelId.startsWith('custom-local:')) {
      final localId = modelId.substring('custom-local:'.length);
      if (rawName.toLowerCase() == localId.toLowerCase()) {
        label = rawName;
      } else {
        // Match CodeBuddy's official format: name:id (e.g. GLM:glm53, deepseek:v4-flash)
        label = '$rawName:$localId';
      }
      if (desc.isEmpty || desc == 'null') {
        desc = 'Custom Model';
      }
    } else {
      label = rawName;
      if (modelId == 'hy3-x' && rawName == 'Hy3') {
        label = 'Hy3-X';
      }
    }

    return KernelOption(
      modelId,
      label,
      Icons.bolt_rounded,
      desc,
    );
  }

  void _populateModelsFromSessionResult(Map<String, Object?> modelsMap) {
    final available = modelsMap['availableModels'] as List<Object?>? ?? const [];
    final currentModelId = modelsMap['currentModelId']?.toString();
    if (available.isNotEmpty) {
      _models.clear();
      for (final item in available) {
        if (item is! Map) continue;
        final modelId = (item['modelId'] ?? item['id'])?.toString() ?? '';
        if (modelId.isEmpty) continue;
        final name = item['name']?.toString() ?? modelId;
        final desc = item['description']?.toString();
        _models.add(_formatModelOption(modelId, name, desc));
      }
      model.options = List.of(_models);
      if (_pendingModel != null) {
        model.reported = _pendingModel;
      } else if (currentModelId != null) {
        model.reported = currentModelId;
      }
      emit(KernelInfoChanged(nextSeq));
    }
  }

  void _populateModesFromSessionResult(Map<String, Object?> modesMap) {
    final available = modesMap['availableModes'] as List<Object?>? ?? const [];
    final currentModeId = modesMap['currentModeId']?.toString();
    if (available.isNotEmpty) {
      _permissions.clear();
      for (final item in available) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        if (id == 'plan') continue;
        final name = item['name']?.toString() ?? id;
        final desc = item['description']?.toString() ?? '';
        _permissions.add(
          KernelOption(
            id,
            name,
            switch (id) {
              'acceptEdits' => Icons.edit_note_rounded,
              'auto' => Icons.auto_mode_rounded,
              'dontAsk' => Icons.visibility_outlined,
              'bypassPermissions' => Icons.all_inclusive_rounded,
              _ => Icons.lock_outline_rounded,
            },
            desc,
          ),
        );
      }
      permission.options = List.of(_permissions);
      if (_pendingMode == null && currentModeId != null) {
        if (currentModeId == 'plan') {
          mode.reported = 'plan';
        } else {
          mode.reported = 'agent';
          permission.reported = currentModeId;
        }
      }
      emit(KernelInfoChanged(nextSeq));
    }
  }

  void _onDisconnected() {
    health = const KernelHealth(
      KernelHealthStatus.failed,
      message: 'CodeBuddy process disconnected',
    );
    for (final response in _responses.values) {
      if (!response.isCompleted) {
        response.completeError(StateError('CodeBuddy process disconnected'));
      }
    }
    _responses.clear();
    final turn = _turn;
    if (turn != null) {
      _endTurn(turn, interrupted: true);
    }
    emit(KernelInfoChanged(nextSeq));
  }

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params, {
    Duration? timeout = const Duration(seconds: 30),
  }) {
    final id = ++_requests;
    final response = Completer<Map<String, Object?>>();
    _responses[id] = response;
    _transport?.write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    if (timeout != null) {
      return response.future.timeout(
        timeout,
        onTimeout: () {
          _responses.remove(id);
          throw TimeoutException('Request $method timed out after $timeout');
        },
      );
    }
    return response.future;
  }

  void _notify(String method, Map<String, Object?> params) {
    _transport?.write({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  // --- Kernel Turn Operations ------------------------------------------------

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    _turn = turn.id;
    _turnStarted = DateTime.now();

    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );

    unawaited(_executeTurn(turn));
  }

  Future<void> _ensureMcpServer(String workingDir) async {
    if (_mcpServer != null) return;
    try {
      if (BrowserBridge.instance.enabled) {
        BrowserTools.register();
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _mcpServer = server;
      _mcpPort = server.port;

      server.listen((HttpRequest req) async {
        try {
          if (req.method == 'POST') {
            final body = await utf8.decoder.bind(req).join();
            final json = jsonDecode(body) as Map<String, Object?>;
            final method = json['method'] as String? ?? '';

            if (method.startsWith('notifications/')) {
              req.response
                ..statusCode = HttpStatus.ok
                ..headers.contentType = ContentType.json
                ..write('{}');
              await req.response.close();
              return;
            }

            final params = (json['params'] as Map?)?.cast<String, Object?>() ?? {};
            final toolName = params['name'] as String? ?? '';

            // Check if it's a browser tool call and fail fast if no browser extension is connected
            if (method == 'tools/call' &&
                (toolName.contains('browser') || toolName.startsWith('browser_'))) {
              if (BrowserBridge.instance.browsers.isEmpty) {
                final response = {
                  'jsonrpc': '2.0',
                  'id': json['id'] ?? 0,
                  'result': {
                    'content': [
                      {
                        'type': 'text',
                        'text': '未检测到已连接的浏览器。请先打开 Chrome 或 Edge 浏览器，并确保已在浏览器中启用 BaoCode 扩展。',
                      }
                    ],
                    'isError': true,
                  },
                };
                req.response
                  ..statusCode = HttpStatus.ok
                  ..headers.contentType = ContentType.json
                  ..write(jsonEncode(response));
                await req.response.close();
                return;
              }
            }

            final response = await ClaudeSdkTools.handle(
              json,
              ClaudeSdkCall(
                cwd: workingDir,
                sessionId: _sessionId,
              ),
            ).timeout(
              const Duration(seconds: 20),
              onTimeout: () => {
                'jsonrpc': '2.0',
                'id': json['id'] ?? 0,
                'result': {
                  'content': [
                    {
                      'type': 'text',
                      'text': '操作执行耗时较长，网页可能正在加载或包含异步脚本。请重试或检查网页地址。',
                    }
                  ],
                  'isError': true,
                },
              },
            );

            req.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(response));
            await req.response.close();
          } else {
            req.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.text
              ..write('BaoCode MCP Server');
            await req.response.close();
          }
        } catch (e) {
          try {
            req.response
              ..statusCode = HttpStatus.internalServerError
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'jsonrpc': '2.0',
                'error': {'code': -32603, 'message': '$e'},
              }));
            await req.response.close();
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  Future<void> _executeTurn(KernelTurn turn) async {
    try {
      await _ensureSession();
      final sid = _sessionId;
      if (sid == null) throw StateError('Failed to obtain CodeBuddy session ID');

      final promptBlocks = <Map<String, Object?>>[
        {'type': 'text', 'text': turn.text},
        for (final note in turn.notes) {'type': 'text', 'text': note},
        for (final img in turn.images)
          {
            'type': 'image',
            'data': base64Encode(img.bytes),
            'mimeType': img.mediaType,
          },
      ];

      final res = await _request(
        'session/prompt',
        {
          'sessionId': sid,
          'prompt': promptBlocks,
        },
        timeout: null,
      );

      // Prompt completed successfully
      if (_turn == turn.id) {
        _endTurn(turn.id, interrupted: res['stopReason'] == 'cancelled');
      }
    } catch (e, st) {
      debugPrint('CodeBuddy _executeTurn error: $e\n$st');
      if (_turn == turn.id) {
        _endTurn(turn.id, interrupted: true);
      }
    }
  }

  @override
  void cancel() {
    final turn = _turn;
    final sid = _sessionId;
    if (turn == null) return;
    if (sid != null) {
      _notify('session/cancel', {'sessionId': sid});
    }
    for (final entry in _pendingRpcApprovals.entries) {
      emit(InteractionResolved(nextSeq, entry.key));
      _transport?.write({
        'jsonrpc': '2.0',
        'id': entry.value.rpcId,
        'result': {
          'outcome': {
            'outcome': 'cancelled',
          }
        }
      });
    }
    _pendingRpcApprovals.clear();
    _endTurn(turn, interrupted: true);
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (_pendingRpcApprovals.remove(requestId) case final req?) {
      emit(InteractionResolved(nextSeq, requestId));
      final selectedOptionId = switch (answer) {
        ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
          req.allowAlwaysOptionId ?? req.allowOnceOptionId,
        ApprovalAnswer(decision: ApprovalDecision.allowOnce) =>
          req.allowOnceOptionId,
        _ => req.denyOptionId,
      };

      _transport?.write({
        'jsonrpc': '2.0',
        'id': req.rpcId,
        'result': {
          'outcome': {
            'outcome': 'selected',
            'optionId': selectedOptionId,
          }
        }
      });
      return;
    }

    final interruptionId = _approvals.remove(requestId);
    if (interruptionId == null) return;
    final sid = _sessionId;
    emit(InteractionResolved(nextSeq, requestId));

    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) => 'allowAll',
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'allow',
      _ => 'deny',
    };

    if (sid != null) {
      unawaited(
        _request('_codebuddy.ai/resolveInterruption', {
          'sessionId': sid,
          'interruptionId': interruptionId,
          'decision': decision,
        }),
      );
    }
  }

  void _onModelChanged(String modelId) {
    _pendingModel = modelId;
    final sid = _sessionId;
    if (sid != null) {
      unawaited(_request('session/set_model', {'sessionId': sid, 'modelId': modelId}));
    }
    emit(KernelInfoChanged(nextSeq));
  }

  void _onModeOrPermissionChanged() {
    final isPlan = mode.selected == 'plan';
    final targetMode = isPlan ? 'plan' : (permission.selected ?? 'default');
    _pendingMode = targetMode;
    final sid = _sessionId;
    if (sid != null) {
      unawaited(_request('session/set_mode', {'sessionId': sid, 'modeId': targetMode}));
    }
    emit(KernelInfoChanged(nextSeq));
  }


  void _handleServerRequest(Object? id, String? method, Map<String, Object?>? params) {
    if (id == null) return;

    if (method == 'session/request_permission') {
      final options = params?['options'] as List<Object?>? ?? const [];
      final toolCall = params?['toolCall'] as Map<String, Object?>?;
      final rawInput = toolCall?['rawInput'] as Map<String, Object?>? ?? const {};
      final meta = toolCall?['_meta'] as Map<String, Object?>? ?? const {};
      final toolName = meta['codebuddy.ai/toolName'] as String? ?? 'Tool';

      String allowOnceId = 'allow_once';
      String? allowAlwaysId;
      String denyId = 'deny';

      for (final opt in options) {
        if (opt is Map) {
          final oid = opt['optionId'] as String? ?? '';
          final kind = opt['kind'] as String? ?? '';
          if (oid == 'allow_always' || oid == 'allow_session') {
            allowAlwaysId = oid;
          } else if (kind == 'allow' || oid == 'allow' || oid == 'allow_once') {
            allowOnceId = oid;
          } else if (kind == 'reject' || oid == 'deny' || oid == 'reject') {
            denyId = oid;
          }
        }
      }

      // If in bypass mode, auto-approve immediately
      if (permission.selected == 'bypassPermissions') {
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'outcome': {
              'outcome': 'selected',
              'optionId': allowAlwaysId ?? allowOnceId,
            }
          }
        });
        return;
      }

      // If in dontAsk mode, auto-deny immediately
      if (permission.selected == 'dontAsk') {
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'outcome': {
              'outcome': 'selected',
              'optionId': denyId,
            }
          }
        });
        return;
      }

      // If in acceptEdits mode and tool is Edit/Write, auto-approve
      if (permission.selected == 'acceptEdits' && (toolName == 'Edit' || toolName == 'Write')) {
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'outcome': {
              'outcome': 'selected',
              'optionId': allowOnceId,
            }
          }
        });
        return;
      }

      // Otherwise, prompt user via interaction card
      final command = rawInput['command'] as String?;
      final filePath = (rawInput['path'] ?? rawInput['filePath'] ?? rawInput['file_path']) as String?;
      final ApprovalPreview? preview = switch (command) {
        final cmd? when cmd.isNotEmpty => CommandPreview(cmd),
        _ => switch (filePath) {
          final path? when path.isNotEmpty => TextPreview(path),
          _ => null,
        },
      };

      final title = switch (command) {
        final cmd? when cmd.isNotEmpty => '运行命令 $cmd？',
        _ => switch (filePath) {
          final path? when path.isNotEmpty => '操作文件 $path？',
          _ => '允许使用 $toolName？',
        },
      };

      final reqId = 'rpc_approval:$id';
      _pendingRpcApprovals[reqId] = _PendingPermissionRequest(
        rpcId: id,
        allowOnceOptionId: allowOnceId,
        allowAlwaysOptionId: allowAlwaysId,
        denyOptionId: denyId,
      );

      emit(
        InteractionRequested(
          nextSeq,
          ApprovalRequest(
            id: reqId,
            title: title,
            toolName: toolName,
            reason: rawInput['description'] as String?,
            preview: preview,
            alwaysAllowLabel: allowAlwaysId != null ? '在当前会话中始终允许' : null,
          ),
        ),
      );
      return;
    }

    if (method == 'fs/read_text_file' && params != null) {
      final filePath = params['path'] as String? ?? '';
      try {
        final content = File(filePath).readAsStringSync();
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'content': content},
        });
      } catch (e) {
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32000, 'message': e.toString()},
        });
      }
      return;
    }

    if (method == 'fs/write_text_file' && params != null) {
      final filePath = params['path'] as String? ?? '';
      final content = params['content'] as String? ?? '';
      try {
        File(filePath).writeAsStringSync(content);
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{},
        });
      } catch (e) {
        _transport?.write({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32000, 'message': e.toString()},
        });
      }
      return;
    }

    _transport?.write({
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, Object?>{},
    });
  }

  // --- ACP Event Handling ----------------------------------------------------

  void _receive(Map<String, Object?> message) {
    // 1. JSON-RPC response to a pending request
    if (message.containsKey('id') && !message.containsKey('method')) {
      final id = message['id'];
      if (message.containsKey('error')) {
        final error = message['error'];
        _responses.remove(id)?.completeError(
          StateError('RPC error for request $id: $error'),
        );
        return;
      }
      final result = (message['result'] as Map?)?.cast<String, Object?>();
      _responses.remove(id)?.complete(result ?? const {});
      return;
    }

    // 2. JSON-RPC request from server to client
    if (message.containsKey('id') && message.containsKey('method')) {
      final id = message['id'];
      final method = message['method'] as String?;
      final params = (message['params'] as Map?)?.cast<String, Object?>();
      _handleServerRequest(id, method, params);
      return;
    }

    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null || params == null) return;

    if (method == 'session/update') {
      final update = (params['update'] as Map?)?.cast<String, Object?>();
      if (update != null) {
        _handleSessionUpdate(update);
      }
    }
  }

  void _handleSessionUpdate(Map<String, Object?> update) {
    final type = update['sessionUpdate'] as String?;
    switch (type) {
      case 'config_option_update':
        _handleConfigOptions(update);
      case 'model_update':
        _handleModelUpdate(update);
      case 'mode_update':
        _handleModeUpdate(update);
      case 'current_mode_update':
        _handleCurrentModeUpdate(update);
      case 'available_commands_update':
        _handleAvailableCommands(update);
      case 'usage_update':
        _handleUsageUpdate(update);
      case 'agent_thought_chunk':
        _handleThoughtChunk(update);
      case 'agent_message_chunk':
        _handleMessageChunk(update);
      case 'tool_call':
        _handleToolCall(update);
      case 'tool_call_update':
        _handleToolCallUpdate(update);
      case 'interruption_request':
        _handleInterruptionRequest(update);
      case 'plan_update':
        if (update['plan'] case final String planText) {
          emit(PlanWritten(nextSeq, planText));
        }
    }
  }

  void _handleModelUpdate(Map<String, Object?> update) {
    final available = update['availableModels'] as List<Object?>? ?? const [];
    final currentModelId = update['currentModelId']?.toString();
    if (available.isNotEmpty) {
      _models.clear();
      for (final item in available) {
        if (item is! Map) continue;
        final modelId = (item['modelId'] ?? item['id'])?.toString() ?? '';
        if (modelId.isEmpty) continue;
        final name = item['name']?.toString() ?? modelId;
        final desc = item['description']?.toString();
        _models.add(_formatModelOption(modelId, name, desc));
      }
      model.options = List.of(_models);
      if (_pendingModel != null) {
        model.reported = _pendingModel;
      } else if (currentModelId != null) {
        model.reported = currentModelId;
      }
      emit(KernelInfoChanged(nextSeq));
    }
  }

  void _handleModeUpdate(Map<String, Object?> update) {
    _populateModesFromSessionResult(update);
  }

  void _handleCurrentModeUpdate(Map<String, Object?> update) {
    if (update['currentModeId'] case final String modeId) {
      _pendingMode = modeId;
      if (modeId == 'plan') {
        mode.reported = 'plan';
      } else {
        mode.reported = 'agent';
        permission.reported = modeId;
      }
      emit(KernelInfoChanged(nextSeq));
    }
  }

  void _handleConfigOptions(Map<String, Object?> update) {
    final optionsList = update['configOptions'] as List<Object?>? ?? const [];
    for (final opt in optionsList) {
      if (opt is! Map) continue;
      final id = opt['id']?.toString();
      final currentVal = opt['currentValue']?.toString();
      final items = opt['options'] as List<Object?>? ?? const [];

      if (id == 'model') {
        _models.clear();
        for (final item in items) {
          if (item is! Map) continue;
          final val = item['value']?.toString() ?? '';
          final rawName = item['name']?.toString() ?? val;
          final name = (val == 'default') ? 'Agent' : rawName;
          final desc = item['description']?.toString();
          _models.add(_formatModelOption(val, name, desc));
        }
        model.options = List.of(_models);
        if (currentVal != null) model.reported = currentVal;
      } else if (id == 'mode') {
        _permissions.clear();
        for (final item in items) {
          if (item is! Map) continue;
          final val = item['value']?.toString() ?? '';
          if (val == 'plan') continue;
          final name = item['name']?.toString() ?? val;
          final desc = item['description']?.toString() ?? '';
          _permissions.add(
            KernelOption(
              val,
              name,
              switch (val) {
                'acceptEdits' => Icons.edit_note_rounded,
                'auto' => Icons.auto_mode_rounded,
                'dontAsk' => Icons.visibility_outlined,
                'bypassPermissions' => Icons.all_inclusive_rounded,
                _ => Icons.lock_outline_rounded,
              },
              desc,
            ),
          );
        }
        permission.options = List.of(_permissions);
        if (currentVal != null) {
          if (currentVal == 'plan') {
            mode.reported = 'plan';
          } else {
            mode.reported = 'agent';
            permission.reported = currentVal;
          }
        }
      }
    }
    emit(KernelInfoChanged(nextSeq));
  }

  void _handleAvailableCommands(Map<String, Object?> update) {
    final cmds = update['availableCommands'] as List<Object?>? ?? const [];
    final list = <KernelCommand>[];
    for (final c in cmds) {
      if (c is! Map) continue;
      final name = c['name'] as String? ?? '';
      final desc = c['description'] as String? ?? '';
      list.add(
        KernelCommand(
          name,
          desc,
          switch (name) {
            'goal' => Icons.flag_outlined,
            'plan' => Icons.assignment_outlined,
            'review' => Icons.rate_review_outlined,
            'compact' => Icons.compress_rounded,
            'commit' => Icons.commit_outlined,
            _ => Icons.terminal_rounded,
          },
        ),
      );
    }
    _commands = list;
    emit(KernelInfoChanged(nextSeq));
  }

  void _handleUsageUpdate(Map<String, Object?> update) {
    final used = update['used'] as int? ?? 0;
    final size = update['size'] as int? ?? _contextWindow;
    _contextWindow = size;
    emit(UsageReported(nextSeq, ContextUsage(window: size, used: used)));
  }

  void _handleThoughtChunk(Map<String, Object?> update) {
    final content = update['content'] as Map?;
    final text = content?['text'] as String? ?? '';
    if (text.isEmpty) return;

    if (_currentThoughtId == null) {
      final tid = 'thought_${DateTime.now().millisecondsSinceEpoch}';
      _currentThoughtId = tid;
      _thoughtBuffer = StringBuffer();
      _thoughtClock = Stopwatch()..start();
      emit(
        ItemUpserted(
          nextSeq,
          tid,
          ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
          streaming: true,
        ),
      );
    }

    final id = _currentThoughtId!;
    final buf = _thoughtBuffer!;
    final offset = buf.length;
    buf.write(text);
    emit(TextDelta(nextSeq, id, offset, text, tokens: buf.length));
  }

  void _closeThoughtIfOpen() {
    final tid = _currentThoughtId;
    if (tid == null) return;
    final buf = _thoughtBuffer;
    final clock = _thoughtClock?..stop();
    _currentThoughtId = null;
    _thoughtBuffer = null;
    _thoughtClock = null;

    final text = buf?.toString() ?? '';
    emit(
      ItemCompleted(
        nextSeq,
        tid,
        item: ThinkingItem(
          text: text,
          tokens: text.length,
          seconds: math.max(1, ((clock?.elapsedMilliseconds ?? 0) / 1000).round()),
        ),
      ),
    );
  }

  void _handleMessageChunk(Map<String, Object?> update) {
    _closeThoughtIfOpen();

    final content = update['content'] as Map?;
    final text = content?['text'] as String? ?? '';
    if (text.isEmpty) return;

    if (_currentMessageId == null) {
      final mid = 'msg_${DateTime.now().millisecondsSinceEpoch}';
      _currentMessageId = mid;
      _messageBuffer = StringBuffer();
      emit(
        ItemUpserted(
          nextSeq,
          mid,
          const AssistantTextItem(''),
          streaming: true,
        ),
      );
    }

    final mid = _currentMessageId!;
    final buf = _messageBuffer!;
    final offset = buf.length;
    buf.write(text);
    emit(TextDelta(nextSeq, mid, offset, text));
  }

  void _closeMessageIfOpen() {
    final mid = _currentMessageId;
    if (mid == null) return;
    final text = _messageBuffer?.toString() ?? '';
    _currentMessageId = null;
    _messageBuffer = null;
    emit(
      ItemCompleted(
        nextSeq,
        mid,
        item: AssistantTextItem(text),
      ),
    );
  }

  void _handleToolCall(Map<String, Object?> update) {
    _closeThoughtIfOpen();

    final callId = update['toolCallId'] as String? ?? 'tool_${DateTime.now().millisecondsSinceEpoch}';
    final toolName = update['toolName'] as String? ?? 'Tool';
    final title = update['title'] as String? ?? toolName;
    final kindStr = update['kind'] as String? ?? 'other';

    final kind = switch (kindStr) {
      'read' => ToolKind.read,
      'edit' => ToolKind.edit,
      'execute' => ToolKind.command,
      'search' => ToolKind.search,
      'fetch' => ToolKind.web,
      _ => ToolKind.other,
    };

    emit(
      ItemUpserted(
        nextSeq,
        callId,
        ToolCallItem(
          kind: kind,
          target: title,
          tool: toolName,
          callId: callId,
          status: ToolStatus.running,
        ),
      ),
    );
  }

  void _handleToolCallUpdate(Map<String, Object?> update) {
    final callId = update['toolCallId'] as String?;
    if (callId == null) return;

    final statusStr = update['status'] as String? ?? 'completed';
    final status = switch (statusStr) {
      'failed' => ToolStatus.failed,
      'running' || 'in_progress' => ToolStatus.running,
      _ => ToolStatus.succeeded,
    };

    final result = update['toolResult']?.toString() ?? update['rawOutput']?.toString();

    emit(
      ItemCompleted(
        nextSeq,
        callId,
        item: ToolCallItem(
          kind: ToolKind.other,
          target: callId,
          status: status,
          output: result,
        ),
      ),
    );
  }

  void _handleInterruptionRequest(Map<String, Object?> update) {
    final interruptionId = update['interruptionId'] as String?;
    if (interruptionId == null) return;

    final reason = update['reason'] as String? ?? 'Permission required';
    final toolName = update['toolName'] as String? ?? 'Tool';
    final reqId = 'approval:$interruptionId';
    _approvals[reqId] = interruptionId;

    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: reqId,
          title: reason,
          toolName: toolName,
          reason: reason,
          alwaysAllowLabel: 'Always allow for this session',
        ),
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    _closeThoughtIfOpen();
    _closeMessageIfOpen();

    for (final entry in _pendingRpcApprovals.entries) {
      emit(InteractionResolved(nextSeq, entry.key));
      _transport?.write({
        'jsonrpc': '2.0',
        'id': entry.value.rpcId,
        'result': {
          'outcome': {
            'outcome': 'cancelled',
          }
        }
      });
    }
    _pendingRpcApprovals.clear();

    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();

    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}

class _PendingPermissionRequest {
  const _PendingPermissionRequest({
    required this.rpcId,
    required this.allowOnceOptionId,
    required this.denyOptionId,
    this.allowAlwaysOptionId,
  });

  final Object rpcId;
  final String allowOnceOptionId;
  final String? allowAlwaysOptionId;
  final String denyOptionId;
}
