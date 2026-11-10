import 'package:mesterm/models/models.dart';
import 'package:mesterm/providers/app_state.dart';
import 'package:mesterm/widgets/connection_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a folder row shows its name only, no item count; a connection shows its host', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await tester.pump();
    final folder = ConnectionFolder(name: 'CUSTOMER-A');
    app.folders.add(folder);
    app.connections.addAll([
      SavedConnection(name: 'DEVICE-01', host: '192.0.2.10', folderId: folder.id),
      SavedConnection(name: 'DEVICE-02', host: 'device-02.example.net', folderId: folder.id),
      SavedConnection(name: 'DEVICE-09', host: '192.0.2.19'),
    ]);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: app,
      child: const MaterialApp(home: Scaffold(body: SizedBox(width: 300, child: ConnectionTree()))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('CUSTOMER-A'), findsOneWidget);
    expect(find.text('2'), findsNothing, reason: 'folders no longer carry a count');
    expect(find.text('3'), findsOneWidget, reason: 'the list heading counts every connection');

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('192.0.2.10'), findsOneWidget);
    expect(find.text('device-02.example.net'), findsOneWidget);
  });
}
