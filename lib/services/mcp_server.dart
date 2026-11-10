import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xterm/xterm.dart';

import '../app_version.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../widgets/device_icon.dart';
import 'command_safety.dart';
import 'pty_session.dart';
import 'serial_session.dart';
import 'session_controller.dart';

export 'command_safety.dart' show ChangeReason;

/// What the user is asked before a command the agent wants to run reaches
/// a device, and why it is asked.
class McpApproval {
  const McpApproval({required this.connectionName, required this.command, required this.reason});
  final String connectionName;
  final String command;
  final ChangeReason reason;
}

/// What a connected agent can do in MesTerm. It sees the whole app (saved
/// connections, folders, open tabs, terminal output), opens connections and
/// runs commands. A command runs without asking only when the agent calls it
/// a read and MesTerm knows it as read-only ([checkAgentCommand]); anything
/// else, and anything at a configuration prompt, waits for the user's yes.
/// Usernames and passwords are never in a tool result.
abstract class McpGateway {
  /// Saved connections matching the filters, at most [limit] of them, with
  /// `total` (all that match) and `returned`.
  Map<String, Object?> listConnections({String? folder, String? query, String? protocol, String? device, int limit = 50});
  List<Map<String, Object?>> listSessions();
  Future<String> openConnection(String connectionId);
  Future<Map<String, Object?>> sendCommand(
    String tabId,
    String command, {
    required String intent,
    bool wait = true,
    int timeoutMs = 15000,
    int maxChars = 8000,
  });
  Map<String, Object?> readOutput(String tabId, int cursor, {int maxChars = 8000});
  Map<String, Object?> readScreen(String tabId, {int lines = 200});
  void close();
}

class AppMcpGateway extends ChangeNotifier implements McpGateway {
  AppMcpGateway(this.app, {this.approve});

  final AppState app;

  /// Asks the user about one command. No answer, or no way to ask, is a no.
  final Future<bool> Function(McpApproval approval)? approve;

  /// Output captured per tab since the agent first used it.
  final _captures = <String, _CapturedSession>{};

  /// Tabs whose paging was turned off, with the session it was done in (a
  /// reconnected tab is a new session, and pages again).
  final _pagingOff = <String, SessionController>{};

  /// What turns paging off for this login only, by device kind. Not a
  /// configuration change, so it is sent without asking.
  static const pagingOffCommands = {
    DeviceKind.aruba: 'no page',
    DeviceKind.cisco: 'terminal length 0',
    DeviceKind.paloalto: 'set cli pager off',
    DeviceKind.huawei: 'screen-length 0 temporary',
  };

