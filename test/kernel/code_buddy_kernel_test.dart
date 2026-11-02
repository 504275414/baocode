import 'dart:async';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/code_buddy/code_buddy_kernel.dart';
import 'package:baocode/kernel/code_buddy/code_buddy_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

class MockCodeBuddyTransport implements CodeBuddyTransport {
  final StreamController<Map<String, Object?>> _controller =
      StreamController<Map<String, Object?>>.broadcast();

  final List<Map<String, Object?>> sent = [];

  @override
  Stream<Map<String, Object?>> get messages => _controller.stream;

  @override
  void write(Map<String, Object?> message) {
    sent.add(message);
    final id = message['id'];
    final method = message['method'] as String?;

    if (method == 'initialize') {
      _controller.add({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'protocolVersion': 1,
          'agentCapabilities': {'loadSession': true},
        },
      });
    } else if (method == 'session/new') {
      _controller.add({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'sessionId': 'test-session-123',
        },
      });
      // Simulate config options and commands update notifications
      _controller.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'test-session-123',
          'update': {
            'sessionUpdate': 'config_option_update',
            'configOptions': [
              {
                'id': 'model',
                'currentValue': 'hy4-preview',
                'options': [
                  {'value': 'hy4-preview', 'name': 'Hy4 Preview'},
                  {'value': 'deepseek-v4.1-flash', 'name': 'DeepSeek Flash'},
                ],
              },
              {
                'id': 'mode',
                'currentValue': 'default',
                'options': [
                  {'value': 'default', 'name': 'Always Ask'},
                  {'value': 'acceptEdits', 'name': 'Accept Edits'},
                ],
              },
            ],
          },
        },
      });
      _controller.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'test-session-123',
          'update': {
            'sessionUpdate': 'available_commands_update',
            'availableCommands': [
              {'name': 'goal', 'description': 'Run until goal reached'},
              {'name': 'plan', 'description': 'Plan preview'},
            ],
          },
        },
      });
    } else if (method == 'session/prompt') {
      // Simulate streaming chunks
      _controller.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'test-session-123',
          'update': {
            'sessionUpdate': 'agent_thought_chunk',
            'content': {'type': 'text', 'text': 'Thinking about problem...'},
          },
        },
      });
      _controller.add({
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': {
          'sessionId': 'test-session-123',
          'update': {
            'sessionUpdate': 'agent_message_chunk',
            'content': {'type': 'text', 'text': 'Hello from CodeBuddy!'},
          },
        },
      });
      _controller.add({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'stopReason': 'end_turn',
        },
      });
    }
  }

  @override
  void close() {
    _controller.close();
  }
}

void main() {
  test('CodeBuddyKernel initializes and streams responses correctly', () async {
    final mockTransport = MockCodeBuddyTransport();
    final kernel = CodeBuddyKernel(
      KernelRegistry.codeBuddy,
      const KernelContext(cwd: '/test/workspace'),
      startTransport: ({cwd}) async => mockTransport,
    );

    final events = <KernelEvent>[];
    kernel.events.listen(events.add);

    kernel.prepare();
    // Allow async connect to run
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(kernel.sessionId, 'test-session-123');
    expect(kernel.model.options.map((o) => o.id), contains('hy4-preview'));
    expect(kernel.commands.map((c) => c.name), contains('goal'));

    // Send a turn
    kernel.send(const KernelTurn(id: 'turn-1', text: 'Hi'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Verify events were emitted
    final types = events.map((e) => e.runtimeType).toList();
    expect(types, contains(TurnStarted));
    expect(types, contains(ItemUpserted));
    expect(types, contains(TextDelta));
    expect(types, contains(TurnEnded));

    kernel.dispose();
  });
}
