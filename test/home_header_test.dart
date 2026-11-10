import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/screens/home_screen.dart';
import 'package:mesterm/services/update_service.dart';
import 'package:mesterm/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the sidebar\'s + opens a new connection; settings and search are in the title bar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    UpdateService.available.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => UpdateService.available.value = null);

    late AppState app;
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => app = AppState(),
      child: MaterialApp(theme: AppTheme.light(), home: const HomeScreen()),
    ));
    await tester.pumpAndSettle();

    // The "+" sits at the right of the filter box, inside the sidebar; the
    // settings and the update button live in the title bar.
    final button = find.byKey(const Key('sidebar-new-connection'));
    expect(button, findsOneWidget);
    expect(tester.getTopRight(button).dx, lessThanOrEqualTo(app.sidebarWidth));
    final settings = find.byIcon(Icons.settings_outlined);
    expect(tester.getCenter(settings).dy, lessThan(40), reason: 'in the title bar');

    // The search is in the middle of the window, the name at its left edge.
    final search = find.byKey(const ValueKey('title-bar-search'));
    expect((tester.getCenter(search).dx - 450).abs(), lessThan(2));
    expect(tester.getSize(search).height, 28, reason: 'a fixed height, not squashed to its content');
    expect(tester.getSize(search).width, 440);
    expect(tester.getTopLeft(find.byKey(const ValueKey('title-bar-name'))).dx, lessThan(30));

    UpdateService.available.value = const UpdateInfo(
      version: 'v9.9.9',
      releaseUrl: 'https://example.invalid',
      notes: '',
      assetName: null,
      assetUrl: null,
      assetSize: 0,
      checksumsUrl: null,
      method: null,
    );
    app.setSidebarWidth(AppState.minSidebarWidth);
    await tester.pump();
    expect(button, findsOneWidget);
    expect(tester.getTopRight(button).dx, lessThanOrEqualTo(AppState.minSidebarWidth));
    expect(tester.takeException(), isNull);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New connection'));
    await tester.pumpAndSettle();
    expect(find.text('CONNECTION'), findsOneWidget);
  });
}