  /// Ask about every command, reads included. Off by default.
  bool askEveryCommand = false;
  static const _askAllKey = 'commands.mcp.askEveryCommand';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    askEveryCommand = prefs.getBool(_askAllKey) ?? false;
    notifyListeners();
  }

  Future<void> setAskEveryCommand(bool on) async {
    askEveryCommand = on;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_askAllKey, on);
  }

  String _folderPath(String? folderId) {
    final names = <String>[];
    final seen = <String>{};
    var id = folderId;
    while (id != null && seen.add(id)) {
      final f = app.folders.where((f) => f.id == id).firstOrNull;
      if (f == null) break;
      names.insert(0, f.name);
      id = f.parentId;
    }
    return names.join(' / ');
  }

  @override
  Map<String, Object?> listConnections({String? folder, String? query, String? protocol, String? device, int limit = 50}) {
    bool has(String? haystack, String? needle) =>
        needle == null || needle.trim().isEmpty || (haystack ?? '').toLowerCase().contains(needle.trim().toLowerCase());
    bool same(String? value, String? wanted) =>
        wanted == null || wanted.trim().isEmpty || (value ?? '').toLowerCase() == wanted.trim().toLowerCase();
    final matches = <Map<String, Object?>>[];
    for (final c in app.connections) {
      final path = _folderPath(c.folderId);
      final kind = DeviceIcon.of(c)?.name;
      if (!has(path, folder)) continue;
      if (!(has(c.name, query) || has(c.host, query))) continue;
      if (!same(c.protocol.name, protocol) || !same(kind, device)) continue;
      final tabs = [for (final t in app.tabs) if (t.connectionId == c.id) t.id];
      // Empty fields are left out: every byte is the agent's tokens.
      matches.add({
        'id': c.id,
        'name': c.name,
        if (path.isNotEmpty) 'folder': path,
        'protocol': c.protocol.name,
        if (c.host.isNotEmpty) 'host': c.host,
        'port': c.port,
        'device': ?kind,
        if (tabs.isNotEmpty) 'open_tabs': tabs,
      });
    }
    final shown = matches.take(limit.clamp(1, 1000)).toList();
    return {'connections': shown, 'total': matches.length, 'returned': shown.length};
  }

  @override
  List<Map<String, Object?>> listSessions() => [
    for (var i = 0; i < app.tabs.length; i++)
      {
        'tab_id': app.tabs[i].id,
        'title': app.tabs[i].controller.tabTitle ?? app.tabs[i].controller.host,
        'connection_id': app.tabs[i].connectionId,
        'kind': _kindOf(app.tabs[i].controller),
        'status': app.tabs[i].controller.status.name,
        'active': i == app.activeTabIndex,
        'readable': app.tabs[i].controller is TerminalSessionController,
      },
  ];

  static String _kindOf(SessionController c) => switch (c) {
    PtySessionController() => 'ssh',
    SerialSessionController() => 'serial',
    _ => 'rdp',
  };

  @override
  Future<String> openConnection(String connectionId) async {
    final connection = app.connections.where((c) => c.id == connectionId).firstOrNull;
    if (connection == null) throw ArgumentError('Connection not found.');
    final before = app.tabs.length;
    final error = await app.openConnection(connection);
    if (error != null) throw StateError(error);
    if (app.tabs.length <= before) throw StateError('Session was not opened.');
    return app.tabs.last.id;
  }

  OpenTab _tab(String tabId) {
    final tab = app.tabs.where((t) => t.id == tabId).firstOrNull;
    if (tab == null) {
      _captures.remove(tabId)?.close();
      throw ArgumentError('Tab not found.');
    }
    return tab;
  }

  TerminalSessionController _terminal(String tabId) {
    final c = _tab(tabId).controller;
    if (c is! TerminalSessionController) throw StateError('Not a terminal session (an RDP tab cannot be read).');
    return c;
  }

  /// Output of a tab from the moment the agent first used it. A tab that
  /// was reopened (another controller) starts a new capture.
  _CapturedSession? _capture(String tabId) {
    final c = _terminal(tabId);
    if (c is! PtySessionController) return null;
    final existing = _captures[tabId];
    if (existing != null && identical(existing.controller, c)) return existing;
    existing?.close();
    return _captures[tabId] = _CapturedSession(c);
  }

  /// The line the cursor is on: the device's prompt, once it is waiting.
  static String promptOf(Terminal terminal) {
    final b = terminal.buffer;
    final y = b.absoluteCursorY;
    return y >= 0 && y < b.height ? b.lines[y].getText().trimRight() : '';
  }

  @override
  Future<Map<String, Object?>> sendCommand(
    String tabId,
    String command, {
    required String intent,
    bool wait = true,
    int timeoutMs = 15000,
    int maxChars = 8000,
  }) async {
    if (command.isEmpty ||
        command.length > 4096 ||
        command.contains('\r') ||
        command.contains('\n') ||
        command.contains('\u0000')) {
      throw ArgumentError('Command must be one line of 1–4096 characters.');
    }
    if (intent != 'read' && intent != 'change') {
      throw ArgumentError('intent must be "read" or "change".');
    }
    final c = _terminal(tabId);
    if (c.status == SessionStatus.closed || c.status == SessionStatus.error) {
      throw StateError('Session is closed.');
    }
    final capture = _capture(tabId);
    var check = checkAgentCommand(command, intent: intent, prompt: promptOf(c.terminal));
    if (check.readOnly && askEveryCommand) check = const CommandCheck.change(ChangeReason.unknown);
    final asked = !check.readOnly;
    if (asked) {
      final tab = _tab(tabId);
      final name = app.connections.where((x) => x.id == tab.connectionId).firstOrNull?.name ??
          c.tabTitle ??
          c.host;
      final ask = approve;
      final yes = ask != null &&
          await ask(McpApproval(connectionName: name, command: command, reason: check.reason!));
      if (!yes) throw StateError('The user did not allow this command.');
      // Checked again: the tab may have closed while the user decided.
      final again = _terminal(tabId);
      if (!identical(again, c)) throw StateError('The session changed while the user decided.');
    }
    await _turnPagingOff(tabId, c, capture);
    final cursor = capture?.end ?? 0;
    final startLine = c.terminal.buffer.absoluteCursorY;
    c.terminal.onOutput?.call('$command\r');
    if (!wait) return {'cursor': cursor, 'asked_user': asked};

    // The wait starts here, after any approval: the user's thinking time is
    // not the device's.
    final timedOut = await _waitForPrompt(c, capture, Duration(milliseconds: timeoutMs.clamp(100, 600000)));
    final prompt = promptOf(c.terminal);
    final String output;
    if (capture != null) {
      output = _commandOutput(stripPager(cleanTerminalText(capture.textFrom(cursor))), command, prompt);
    } else {
      // A serial console has no output stream: what came below the
      // command's line, up to the prompt.
      final b = c.terminal.buffer;
      final end = b.absoluteCursorY;
      output = cleanTerminalText(stripPager([
        for (var i = startLine + 1; i < end && i < b.height; i++)
          if (i >= 0) b.lines[i].getText().trimRight(),
      ].join('\n')));
    }
    final (text, cut) = keepTail(output, maxChars);
    return {
      'output': text,
      'prompt': prompt,
      'config_mode': isConfigPrompt(prompt),
      'timed_out': timedOut,
      'status': c.status.name,
      'truncated': cut,
      'cursor': capture?.end ?? 0,
      'asked_user': asked,
    };
  }

  /// Once a tab, before the agent's first command in it: the device's own
  /// command for no paging, so long output comes whole. Its output is not
  /// part of any answer.
  Future<void> _turnPagingOff(String tabId, TerminalSessionController c, _CapturedSession? capture) async {
    if (identical(_pagingOff[tabId], c)) return;
    final tab = _tab(tabId);
    final conn = app.connections.where((x) => x.id == tab.connectionId).firstOrNull;
    final kind = conn == null ? null : DeviceIcon.of(conn);
    final command = pagingOffCommands[kind];
    // Unknown devices get nothing; the kind may be known by the next command.
    if (command == null) return;
    _pagingOff[tabId] = c;
    c.terminal.onOutput?.call('$command\r');
    await _waitForPrompt(c, capture, const Duration(seconds: 5), answerPager: false);
  }

  static final _osc = RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)');
  static final _csi = RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]');
  static final _escape = RegExp(r'\x1b(?:[()*+][0-9A-Za-z]|[@-Z\\^_=>78]|$)');
  static final _erased = RegExp(r'[^\x08\n]\x08');
  static final _controls = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]');

  /// Terminal output as text: no escape sequences (colours, cursor moves,
  /// `ESC[K`, `ESC[?25l`, titles), backspaced characters gone, `\r\n` as
  /// `\n` and other `\r`s dropped, no spaces at line ends, and no run of
  /// more than two blank lines (it becomes one).
  static String cleanTerminalText(String text) {
    var t = text.replaceAll(_osc, '').replaceAll(_csi, '').replaceAll(_escape, '');
    // A backspace takes back the character before it (pagers erase
    // themselves that way).
    while (_erased.hasMatch(t)) {
      t = t.replaceAll(_erased, '');
    }
    t = t.replaceAll('\r\n', '\n').replaceAll('\r', '').replaceAll(_controls, '');
    t = t.split('\n').map((l) => l.trimRight()).join('\n');
    return t.replaceAll(RegExp(r'\n{4,}'), '\n\n');
  }

  /// "--More--" and its kin, the way switches and firewalls page.
  static final _pager = RegExp(
    r'[ \t]*(?:<-+\s*more\s*-+>|-{2,4}\s*\(?more\)?\s*-{2,4})[ \t]*',
    caseSensitive: false,
  );

  static bool isPagerLine(String line) => _pager.hasMatch(line);

  /// [text] without the pager prompts that were answered while it came.
  static String stripPager(String text) => text
      .split('\n')
      .where((l) => l.replaceAll(_pager, '').replaceAll(RegExp(r'[\s\x08]'), '').isNotEmpty || !_pager.hasMatch(l))
      .map((l) => l.replaceAll(_pager, ''))
      .join('\n');

  /// At most this many pages are turned for one command.
  static const maxPages = 50;

  static const _poll = Duration(milliseconds: 50);

  /// How long the output must stay still, with a prompt under the cursor,
  /// before the command counts as finished.
  static const _quiet = Duration(milliseconds: 200);

  /// A line a device or shell waits at: ends in `#`, `>`, `$`, `%` or `]`.
  static final _promptLike = RegExp(r'[#>$%\]]\s*$');

  static bool looksLikePrompt(String line) {
    final l = line.trimRight();
    return l.isNotEmpty && l.length <= 200 && (_promptLike.hasMatch(l) || isConfigPrompt(l));
  }

  /// Waits until something came back and the cursor rests on a prompt again
  /// (as read_screen sees it), with the output still for [_quiet]. True when
  /// [timeout] ran out first.
  /// A pager prompt under the cursor is answered with a space ([maxPages] at
  /// most), in case turning paging off did not take.
  Future<bool> _waitForPrompt(
    TerminalSessionController c,
    _CapturedSession? capture,
    Duration timeout, {
    bool answerPager = true,
  }) async {
    final started = DateTime.now();
    Object signature() {
      final b = c.terminal.buffer;
      return capture?.end ?? '${b.height}:${b.absoluteCursorY}:${b.cursorX}';
    }

    final first = signature();
    var last = first;
    var lastChange = started;
    var pages = 0;
    Object? answeredAt;
    while (true) {
      await Future<void>.delayed(_poll);
      final now = DateTime.now();
      final sig = signature();
      if (sig != last) {
        last = sig;
        lastChange = now;
      }
      // One space per pager prompt: not again until the screen moved.
      if (answerPager && pages < maxPages && sig != answeredAt && isPagerLine(promptOf(c.terminal))) {
        answeredAt = sig;
        pages++;
        c.terminal.onOutput?.call(' ');
        continue;
      }
      final moved = last != first;
      if (moved && now.difference(lastChange) >= _quiet && looksLikePrompt(promptOf(c.terminal))) return false;
      if (c.status == SessionStatus.closed || c.status == SessionStatus.error) return false;
      if (now.difference(started) >= timeout) return true;
    }
  }

  /// The command's own output: without the echoed command line at the top
  /// and the prompt it ended at.
  static String commandOutput(String text, String command, String prompt) => _commandOutput(text, command, prompt);

  static String _commandOutput(String text, String command, String prompt) {
    var lines = text.split('\n');
    if (lines.isNotEmpty && lines.first.contains(command.trim())) lines = lines.sublist(1);
    if (lines.isNotEmpty) {
      final last = lines.last.replaceAll('\r', '').trimRight();
      if (last.isEmpty || last == prompt.trimRight() || looksLikePrompt(last)) lines = lines.sublist(0, lines.length - 1);
    }
    return lines.join('\n');
  }

  @override
  Map<String, Object?> readOutput(String tabId, int cursor, {int maxChars = 8000}) {
    final capture = _capture(tabId);
    if (capture == null) throw StateError('Use read_screen for this tab.');
    if (cursor < 0 || cursor > capture.end) throw ArgumentError('Invalid output cursor.');
    // Everything since the cursor, as text; past [maxChars], its end.
    final (text, cut) = keepTail(stripPager(cleanTerminalText(capture.textFrom(cursor))), maxChars);
    return {
      'output': text,
      'cursor': capture.end,
      'truncated': cut || cursor < capture.start,
      'status': capture.controller.status.name,
      if (capture.controller.lastError != null) 'error': capture.controller.lastError,
    };
  }

  /// [text], or its last [maxChars] characters (from a line start where one
  /// is near), and whether anything was cut.
  static (String, bool) keepTail(String text, int maxChars) {
    final limit = maxChars.clamp(100, 1000000);
    if (text.length <= limit) return (text, false);
    var tail = text.substring(text.length - limit);
    final nl = tail.indexOf('\n');
    if (nl >= 0 && nl < 200) tail = tail.substring(nl + 1);
    return (tail, true);
  }

  @override
  Map<String, Object?> readScreen(String tabId, {int lines = 200}) {
    final c = _terminal(tabId);
    final b = c.terminal.buffer;
    final count = lines.clamp(1, 2000);
    final end = b.height;
    final start = (end - count).clamp(0, end);
    final text = [for (var i = start; i < end; i++) b.lines[i].getText().trimRight()];
    while (text.isNotEmpty && text.last.isEmpty) {
      text.removeLast();
    }
    final prompt = promptOf(c.terminal);
    return {
      'text': text.join('\n'),
      'prompt': prompt,
      'config_mode': isConfigPrompt(prompt),
      'status': c.status.name,
    };
  }

  @override
  void close() {
    for (final capture in _captures.values) {
      capture.close();
    }
    _captures.clear();
  }
}

