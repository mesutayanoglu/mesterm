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
  List<Map<String, Object?>> listConnections() => [
    {'id': 'device-01', 'name': 'DEVICE-01'},
  ];

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
  Future<Map<String, Object?>> sendCommand(String tabId, String command, {required String intent}) async {
    if (tabId != 'session-01') throw ArgumentError('Unknown session');
    sent = command;
    sentIntent = intent;
    return {'cursor': 5, 'asked_user': false};
  }

  @override
  Map<String, Object?> readOutput(String tabId, int cursor) => {
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
      final sent = <String>[];
      c.writeOverride = sent.add;
      return (tab, c, sent);
    }

    test('every connection is listed, with its folder and host; never a username or password', () async {
      final listed = gateway.listConnections();
      expect(listed.map((c) => c['name']), ['CORE-SW', 'EDGE-FW']);
      expect(listed.first['folder'], 'CUSTOMER-A');
      expect(listed.first['host'], '192.0.2.1');
      final json = jsonEncode(listed);
      expect(json, isNot(contains('user1')));
      expect(json, isNot(contains('secret-1')));
    });

    test('a read the app also knows as read-only runs without asking', () async {
      final (tab, _, sent) = await open('c1');
      final result = await gateway.sendCommand(tab, 'show ip interface brief | include up', intent: 'read');
      expect(sent, ['show ip interface brief | include up\r']);
      expect(result['asked_user'], isFalse);
      expect(asked, isEmpty);
    });

    test('a change asks first; a no sends nothing, a yes sends it', () async {
      final (tab, _, sent) = await open('c1');
      answer = false;
      await expectLater(gateway.sendCommand(tab, 'reload', intent: 'change'), throwsStateError);
      expect(sent, isEmpty);
      expect(asked.single.connectionName, 'CORE-SW');
      expect(asked.single.reason, ChangeReason.agentSaysChange);

      answer = true;
      final result = await gateway.sendCommand(tab, 'reload', intent: 'change');
      expect(sent, ['reload\r']);
      expect(result['asked_user'], isTrue);
    });

    test('both sides must agree: a "read" the app does not know asks', () async {
      final (tab, _, sent) = await open('c1');
      await gateway.sendCommand(tab, 'write memory', intent: 'read');
      expect(asked.single.reason, ChangeReason.unknown);
      await gateway.sendCommand(tab, 'show run; reload', intent: 'read');
      expect(asked.last.reason, ChangeReason.chained);
      expect(sent, ['write memory\r', 'show run; reload\r'], reason: 'sent only after the yes');
    });

    test('at a configuration prompt every command asks', () async {
      final (tab, c, _) = await open('c1');
      c.debugReceiveOutput('CORE-SW(config-if)#');
      await gateway.sendCommand(tab, 'show this', intent: 'read');
      expect(asked.single.reason, ChangeReason.configMode);
      expect(gateway.readScreen(tab)['config_mode'], isTrue);
    });

    test('"Ask before every command" asks for reads too', () async {
      await gateway.setAskEveryCommand(true);
      final (tab, _, _) = await open('c1');
      await gateway.sendCommand(tab, 'show version', intent: 'read');
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
      await expectLater(silent.sendCommand(tab, 'reload', intent: 'change'), throwsStateError);
      await silent.sendCommand(tab, 'show version', intent: 'read');
      expect(sent, ['show version\r']);
      silent.close();
    });

    test('a bad intent is refused before anything is asked', () async {
      final (tab, _, sent) = await open('c1');
      await expectLater(gateway.sendCommand(tab, 'show version', intent: 'maybe'), throwsArgumentError);
      expect(sent, isEmpty);
      expect(asked, isEmpty);
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
    controller.debugReceiveOutput('device prompt> ');
    final output = gateway.readOutput(tab, 0);
    expect(output['output'], 'device prompt> ');
    expect(output['cursor'], 15);
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
