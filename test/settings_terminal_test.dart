import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/screens/settings_screen.dart';
import 'package:mesterm/services/terminal_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppState> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppState();
    await tester.pump();
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('a colour scheme sets both colours and shows as chosen', (tester) async {
    final app = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('scheme-Solarized Light')));
    await tester.pumpAndSettle();
    expect(app.terminalBackground, const Color(0xFFFDF6E3));
    expect(app.terminalForeground, const Color(0xFF586E75));
    expect(
      find.descendant(of: find.byKey(const ValueKey('scheme-Solarized Light')), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
  });

  testWidgets('the contrast note follows the colours', (tester) async {
    final app = await pump(tester);
    await app.setTerminalColors(background: const Color(0xFF000000), foreground: const Color(0xFFFFFFFF));
    await tester.pumpAndSettle();
    expect(find.text('Contrast 21.0:1'), findsOneWidget);
    expect(find.text('Very readable'), findsOneWidget);
    await app.setTerminalColors(background: const Color(0xFF777777), foreground: const Color(0xFF888888));
    await tester.pumpAndSettle();
    expect(find.text('Hard to read'), findsOneWidget);
  });

  testWidgets('the size steps by one point within its range', (tester) async {
    final app = await pump(tester);
    final start = app.terminalFontSize.round();
    await tester.tap(find.byKey(const ValueKey('font-size-up')));
    await tester.pumpAndSettle();
    expect(app.terminalFontSize.round(), start + 1);
    expect(find.text('${start + 1} pt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('font-size-down')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('font-size-down')));
    await tester.pumpAndSettle();
    expect(app.terminalFontSize.round(), start - 1);
  });

  testWidgets('the font list can be searched, and a typed name used', (tester) async {
    final app = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('font-field')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font-picker')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('font-search')), 'Example Mono');
    await tester.pump();
    await tester.tap(find.text('Use "Example Mono"'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font-picker')), findsNothing);
    expect(app.terminalFontFamily, 'Example Mono');
  });

  testWidgets('the palette shows the new colour over the old, and a click on the old goes back', (tester) async {
    final app = await pump(tester);
    final before = app.terminalBackground;
    await tester.tap(find.byIcon(Icons.colorize).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('color-code')), '#3366CC');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('color-revert')));
    await tester.pump();
    final code = tester.widget<TextField>(find.byKey(const ValueKey('color-code'))).controller!.text;
    expect(code, colorToHex(before));
  });
}