class _CapturedSession {
  _CapturedSession(this.controller) {
    _subscription = controller.outputStream.listen(_append);
  }

  final PtySessionController controller;
  late final StreamSubscription<String> _subscription;
  String _output = '';
  int _start = 0;
  static const _retain = 65536;

  int get end => _start + _output.length;

  /// The oldest offset still kept.
  int get start => _start;

  /// Everything from [cursor] on (or from the oldest kept, if it is older).
  String textFrom(int cursor) => _output.substring((max(cursor, _start) - _start).clamp(0, _output.length));

  void _append(String text) {
    _output += text;
    if (_output.length > _retain) {
      final drop = _output.length - _retain;
      _output = _output.substring(drop);
      _start += drop;
    }
  }

  void close() => unawaited(_subscription.cancel());
}

/// A local, opt-in Streamable HTTP MCP endpoint. A random URL path is the
/// bearer secret so a Secure MCP Tunnel can forward without custom headers.
class McpServer extends ChangeNotifier {
  McpServer(this.gateway, {this.port = 8765});

  final McpGateway gateway;
  final int port;
  HttpServer? _server;
  Future<void>? _starting;
  bool _disposed = false;
  String? _token;
  String? error;
  static const _enabledKey = 'commands.mcp.enabled';
  static const _tokenKey = 'commands.mcp.token';
  static const _maxBody = 1024 * 1024;

