import 'dart:convert';
import 'dart:io';

import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/models/models.dart';
import 'package:mesterm/screens/settings_screen.dart';
import 'package:mesterm/services/pty_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mesterm/services/mcp_server.dart';

class _FakeGateway implements McpGateway {
  String? sent;
  String? sentIntent;

  @override
  Map<String, Object?> listConnections({String? folder, String? query, String? protocol, String? device, int limit = 50}) => {
    'connections': [
      {'id': 'device-01', 'name': 'DEVICE-01'},
    ],
    'total': 1,
    'returned': 1,
  };

  @override
  List<Map<String, Object?>> listSessions() => [
    {'tab_id': 'session-01', 'title': 'DEVICE-01'},
  ];

  @override
  Future<String> openConnection(String connectionId) async {
    if (connectionId != 'device-01') throw ArgumentError('Unknown connection');
    return 'session-01';
  }

  @override
  Future<Map<String, Object?>> sendCommand(
    String tabId,
    String command, {
    required String intent,
    bool wait = true,
    int timeoutMs = 15000,
    int maxChars = 8000,
    String keep = 'both',
  }) async {
    if (tabId != 'session-01') throw ArgumentError('Unknown session');
    sent = command;
    sentIntent = intent;
    return {'cursor': 5, 'asked_user': false};
  }

  @override
  Map<String, Object?> readOutput(
    String tabId,
    int cursor, {
    int maxChars = 8000,
    String keep = 'both',
    int? offset,
    int? length,
  }) => {
    'output': 'ok',
    'cursor': cursor + 2,
    'status': 'running',
  };

  @override
  Map<String, Object?> readScreen(String tabId, {int lines = 200}) => {'text': 'DEVICE-01#', 'prompt': 'DEVICE-01#'};

  @override
  void close() {}
}

