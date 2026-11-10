import 'package:mesterm/models/models.dart';
import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppState app;

  Future<void> pumpTree(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    app = AppState();
    await tester.pump();
    final alpha = ConnectionFolder(name: 'ALPHA');
    final sub = ConnectionFolder(name: 'SUB', parentId: alpha.id);
    app.folders.addAll([alpha, sub]);
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: alpha.id),
      SavedConnection(name: 'DEVICE-03', host: '192.0.2.13', folderId: sub.id),
      SavedConnection(name: 'DEVICE-09', host: '192.0.2.19'),
    ]);
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 300, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pumpAndSettle();
  }

  /// The row the keyboard is on, read from the rename dialog F2 opens.
  Future<String> cursor(WidgetTester tester) async {
    await key(tester, LogicalKeyboardKey.f2);
    final text = tester.widget<TextField>(find.byType(TextField).last).controller!.text;
    await key(tester, LogicalKeyboardKey.escape);
    return text;
  }

  testWidgets('arrows walk the tree; right opens a folder and steps in, left steps out and closes', (tester) async {
    await pumpTree(tester);
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(await cursor(tester), 'ALPHA');
    expect(find.text('DEVICE-01'), findsNothing);

    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('DEVICE-01'), findsOneWidget, reason: 'opened');
    expect(find.text('SUB'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowRight);
    expect(await cursor(tester), 'SUB', reason: 'stepped into the folder');

    await key(tester, LogicalKeyboardKey.enter);
    expect(find.text('DEVICE-03'), findsOneWidget, reason: 'Enter opens a folder');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(await cursor(tester), 'DEVICE-03');

    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(await cursor(tester), 'SUB', reason: 'out to its folder');
    await key(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.text('DEVICE-03'), findsNothing, reason: 'closed');
    await key(tester, LogicalKeyboardKey.end);
    expect(await cursor(tester), 'DEVICE-09');
    await key(tester, LogicalKeyboardKey.home);
    expect(await cursor(tester), 'ALPHA');
  });

  testWidgets('F2 renames the row; Delete asks first', (tester) async {
    await pumpTree(tester);
    await key(tester, LogicalKeyboardKey.end);
    await key(tester, LogicalKeyboardKey.f2);
    await tester.enterText(find.byType(TextField).last, 'DEVICE-10');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(app.connections.any((c) => c.name == 'DEVICE-10'), isTrue);

    await key(tester, LogicalKeyboardKey.delete);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    await key(tester, LogicalKeyboardKey.escape);
    expect(app.connections.any((c) => c.name == 'DEVICE-10'), isTrue, reason: 'nothing deleted without a yes');
  });

  testWidgets('/ goes to the filter; letters typed there stay text, Down goes back to the list', (tester) async {
    await pumpTree(tester);
    await app.setVimKeys(true);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '/');
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ, character: 'j');
    await tester.enterText(find.byType(TextField).first, 'dev');
    await tester.pumpAndSettle();
    expect(find.text('DEVICE-03'), findsOneWidget, reason: 'filtered across folders');
    await key(tester, LogicalKeyboardKey.arrowDown);
    expect(await cursor(tester), 'DEVICE-01');
    await key(tester, LogicalKeyboardKey.keyJ);
    expect(await cursor(tester), 'DEVICE-03', reason: 'j moves with the Vim option on');
    await key(tester, LogicalKeyboardKey.keyK);
    expect(await cursor(tester), 'DEVICE-01');
  });

  testWidgets('without the Vim option, j and k do nothing in the tree', (tester) async {
    await pumpTree(tester);
    await key(tester, LogicalKeyboardKey.arrowDown);
    await key(tester, LogicalKeyboardKey.keyJ);
    expect(await cursor(tester), 'ALPHA');
  });
}