  bool get enabled => _server != null;
  String? get url =>
      enabled ? 'http://127.0.0.1:${_server!.port}/mcp/$_token' : null;

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!_disposed && prefs.getBool(_enabledKey) == true) await start();
  }

  Future<void> start({String? testToken}) {
    if (enabled || _disposed) return Future<void>.value();
    return _starting ??= _start(testToken).whenComplete(() => _starting = null);
  }

  Future<void> _start(String? testToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      final saved = prefs.getString(_tokenKey);
      _token =
          testToken ??
          (saved != null && saved.length >= 32 ? saved : _newToken());
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      if (_disposed) {
        await server.close(force: true);
        return;
      }
      _server = server;
      server.listen(_handle);
      if (testToken == null) {
        await prefs.setString(_tokenKey, _token!);
        await prefs.setBool(_enabledKey, true);
      }
      error = null;
    } catch (e) {
      final server = _server;
      await server?.close(force: true);
      error = e.toString();
      _server = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> stop() async {
    await _starting;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    gateway.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    if (!_disposed) notifyListeners();
  }

  static String _newToken() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('Connection', 'close');
    final host = request.headers.value(HttpHeaders.hostHeader);
    final validHost =
        host == '127.0.0.1:${_server?.port}' ||
        host == 'localhost:${_server?.port}';
    final origin = request.headers.value('Origin');
    final validOrigin =
        origin == null ||
        origin == 'http://127.0.0.1:${_server?.port}' ||
        origin == 'http://localhost:${_server?.port}';
    if (!validHost || !validOrigin || request.uri.path != '/mcp/$_token') {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    if (request.method != 'POST') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      response.statusCode = HttpStatus.unsupportedMediaType;
      await response.close();
      return;
    }
    try {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) {
          response.statusCode = HttpStatus.requestEntityTooLarge;
          await response.close();
          return;
        }
      }
      final message = jsonDecode(utf8.decode(bytes));
      if (message is! Map<String, dynamic> ||
          message['jsonrpc'] != '2.0' ||
          message['method'] is! String) {
        _json(
          response,
          _rpcError(
            message is Map ? message['id'] : null,
            -32600,
            'Invalid request',
          ),
        );
        return;
      }
      final id = message['id'];
      if (id == null) {
        response.statusCode = HttpStatus.accepted;
        await response.close();
        return;
      }
      final method = message['method'] as String;
      final params = message['params'] is Map<String, dynamic>
          ? message['params'] as Map<String, dynamic>
          : <String, dynamic>{};
      Object? result;
      switch (method) {
        case 'initialize':
          final requested = params['protocolVersion'];
          result = {
            'protocolVersion':
                ['2025-11-25', '2025-06-18', '2025-03-26'].contains(requested)
                ? requested
                : '2025-11-25',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'mesterm', 'version': appVersion},
            'instructions': 'MesTerm is an SSH, serial and RDP connection manager. You can see every saved connection (list_connections) and every open tab (list_sessions), open connections, read any terminal (read_screen, read_output) and run commands (send_command). Say with each command whether it only reads (intent "read") or changes something (intent "change"). A read MesTerm also knows as read-only (show, display, get, ping and the like) runs at once; anything else, and anything at a configuration prompt, waits for the user to allow it, and can be refused. Output arrives asynchronously: poll read_output with the returned cursor until the prompt comes back. Usernames and passwords are never shared.',
          };
          break;
        case 'ping':
          result = <String, Object>{};
          break;
        case 'tools/list':
          result = {'tools': _tools};
          break;
        case 'tools/call':
          result = await _call(params);
          break;
        default:
          _json(response, _rpcError(id, -32601, 'Method not found'));
          return;
      }
      _json(response, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } on FormatException {
      _json(response, _rpcError(null, -32700, 'Parse error'));
    } catch (e) {
      _json(response, _rpcError(null, -32603, 'Internal error: $e'));
    }
  }

  Future<Map<String, Object?>> _call(Map<String, dynamic> params) async {
    final name = params['name'];
    final args = params['arguments'] ?? <String, dynamic>{};
    if (name is! String || args is! Map<String, dynamic>) {
      return _toolResult('Invalid tool call.', error: true);
    }
    try {
      Object? value;
      switch (name) {
        case 'list_connections':
          String? opt(String key) {
            final v = args[key];
            if (v == null) return null;
            if (v is! String) throw ArgumentError('$key must be a string.');
            return v;
          }
          final limit = args['limit'] ?? 50;
          if (limit is! int) throw ArgumentError('limit must be an integer.');
          value = gateway.listConnections(
            folder: opt('folder'),
            query: opt('query'),
            protocol: opt('protocol'),
            device: opt('device'),
            limit: limit,
          );
          break;
        case 'list_sessions':
          value = {'sessions': gateway.listSessions()};
          break;
        case 'open_connection':
          value = {'tab_id': await gateway.openConnection(_string(args, 'connection_id'))};
          break;
        case 'send_command':
          final wait = args['wait'] ?? true;
          final timeout = args['timeout_ms'] ?? 15000;
          final maxChars = args['max_chars'] ?? 8000;
          if (maxChars is! int) throw ArgumentError('max_chars must be an integer.');
          if (wait is! bool) throw ArgumentError('wait must be true or false.');
          if (timeout is! int) throw ArgumentError('timeout_ms must be an integer.');
          value = await gateway.sendCommand(
            _string(args, 'tab_id'),
            _string(args, 'command'),
            intent: _string(args, 'intent'),
            wait: wait,
            timeoutMs: timeout,
            maxChars: maxChars,
          );
          break;
        case 'read_output':
          final cursor = args['cursor'] ?? 0;
          if (cursor is! int) throw ArgumentError('cursor must be an integer.');
          final maxChars = args['max_chars'] ?? 8000;
          if (maxChars is! int) throw ArgumentError('max_chars must be an integer.');
          value = gateway.readOutput(_string(args, 'tab_id'), cursor, maxChars: maxChars);
          break;
        case 'read_screen':
          final lines = args['lines'] ?? 200;
          if (lines is! int) throw ArgumentError('lines must be an integer.');
          value = gateway.readScreen(_string(args, 'tab_id'), lines: lines);
          break;
        default:
          throw ArgumentError('Unknown tool.');
      }
      return _toolResult(jsonEncode(value));
    } catch (e) {
      return _toolResult('$e', error: true);
    }
  }

  static String _string(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError('$key is required.');
    }
    return value;
  }

  static Map<String, Object?> _toolResult(String text, {bool error = false}) =>
      {
        'content': [
          {'type': 'text', 'text': text},
        ],
        if (error) 'isError': true,
      };

  static Map<String, Object?> _rpcError(Object? id, int code, String message) =>
      {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      };

  static void _json(HttpResponse response, Object data) {
    response.headers.contentType = ContentType.json;
    final bytes = utf8.encode(jsonEncode(data));
    response.contentLength = bytes.length;
    response.add(bytes);
    unawaited(response.close());
  }

  static const _tools = [
    {
      'name': 'list_connections',
      'description': 'Every saved connection: id, name, folder path, protocol, host, port, device kind, and the tabs it is open in. Usernames and passwords are not included.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'folder': {'type': 'string'},
          'query': {'type': 'string'},
          'protocol': {'type': 'string'},
          'device': {'type': 'string'},
          'limit': {'type': 'integer', 'default': 50, 'minimum': 1},
        },
      },
    },
    {
      'name': 'list_sessions',
      'description': 'Every open tab: tab_id, title, connection_id, kind (ssh, serial, rdp), status, whether it is the active tab, and whether its terminal can be read.',
      'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
    },
    {
      'name': 'open_connection',
      'description': 'Open a saved connection in a new MesTerm tab and return its tab_id.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'connection_id': {'type': 'string'},
        },
        'required': ['connection_id'],
      },
    },
    {
      'name': 'send_command',
      'description': 'Type one line followed by Enter into a terminal tab (SSH or serial). intent says what the command does: "read" for one that only shows something, "change" for anything that changes the device or the host. A read that MesTerm also recognises as read-only runs at once; anything else, and anything at a configuration prompt, waits for the user to allow it, and a refusal is returned as an error. Returns the output cursor from before the command and whether the user was asked.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'tab_id': {'type': 'string'},
          'command': {'type': 'string'},
          'intent': {
            'type': 'string',
            'enum': ['read', 'change'],
          },
          'wait': {'type': 'boolean', 'default': true},
          'timeout_ms': {'type': 'integer', 'default': 15000, 'minimum': 100},
          'max_chars': {'type': 'integer', 'default': 8000, 'minimum': 100},
        },
        'required': ['tab_id', 'command', 'intent'],
      },
    },
    {
      'name': 'read_output',
      'description': 'Read up to 8192 characters of an SSH tab\'s output from cursor (capture starts when the tab is first used through MCP). Use the returned cursor for the next read; output can arrive later.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'tab_id': {'type': 'string'},
          'cursor': {'type': 'integer', 'minimum': 0},
          'max_chars': {'type': 'integer', 'default': 8000, 'minimum': 100},
        },
        'required': ['tab_id'],
      },
    },
    {
      'name': 'read_screen',
      'description': 'The text of a terminal tab as it is on screen, with scrollback: the last lines (default 200, at most 2000), the prompt the cursor is on, and whether that prompt is a configuration prompt.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'tab_id': {'type': 'string'},
          'lines': {'type': 'integer', 'minimum': 1, 'maximum': 2000},
        },
        'required': ['tab_id'],
      },
    },
  ];

  @override
  void dispose() {
    _disposed = true;
    final server = _server;
    _server = null;
    unawaited(server?.close(force: true));
    gateway.close();
    super.dispose();
  }
}