Future<(int, Map<String, dynamic>?)> _request(
  String url,
  Object body, {
  String? origin,
}) async {
  final uri = Uri.parse(url);
  final socket = await Socket.connect(uri.host, uri.port);
  final bytes = utf8.encode(jsonEncode(body));
  socket.write('POST ${uri.path} HTTP/1.1\r\n');
  socket.write('Host: ${uri.host}:${uri.port}\r\n');
  socket.write('Content-Type: application/json\r\n');
  socket.write('Content-Length: ${bytes.length}\r\n');
  if (origin != null) socket.write('Origin: $origin\r\n');
  socket.write('Connection: close\r\n\r\n');
  socket.add(bytes);
  await socket.flush();
  final raw = await utf8.decoder.bind(socket).join();
  final split = raw.indexOf('\r\n\r\n');
  final status = int.parse(raw.substring(0, split).split(' ')[1]);
  final text = raw.substring(split + 4);
  return (
    status,
    text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('MCP handshake, tools, command and output over local HTTP', () async {
    final gateway = _FakeGateway();
    final server = McpServer(gateway, port: 0);
    await server.start(testToken: 'a' * 32);
    expect(server.enabled, isTrue);
    addTearDown(() => server.dispose());
    final url = server.url!;

    final (initStatus, init) = await _request(url, {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-11-25'},
    });
    expect(initStatus, 200);
    expect(init!['result']['protocolVersion'], '2025-11-25');

    final (noticeStatus, notice) = await _request(url, {
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    expect(noticeStatus, 202);
    expect(notice, isNull);

    final (_, listed) = await _request(url, {
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = listed!['result']['tools'] as List<dynamic>;
    expect(
      tools.map((t) => t['name']),
      containsAll([
        'list_connections',
        'open_connection',
        'send_command',
        'read_output',
        'list_sessions',
        'read_screen',
      ]),
    );
    final send = tools.firstWhere((t) => t['name'] == 'send_command') as Map;
    expect((send['inputSchema']['properties'] as Map).keys, containsAll(['wait', 'timeout_ms', 'max_chars', 'intent', 'keep']));
    expect(send['description'], contains('no need to call read_screen'));
    final list = tools.firstWhere((t) => t['name'] == 'list_connections') as Map;
    expect((list['inputSchema']['properties'] as Map).keys, containsAll(['folder', 'query', 'protocol', 'device', 'limit']));
    final read = tools.firstWhere((t) => t['name'] == 'read_output') as Map;
    expect((read['inputSchema']['properties'] as Map).keys, containsAll(['max_chars', 'keep', 'offset', 'length']));
    expect(send['description'], contains('skipped_from'));

    Future<Map<String, dynamic>> call(
      int id,
      String name,
      Map<String, Object> args,
    ) async {
      final (status, body) = await _request(url, {
        'jsonrpc': '2.0',
        'id': id,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      });
      expect(status, 200);
      return jsonDecode(body!['result']['content'][0]['text'] as String)
          as Map<String, dynamic>;
    }

    final connections = await call(3, 'list_connections', {});
    expect(connections['connections'], [
      {'id': 'device-01', 'name': 'DEVICE-01'},
    ]);
    final opened = await call(4, 'open_connection', {
      'connection_id': 'device-01',
    });
    expect(opened['tab_id'], 'session-01');
    final sent = await call(5, 'send_command', {
      'tab_id': 'session-01',
      'command': 'show version',
      'intent': 'read',
    });
    expect(sent['cursor'], 5);
    expect(gateway.sent, 'show version');
    expect(gateway.sentIntent, 'read');
    final screen = await call(7, 'read_screen', {'tab_id': 'session-01'});
    expect(screen['prompt'], 'DEVICE-01#');
    final output = await call(6, 'read_output', {
      'tab_id': 'session-01',
      'cursor': 5,
    });
    expect(output['output'], 'ok');
    expect(output['cursor'], 7);
  });

  test('secret path and foreign Origin cannot call tools', () async {
    final gateway = _FakeGateway();
    final server = McpServer(gateway, port: 0);
    await server.start(testToken: 'b' * 32);
    addTearDown(() => server.dispose());
    final url = server.url!;
    final body = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'};
    final (badPath, _) = await _request(
      url.replaceFirst('b' * 32, 'wrong'),
      body,
    );
    expect(badPath, 403);
    final (badOrigin, _) = await _request(
      url,
      body,
      origin: 'https://example.invalid',
    );
    expect(badOrigin, 403);
  });

  test('opt-in and secret survive an app restart', () async {
    final first = McpServer(_FakeGateway(), port: 0);
    await first.start();
    final secretPath = Uri.parse(first.url!).path;
    expect((await SharedPreferences.getInstance()).getBool('commands.mcp.enabled'), isTrue);
    first.dispose();

    final restored = McpServer(_FakeGateway(), port: 0);
    await restored.restore();
    expect(restored.enabled, isTrue);
    expect(Uri.parse(restored.url!).path, secretPath);
    await restored.stop();
    restored.dispose();
    expect((await SharedPreferences.getInstance()).getBool('commands.mcp.enabled'), isFalse);
  });

  test('simultaneous starts share one listener', () async {
    final server = McpServer(_FakeGateway(), port: 0);
    await Future.wait([server.start(), server.start()]);
    expect(server.enabled, isTrue);
    expect(server.error, isNull);
    await server.stop();
    server.dispose();
  });

  group('app gateway', () {
    late AppState app;
    late AppMcpGateway gateway;
    late List<McpApproval> asked;
    var answer = true;

    setUp(() async {
      PtySessionController.checkReachability = false;
      app = AppState();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final folder = ConnectionFolder(id: 'f1', name: 'CUSTOMER-A');
      app.folders = [folder];
      app.connections = [
        SavedConnection(id: 'c1', name: 'CORE-SW', host: '192.0.2.1', username: 'user1', password: 'secret-1', folderId: 'f1'),
        SavedConnection(id: 'c2', name: 'EDGE-FW', host: '192.0.2.2'),
      ];
      asked = [];
      answer = true;
      gateway = AppMcpGateway(app, approve: (a) async {
        asked.add(a);
        return answer;
      });
      await gateway.load();
    });
    tearDown(() {
      gateway.close();
      for (final t in app.tabs) {
        t.controller.dispose();
      }
      PtySessionController.checkReachability = true;
    });

    Future<(String, PtySessionController, List<String>)> open(String id) async {
      final tab = await gateway.openConnection(id);
      final c = app.tabs.last.controller as PtySessionController;
      // There is no real ssh here: let the start fail, then act as a live
      // session, so a wait never ends early on a dead one.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      c.status = SessionStatus.running;
      // Logged in: a prompt under the cursor.
      c.debugReceiveOutput('\r\nCORE-SW#');
      final sent = <String>[];
      c.writeOverride = sent.add;
      return (tab, c, sent);
    }

    test('every connection is listed, with its folder and host; never a username or password', () async {
      final listed = gateway.listConnections()['connections'] as List<Map<String, Object?>>;
      expect(listed.map((c) => c['name']), ['CORE-SW', 'EDGE-FW']);
      expect(listed.first['folder'], 'CUSTOMER-A');
      expect(listed.first['host'], '192.0.2.1');
      final json = jsonEncode(listed);
      expect(json, isNot(contains('user1')));
      expect(json, isNot(contains('secret-1')));
    });

    test('connections can be filtered; empty fields are left out; total and returned are counted', () async {
      app.connections.add(SavedConnection(id: 'c3', name: 'CORE-SW-2', host: '198.51.100.3', folderId: 'f1', protocol: ConnectionProtocol.rdp));
      Map<String, Object?> list({String? folder, String? query, String? protocol, String? device, int limit = 50}) =>
          gateway.listConnections(folder: folder, query: query, protocol: protocol, device: device, limit: limit);
      List<String?> names(Map<String, Object?> r) => [for (final c in r['connections'] as List) (c as Map)['name'] as String?];

      expect(names(list(folder: 'customer-a')), ['CORE-SW', 'CORE-SW-2'], reason: 'any case, part of the path');
      expect(names(list(query: '192.0.2.2')), ['EDGE-FW'], reason: 'by host');
      expect(names(list(query: 'core')), ['CORE-SW', 'CORE-SW-2'], reason: 'by name');
      expect(names(list(protocol: 'RDP')), ['CORE-SW-2']);
      expect(names(list(device: 'windows')), ['CORE-SW-2'], reason: 'RDP shows as Windows');
      final limited = list(limit: 1);
      expect(limited['total'], 3);
      expect(limited['returned'], 1);

      final edge = (list(query: 'EDGE')['connections'] as List).single as Map;
      expect(edge.containsKey('folder'), isFalse, reason: 'no folder: left out');
      expect(edge.containsKey('open_tabs'), isFalse, reason: 'no tabs: left out');
      expect(edge.containsKey('device'), isFalse);
      await gateway.openConnection('c1');
      final core = (list(query: 'CORE-SW', folder: 'customer')['connections'] as List).first as Map;
      expect(core['open_tabs'], hasLength(1));
    });

    test('a read the app also knows as read-only runs without asking', () async {
      final (tab, _, sent) = await open('c1');
      final result = await gateway.sendCommand(tab, 'show ip interface brief | include up', intent: 'read', wait: false);
      expect(sent, ['show ip interface brief | include up\r']);
      expect(result['asked_user'], isFalse);
      expect(asked, isEmpty);
    });

    test('a change asks first; a no sends nothing, a yes sends it', () async {
      final (tab, _, sent) = await open('c1');
      answer = false;
      await expectLater(gateway.sendCommand(tab, 'reload', intent: 'change', wait: false), throwsStateError);
      expect(sent, isEmpty);
      expect(asked.single.connectionName, 'CORE-SW');
      expect(asked.single.reason, ChangeReason.agentSaysChange);

      answer = true;
      final result = await gateway.sendCommand(tab, 'reload', intent: 'change', wait: false);
      expect(sent, ['reload\r']);
      expect(result['asked_user'], isTrue);
    });

    test('both sides must agree: a "read" the app does not know asks', () async {
      final (tab, _, sent) = await open('c1');
      await gateway.sendCommand(tab, 'write memory', intent: 'read', wait: false);
      expect(asked.single.reason, ChangeReason.unknown);
      await gateway.sendCommand(tab, 'show run; reload', intent: 'read', wait: false);
      expect(asked.last.reason, ChangeReason.chained);
      expect(sent, ['write memory\r', 'show run; reload\r'], reason: 'sent only after the yes');
    });

    test('at a configuration prompt every command asks', () async {
      final (tab, c, _) = await open('c1');
      c.debugReceiveOutput('CORE-SW(config-if)#');
      await gateway.sendCommand(tab, 'show this', intent: 'read', wait: false);
      expect(asked.single.reason, ChangeReason.configMode);
      expect(gateway.readScreen(tab)['config_mode'], isTrue);
    });

    test('"Ask before every command" asks for reads too', () async {
      await gateway.setAskEveryCommand(true);
      final (tab, _, _) = await open('c1');
      await gateway.sendCommand(tab, 'show version', intent: 'read', wait: false);
      expect(asked, hasLength(1));
      final reloaded = AppMcpGateway(app);
      await reloaded.load();
      expect(reloaded.askEveryCommand, isTrue, reason: 'remembered');
    });

    test('with no way to ask, a change does not run; a read still does', () async {
      final silent = AppMcpGateway(app);
      await silent.load();
      final tab = await silent.openConnection('c1');
      final c = app.tabs.last.controller as PtySessionController;
      final sent = <String>[];
      c.writeOverride = sent.add;
      c.debugReceiveOutput('\r\nCORE-SW#');
      await expectLater(silent.sendCommand(tab, 'reload', intent: 'change', wait: false), throwsStateError);
      await silent.sendCommand(tab, 'show version', intent: 'read', wait: false);
      expect(sent, ['show version\r']);
      silent.close();
    });

    test('a bad intent is refused before anything is asked', () async {
      final (tab, _, sent) = await open('c1');
      await expectLater(gateway.sendCommand(tab, 'show version', intent: 'maybe', wait: false), throwsArgumentError);
      expect(sent, isEmpty);
      expect(asked, isEmpty);
    });

    /// A device that answers each command after [delay]: the echo, [reply]
    /// and its prompt again.
    void device(PtySessionController c, String prompt, String Function(String command) reply,
        {Duration delay = const Duration(milliseconds: 30)}) {
      c.status = SessionStatus.running;
      c.debugReceiveOutput('\r\n$prompt');
      c.writeOverride = (data) {
        final command = data.replaceAll('\r', '');
        Future<void>.delayed(delay, () => c.debugReceiveOutput('$command\r\n${reply(command)}$prompt'));
      };
    }

    test('send_command waits for the prompt and returns only the command\'s output', () async {
      final (tab, c, _) = await open('c1');
      device(c, 'CORE-SW#', (cmd) => 'Cisco IOS Software, Version 17.9\r\nuptime is 4 weeks\r\n');
      final result = await gateway.sendCommand(tab, 'show version', intent: 'read');
      expect(result['timed_out'], isFalse);
      expect(result['prompt'], 'CORE-SW#');
      expect(result['config_mode'], isFalse);
      final output = (result['output'] as String).replaceAll('\r', '');
      expect(output, 'Cisco IOS Software, Version 17.9\nuptime is 4 weeks');
      expect(output, isNot(contains('show version')), reason: 'the echoed command line is left out');
      expect(result['cursor'], greaterThan(0));
    });

    test('with no prompt in time, what came so far is returned with timed_out', () async {
      final (tab, c, _) = await open('c1');
      c.debugReceiveOutput('CORE-SW#');
      c.writeOverride = (data) => Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => c.debugReceiveOutput('show tech\r\nline one\r\nstill going'),
      );
      final result = await gateway.sendCommand(tab, 'show tech', intent: 'read', timeoutMs: 500);
      expect(result['timed_out'], isTrue);
      expect((result['output'] as String).replaceAll('\r', ''), contains('line one'));
    });

    test('the wait starts after the user says yes', () async {
      final (tab, c, _) = await open('c1');
      device(c, 'CORE-SW#', (cmd) => 'done\r\n');
      final slow = AppMcpGateway(app, approve: (a) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return true;
      });
      final result = await slow.sendCommand(tab, 'write memory', intent: 'change', timeoutMs: 400);
      expect(result['timed_out'], isFalse, reason: 'the 600 ms of deciding do not count');
      expect((result['output'] as String).replaceAll('\r', ''), 'done');
      slow.close();
    });

    test('paging is turned off once per tab, by device kind, without asking, out of the output', () async {
      app.connections.first.device = DeviceKind.cisco;
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      c.debugReceiveOutput('CORE-SW#');
      c.writeOverride = (data) {
        sent.add(data);
        final command = data.replaceAll('\r', '');
        final reply = command == 'terminal length 0' ? '' : 'ver 17.9\r\n';
        Future<void>.delayed(const Duration(milliseconds: 20), () => c.debugReceiveOutput('$command\r\n${reply}CORE-SW#'));
      };
      final first = await gateway.sendCommand(tab, 'show version', intent: 'read');
      await gateway.sendCommand(tab, 'show clock', intent: 'read');
      expect(sent, ['terminal length 0\r', 'show version\r', 'show clock\r'], reason: 'once per tab');
      expect(asked, isEmpty, reason: 'not a configuration change');
      expect((first['output'] as String).replaceAll('\r', ''), 'ver 17.9');
    });

    test('an unknown device gets no paging command', () async {
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      device(c, 'EDGE-FW>', (cmd) => 'ok\r\n');
      final reply = c.writeOverride!;
      c.writeOverride = (d) {
        sent.add(d);
        reply(d);
      };
      await gateway.sendCommand(tab, 'show clock', intent: 'read');
      expect(sent, ['show clock\r']);
    });

    test('the paging commands, by device kind', () {
      expect(AppMcpGateway.pagingOffCommands, {
        DeviceKind.aruba: 'no page',
        DeviceKind.hpe: 'no page',
        DeviceKind.cisco: 'terminal length 0',
        DeviceKind.paloalto: 'set cli pager off',
        DeviceKind.huawei: 'screen-length 0 temporary',
      });
    });

    test('a pager prompt is answered with a space and left out of the output', () async {
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      c.debugReceiveOutput('EDGE-FW>');
      c.writeOverride = (data) {
        sent.add(data);
        if (data == ' ') {
          Future<void>.delayed(const Duration(milliseconds: 20), () => c.debugReceiveOutput('\r\nline two\r\nEDGE-FW>'));
        } else {
          final command = data.replaceAll('\r', '');
          Future<void>.delayed(
            const Duration(milliseconds: 20),
            () => c.debugReceiveOutput('$command\r\nline one\r\n --More-- '),
          );
        }
      };
      final result = await gateway.sendCommand(tab, 'show log', intent: 'read');
      expect(sent, ['show log\r', ' ']);
      final output = (result['output'] as String).replaceAll('\r', '');
      expect(output, isNot(contains('More')));
      expect(output, contains('line one'));
      expect(output, contains('line two'));
      expect(result['timed_out'], isFalse);
    });

    test('pager markers of the common devices are recognised', () {
      for (final l in ['-- MORE --', '--More--', ' --More-- ', '<--- More --->', '---- More ----']) {
        expect(AppMcpGateway.isPagerLine(l), isTrue, reason: l);
      }
      expect(AppMcpGateway.isPagerLine('SW#'), isFalse);
      expect(AppMcpGateway.stripPager('a\n --More-- \nb'), 'a\nb');
    });

    test('send_command output is clean text', () async {
      final (tab, c, _) = await open('c1');
      device(c, 'CORE-SW#', (cmd) => '\x1b[?25l\x1b[1mInterface\x1b[0m   Status  \x1b[K\r\nGi0/1   \x1b[32mup\x1b[0m\r\n\r\n\r\n\r\n\r\nend\r\n');
      final result = await gateway.sendCommand(tab, 'show int status', intent: 'read');
      expect(result['output'], 'Interface   Status\nGi0/1   up\n\nend');
    });

    /// A device whose [command] prints lines 0 to [count] - 1.
    Future<(String, PtySessionController, String)> longOutput({int count = 400}) async {
      final (tab, c, _) = await open('c1');
      final lines = [for (var i = 0; i < count; i++) 'line $i'];
      device(c, 'CORE-SW#', (cmd) => '${lines.join('\r\n')}\r\n');
      return (tab, c, lines.join('\n'));
    }

    test('a long output keeps head and tail by default, says what it skipped, and read_output fetches it', () async {
      final (tab, _, full) = await longOutput();
      final result = await gateway.sendCommand(tab, 'show log', intent: 'read', maxChars: 500);
      final output = result['output'] as String;
      expect(result['truncated'], isTrue);
      expect(result['total_chars'], full.length);
      expect(output, startsWith('line 0\n'));
      expect(output, endsWith('line 399'));
      final from = result['skipped_from'] as int;
      final to = result['skipped_to'] as int;
      expect(output, contains('... ${to - from} karakter atlandı ...'));
      expect(from, 250);
      expect(full.length - to, 250, reason: 'half of max_chars each side');

      // The skipped part, without running the command again.
      final skipped = gateway.readOutput(tab, 0, offset: from, length: to - from);
      expect(skipped['output'], full.substring(from, to));
      expect(skipped['total_chars'], full.length);
      expect(skipped['has_more'], isTrue);
      expect(full.substring(0, from) + (skipped['output'] as String) + full.substring(to), full,
          reason: 'head + skipped + tail is the whole output');
    });

    test('keep head and keep tail', () async {
      final (tab, _, full) = await longOutput();
      final head = await gateway.sendCommand(tab, 'show log', intent: 'read', maxChars: 300, keep: 'head');
      expect(head['output'], full.substring(0, 300));
      expect((head['skipped_from'], head['skipped_to']), (300, full.length));

      final tail = await gateway.sendCommand(tab, 'show log', intent: 'read', maxChars: 300, keep: 'tail');
      expect(tail['output'], full.substring(full.length - 300));
      expect((tail['skipped_from'], tail['skipped_to']), (0, full.length - 300));

      await expectLater(gateway.sendCommand(tab, 'show log', intent: 'read', keep: 'middle'), throwsArgumentError);
    });

    test('an output that fits is whole, with no skip fields', () async {
      final (tab, _, _) = await longOutput(count: 3);
      final result = await gateway.sendCommand(tab, 'show log', intent: 'read');
      expect(result['truncated'], isFalse);
      expect(result.containsKey('skipped_from'), isFalse);
      expect(result.containsKey('total_chars'), isFalse);
    });

    test('the last output is kept until the next command in the tab', () async {
      final (tab, c, full) = await longOutput();
      expect(() => gateway.readOutput(tab, 0, offset: 0), throwsStateError, reason: 'nothing kept yet');
      await gateway.sendCommand(tab, 'show log', intent: 'read', maxChars: 200);
      expect(gateway.readOutput(tab, 0, offset: 0, length: 6)['output'], 'line 0');
      expect(() => gateway.readOutput(tab, 0, offset: full.length + 1), throwsArgumentError);

      device(c, 'CORE-SW#', (cmd) => 'new output\r\n');
      await gateway.sendCommand(tab, 'show clock', intent: 'read');
      expect(gateway.readOutput(tab, 0, offset: 0)['output'], 'new output', reason: 'replaced by the next command');
    });

    test('read_output since a cursor is cut the same way', () async {
      final (tab, _, _) = await longOutput();
      final sent = await gateway.sendCommand(tab, 'show log', intent: 'read', wait: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final read = gateway.readOutput(tab, sent['cursor'] as int, maxChars: 300);
      expect(read['truncated'], isTrue);
      expect(read['output'], contains('karakter atlandı'));
      final skipped = gateway.readOutput(tab, 0, offset: read['skipped_from'] as int, length: 10);
      expect(skipped['length'], 10);
    });

    test('a device that redraws the whole screen: each output is only its own command\'s', () async {
      final (tab, c, _) = await open('c1');
      // ArubaOS-Switch: for every command, ESC[H ESC[K and the whole screen
      // again, every earlier command and its output included.
      final screen = <String>[];
      const prompt = 'CORE-SW# ';
      final replies = {
        'show system': ['Name : CORE-SW', 'Uptime : 4 days'],
        'show vlans': ['VLAN 10 DATA', 'VLAN 20 VOICE'],
        'show time': ['Mon Nov 10 09:14:22 2026'],
      };
      c.status = SessionStatus.running;
      c.debugReceiveOutput(prompt);
      c.writeOverride = (data) {
        final command = data.replaceAll('\r', '');
        screen.add('$prompt$command');
        screen.addAll(replies[command]!);
        final redraw = StringBuffer('\x1b[H\x1b[K');
        for (final line in screen) {
          redraw.write('$line\x1b[K\r\n');
        }
        redraw.write(prompt);
        Future<void>.delayed(const Duration(milliseconds: 20), () => c.debugReceiveOutput(redraw.toString()));
      };
      for (final command in replies.keys) {
        final result = await gateway.sendCommand(tab, command, intent: 'read');
        expect(result['echo_found'], isTrue, reason: command);
        expect(result['output'], replies[command]!.join('\n'), reason: 'only $command\'s own output');
      }
    });

    test('no echo found: the whole text, as before, with echo_found false', () async {
      final (tab, c, _) = await open('c1');
      device(c, 'CORE-SW#', (cmd) => 'some output\r\n');
      // A device that does not echo: the reply drops the command line.
      c.writeOverride = (data) => Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => c.debugReceiveOutput('\r\nsome output\r\nCORE-SW#'),
      );
      final result = await gateway.sendCommand(tab, 'show clock', intent: 'read');
      expect(result['echo_found'], isFalse);
      expect(result['output'], contains('some output'));
    });

    /// An ArubaOS-Switch, as far as these tests need one: after login a
    /// "Press any key to continue" banner that takes the first key it gets
    /// (and so the first letter of a command typed into it), long output
    /// paged with "-- MORE --" until `no page`.
    void aruba(PtySessionController c, List<String> sent, {bool banner = true}) {
      const prompt = 'CORE-SW# ';
      var bannerUp = banner;
      var paging = true;
      var pending = <String>[];
      final log = [for (var i = 1; i <= 60; i++) 'I 11/10/26 09:${i.toString().padLeft(2, '0')} 00076 ports: port $i is now on-line'];
      void reply(String text) => Future<void>.delayed(const Duration(milliseconds: 15), () => c.debugReceiveOutput(text));
      void run(String command) {
        final out = StringBuffer('$command\r\n');
        if (command == 'no page') {
          paging = false;
        } else if (command == 'show system') {
          out.write('Name : CORE-SW\r\n');
        } else if (command == 'show logging -r') {
          if (paging) {
            out.write(log.take(20).join('\r\n'));
            out.write('\r\n-- MORE --, next page: Space, next line: Enter, quit: Control-C');
            pending = log.skip(20).toList();
            reply(out.toString());
            return;
          }
          out.write('${log.join('\r\n')}\r\n');
        } else {
          out.write('Invalid input: ${command.split(' ').first}\r\n');
        }
        reply('$out$prompt');
      }

      c.status = SessionStatus.running;
      c.debugReceiveOutput(banner ? '\r\nHP J9729A Switch 2920-48G\r\n\r\nPress any key to continue' : '\r\n$prompt');
      c.writeOverride = (data) {
        sent.add(data);
        if (bannerUp) {
          bannerUp = false;
          reply('\x1b[2J\x1b[H$prompt');
          // The key that closed the banner is gone; the rest is typed on.
          final rest = data.substring(1).replaceAll('\r', '');
          if (rest.isNotEmpty) Future<void>.delayed(const Duration(milliseconds: 30), () => run(rest));
          return;
        }
        if (data == ' ' && pending.isNotEmpty) {
          final page = pending.take(20).toList();
          pending = pending.skip(20).toList();
          reply('\r\x1b[K${page.join('\r\n')}${pending.isEmpty ? '\r\n$prompt' : '\r\n-- MORE --, next page: Space, next line: Enter, quit: Control-C'}');
          return;
        }
        run(data.replaceAll('\r', ''));
      };
    }

    test('a "Press any key" banner gets one space first; then no page; the command last, whole', () async {
      app.connections.first.device = DeviceKind.aruba;
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      aruba(c, sent);
      final result = await gateway.sendCommand(tab, 'show system', intent: 'read');
      expect(sent, [' ', 'no page\r', 'show system\r'], reason: 'banner key, paging off, then the command');
      expect(result['output'], 'Name : CORE-SW', reason: 'not "how system"');
      expect(asked, isEmpty, reason: 'none of the preparation is asked about');
    });

    test('Aruba: with paging off, show logging -r comes whole, no -- MORE --', () async {
      app.connections.first.device = DeviceKind.aruba;
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      aruba(c, sent, banner: false);
      final result = await gateway.sendCommand(tab, 'show logging -r', intent: 'read');
      final output = result['output'] as String;
      expect(output, isNot(contains('MORE')));
      expect(output, contains('port 1 is now on-line'));
      expect(output, contains('port 60 is now on-line'));
      expect(sent, ['no page\r', 'show logging -r\r'], reason: 'no page took: no pager prompt had to be answered');
    });

    test('Aruba without paging off: the pager is answered and its whole line left out', () async {
      final (tab, c, _) = await open('c1');
      final sent = <String>[];
      aruba(c, sent, banner: false);
      final result = await gateway.sendCommand(tab, 'show logging -r', intent: 'read');
      final output = result['output'] as String;
      expect(sent.where((d) => d == ' '), hasLength(2), reason: 'two pages turned');
      expect(output, isNot(contains('MORE')));
      expect(output, isNot(contains('next page')));
      expect(output, contains('port 60 is now on-line'));
      expect('\n'.allMatches(output).length, 59, reason: '60 lines, nothing doubled or lost');
    });

    test('wait: false keeps the old answer: just the cursor', () async {
      final (tab, _, sent) = await open('c1');
      final result = await gateway.sendCommand(tab, 'show version', intent: 'read', wait: false);
      expect(result.keys, containsAll(['cursor', 'asked_user']));
      expect(result.containsKey('output'), isFalse);
      expect(sent, ['show version\r']);
    });

    test('any open tab can be read, not only ones the agent opened', () async {
      await app.openConnection(app.connections[1]);
      final c = app.tabs.last.controller as PtySessionController;
      c.debugReceiveOutput('EDGE-FW> ');
      final sessions = gateway.listSessions();
      expect(sessions.single['connection_id'], 'c2');
      expect(sessions.single['kind'], 'ssh');
      final screen = gateway.readScreen(sessions.single['tab_id'] as String);
      expect(screen['text'], contains('EDGE-FW>'));
      expect(screen['prompt'], endsWith('EDGE-FW>'), reason: 'the line the cursor is on');
      expect(screen['config_mode'], isFalse);
    });
  });

  test('app gateway reads output from the opened SSH tab', () async {
    PtySessionController.checkReachability = false;
    addTearDown(() => PtySessionController.checkReachability = true);
    final app = AppState();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    app.connections = [SavedConnection(id: 'device-01', name: 'DEVICE-01', host: '192.0.2.1')];
    final gateway = AppMcpGateway(app);
    await gateway.load();
    final tab = await gateway.openConnection('device-01');
    final controller = app.tabs.last.controller as PtySessionController;
    addTearDown(() {
      gateway.close();
      controller.dispose();
      app.dispose();
    });
    expect(gateway.readOutput(tab, 0)['output'], '', reason: 'capture starts on first use');
    controller.debugReceiveOutput('\x1b[32mdevice\x1b[0m prompt> \r\n');
    final output = gateway.readOutput(tab, 0);
    expect(output['output'], 'device prompt>\n', reason: 'cleaned: no colours, no \\r, no trailing space');
    expect(output['cursor'], 26, reason: 'the cursor still counts what came');
  });

  group('cleanTerminalText', () {
    String clean(String s) => AppMcpGateway.cleanTerminalText(s);

    test('escape sequences go: CSI, OSC, erase line, cursor hide, charset', () {
      expect(clean('\x1b[31mred\x1b[0m'), 'red');
      expect(clean('a\x1b[Kb\x1b[?25l\x1b[?25h'), 'ab');
      expect(clean('\x1b]0;window title\x07text'), 'text');
      expect(clean('\x1b]2;t\x1b\\x'), 'x');
      expect(clean('\x1b(Bplain\x1b=\x1b>'), 'plain');
      expect(clean('\x1b[2J\x1b[1;1Htop'), 'top');
    });

    test('line ends, lone carriage returns, trailing spaces, blank runs', () {
      expect(clean('a\r\nb\r\n'), 'a\nb\n');
      expect(clean('a\rb'), 'ab');
      expect(clean('a   \nb\t\n'), 'a\nb\n');
      expect(clean('a\n\n\nb'), 'a\n\n\nb', reason: 'two blank lines stay');
      expect(clean('a\n\n\n\n\nb'), 'a\n\nb', reason: 'more than two become one');
    });

    test('backspaced characters are taken back', () {
      expect(clean(' --More-- \x08\x08\x08\x08\x08\x08\x08\x08\x08\x08line'), 'line');
    });
  });

  testWidgets('Settings shows local MCP controls', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    final server = McpServer(_FakeGateway(), port: 0);
    addTearDown(server.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<McpServer>.value(value: server),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Allow MCP access'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets, reason: 'MCP access, and beta updates');
    expect(server.enabled, isFalse);
  });
}
