import 'dart:async';

import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/services/session_controller.dart';
import 'package:mesterm/widgets/terminal_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

class _Fake implements TerminalSessionController {
  _Fake(this.status);
  @override
  final host = '192.0.2.10';
  @override
  String? get tabTitle => 'DEVICE-01';
  @override
  SessionStatus status;
  final _s = StreamController<SessionStatus>.broadcast();
  @override
  Stream<SessionStatus> get statusStream => _s.stream;
  void set(SessionStatus v) {
    status = v;
    _s.add(v);
  }

  @override
  final terminal = Terminal();
  int reconnects = 0;
  @override
  void reconnect() => reconnects++;
  @override
  void dispose() {}
}

void main() {
  Future<AppState> pump(WidgetTester tester, _Fake c) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    app.tabs.add(OpenTab(id: 'a', controller: c));
    app.setActiveTab(0);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        home: Scaffold(body: SessionStateBar(controller: c, onReconnect: c.reconnect)),
      ),
    ));
    await tester.pump();
    return app;
  }

  testWidgets('a running session shows no bar; a failed one says so and offers Reconnect', (tester) async {
    final c = _Fake(SessionStatus.running);
    await pump(tester, c);
    expect(find.byKey(const ValueKey('session-ended')), findsNothing);

    c.set(SessionStatus.error);
    await tester.pump();
    await tester.pump();
    expect(find.text('Could not connect to 192.0.2.10'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-reconnect')));
    expect(c.reconnects, 1);
  });

  testWidgets('an ended session says so; Close tab closes it', (tester) async {
    final c = _Fake(SessionStatus.closed);
    final app = await pump(tester, c);
    expect(find.text('Session ended'), findsOneWidget);
    await tester.tap(find.text('Close tab'));
    await tester.pump();
    expect(app.tabs, isEmpty);
  });

  testWidgets('a session that is not an SSH one shows nothing while it starts', (tester) async {
    await pump(tester, _Fake(SessionStatus.starting));
    expect(find.byKey(const ValueKey('session-connecting')), findsNothing);
    expect(find.byKey(const ValueKey('session-ended')), findsNothing);
  });
}
