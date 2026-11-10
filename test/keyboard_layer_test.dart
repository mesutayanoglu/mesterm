import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/screens/home_screen.dart';
import 'package:mesterm/services/app_shortcuts.dart';
import 'package:mesterm/services/pane_layout.dart';
import 'package:mesterm/services/session_controller.dart';
import 'package:mesterm/services/update_service.dart';
import 'package:mesterm/theme/app_theme.dart';
import 'package:mesterm/widgets/status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

class _FakeSession implements TerminalSessionController {
  _FakeSession(this.host, [this.status = SessionStatus.running]);
  @override
  final terminal = Terminal();
  @override
  void reconnect() {}
  @override
  final String host;
  @override
  String? get tabTitle => host;
  @override
  SessionStatus status;
  @override
  Stream<SessionStatus> get statusStream => const Stream.empty();
  @override
  void dispose() {}
}

Future<AppState> _pumpHome(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  UpdateService.available.value = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async => call.method == 'isMaximized' ? false : null,
  );
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late AppState app;
  await tester.pumpWidget(ChangeNotifierProvider(
    create: (_) => app = AppState(),
    child: MaterialApp(theme: AppTheme.dark(), home: const HomeScreen()),
  ));
  await tester.pumpAndSettle();
  return app;
}

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Ctrl+Shift+P opens the palette; a command runs from it with the keyboard', (tester) async {
    await _pumpHome(tester);
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);

    await _chord(tester, LogicalKeyboardKey.keyP, shift: true);
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('command-palette-query')), 'new conn');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
    expect(find.text('CONNECTION'), findsOneWidget, reason: 'the new connection dialog is open');
  });

  testWidgets('the title bar search opens the palette, and Escape closes it', (tester) async {
    await _pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('title-bar-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
  });

  testWidgets('plain Ctrl keys are left to the session: Ctrl+K, Ctrl+W, Ctrl+A run nothing', (tester) async {
    await _pumpHome(tester);
    var ran = 0;
    final before = AppShortcuts.dispatcher;
    AppShortcuts.dispatcher = (_) => ran++;
    addTearDown(() => AppShortcuts.dispatcher = before);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (final key in [LogicalKeyboardKey.keyK, LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyP]) {
      final event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyK,
        logicalKey: key,
        timeStamp: Duration.zero,
      );
      expect(AppShortcuts.handle(event), KeyEventResult.ignored, reason: '${key.keyLabel} goes to the terminal');
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(ran, 0);
  });

  testWidgets('Ctrl+Tab moves through the tab bar, a split counting once', (tester) async {
    final app = await _pumpHome(tester);
    for (final id in ['1', '2', '3']) {
      app.tabs.add(OpenTab(id: id, controller: _FakeSession('192.0.2.$id')));
    }
    app.applyLayout(buildLayout(SplitPreset.sideBySide, ['1', '2']), editActive: true);
    final group = app.groups.single.id;
    expect(app.activeGroupId, group);

    await _chord(tester, LogicalKeyboardKey.tab);
    expect(app.activeGroupId, isNull);
    expect(app.tabs[app.activeTabIndex].id, '3');

    await _chord(tester, LogicalKeyboardKey.tab);
    expect(app.activeGroupId, group, reason: 'wraps round to the split');

    await _chord(tester, LogicalKeyboardKey.tab, shift: true);
    expect(app.tabs[app.activeTabIndex].id, '3');
  });

  testWidgets('the status bar names the active session, and says when there is none', (tester) async {
    final app = await _pumpHome(tester);
    expect(find.byKey(const ValueKey('status-bar')), findsOneWidget);
    expect(find.text('No open sessions'), findsOneWidget);
    expect(find.byKey(const ValueKey('status-bar-hints')), findsOneWidget);
    expect(find.text(AppShortcuts.label(AppCommand.palette)), findsWidgets);

    app.tabs.add(OpenTab(id: 'a', controller: _FakeSession('198.51.100.7', SessionStatus.starting)));
    app.setActiveTab(0);
    await tester.pump();
    expect(find.text('Connecting'), findsOneWidget);
    expect(find.descendant(of: find.byType(StatusBar), matching: find.text('198.51.100.7')), findsOneWidget);
  });

  test('shortcut labels read as typed', () {
    expect(AppShortcuts.label(AppCommand.palette), 'Ctrl+Shift+P');
    expect(AppShortcuts.label(AppCommand.nextTab), 'Ctrl+Tab');
    expect(AppShortcuts.label(AppCommand.settings), 'Ctrl+,');
  });
}
