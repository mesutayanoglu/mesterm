import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/models.dart';
import '../providers/app_state.dart';
import '../services/app_shortcuts.dart';
import '../theme/app_theme.dart';
import 'device_icon.dart';
import 'status_bar.dart';

/// Opens the command palette: one box to find a connection and open it, or
/// run a command, from the keyboard. [run] carries out a command (the home
/// screen's dispatcher), after the palette has closed.
Future<void> showCommandPalette(BuildContext context, {required void Function(AppCommand) run}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => CommandPalette(run: run),
  );
}

/// One line of the palette's list.
class _Entry {
  _Entry.connection(this.connection) : command = null;
  _Entry.command(this.command) : connection = null;
  final SavedConnection? connection;
  final AppCommand? command;
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, required this.run});
  final void Function(AppCommand) run;

  /// Commands offered, in the order shown, with their names.
  static const commands = <AppCommand, String>{
    AppCommand.newConnection: 'New connection',
    AppCommand.splitView: 'Split view',
    AppCommand.nextTab: 'Next tab',
    AppCommand.previousTab: 'Previous tab',
    AppCommand.closeTab: 'Close tab',
    AppCommand.settings: 'Settings',
  };

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static const _maxConnections = 8;
  static const _rowHeight = 36.0;

  List<_Entry> _entries(AppState app) {
    final q = _query.text.trim().toLowerCase();
    bool hit(String s) => s.toLowerCase().contains(q);
    final conns = app.connections
        .where((c) => q.isEmpty || hit(c.name) || hit(c.host))
        .take(q.isEmpty ? 5 : _maxConnections)
        .map(_Entry.connection);
    final cmds = CommandPalette.commands.entries
        .where((e) => q.isEmpty || hit(tr(e.value)) || hit(e.value))
        .map((e) => _Entry.command(e.key));
    return [...conns, ...cmds];
  }

  void _open(_Entry e) {
    final app = context.read<AppState>();
    Navigator.of(context).pop();
    if (e.connection != null) {
      app.openConnection(e.connection!);
    } else {
      widget.run(e.command!);
    }
  }

  void _move(int by, int length) {
    if (length == 0) return;
    setState(() => _selected = (_selected + by).clamp(0, length - 1));
    // Keep the selected line in view.
    if (_scroll.hasClients) {
      final top = _selected * _rowHeight;
      final view = _scroll.position.viewportDimension;
      if (top < _scroll.offset) {
        _scroll.jumpTo(top);
      } else if (top + _rowHeight > _scroll.offset + view) {
        _scroll.jumpTo(top + _rowHeight - view);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dim = dark ? AppColors.darkTextDim : AppColors.lightTextDim;
    final entries = _entries(app);
    if (_selected >= entries.length) _selected = entries.isEmpty ? 0 : entries.length - 1;
    final selectedFill = (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.10 : 0.07);
    final openIds = app.tabs.map((t) => t.connectionId).toSet();

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 72),
        child: Material(
          color: dark ? AppColors.darkPanel : AppColors.lightPanel,
          elevation: 12,
          shadowColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: dark ? const Color(0xFF3A3A3A) : AppColors.lightBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            key: const ValueKey('command-palette'),
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Focus(
                  // Arrows and Enter steer the list while the box keeps the
                  // typing; Escape closes the dialog on its own.
                  onKeyEvent: (_, event) {
                    if (event is KeyUpEvent) return KeyEventResult.ignored;
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown) {
                      _move(1, entries.length);
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.arrowUp) {
                      _move(-1, entries.length);
                      return KeyEventResult.handled;
                    }
                    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) &&
                        entries.isNotEmpty) {
                      _open(entries[_selected]);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Container(
                    height: 46,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor))),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 16, color: dim),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            key: const ValueKey('command-palette-query'),
                            controller: _query,
                            autofocus: true,
                            onChanged: (_) => setState(() => _selected = 0),
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              hintText: tr('Search connections and commands'),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: _rowHeight * 10 + 12),
                  child: entries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          child: Text(tr('Nothing matches.'), textAlign: TextAlign.center, style: TextStyle(color: dim)),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(6),
                          itemExtent: _rowHeight,
                          itemCount: entries.length,
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            final conn = e.connection;
                            final kind = conn == null ? null : DeviceIcon.of(conn);
                            return Material(
                              color: i == _selected ? selectedFill : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () => _open(e),
                                onHover: (h) {
                                  if (h && _selected != i) setState(() => _selected = i);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 18,
                                        child: conn == null
                                            ? Icon(Icons.chevron_right, size: 16, color: dim)
                                            : kind != null
                                            ? DeviceIcon(kind)
                                            : Icon(
                                                conn.protocol == ConnectionProtocol.rdp
                                                    ? Icons.desktop_windows_outlined
                                                    : Icons.terminal,
                                                size: 14,
                                                color: dim,
                                              ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          conn?.name ?? tr(CommandPalette.commands[e.command]!),
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                      if (conn != null) ...[
                                        if (openIds.contains(conn.id))
                                          Padding(
                                            padding: const EdgeInsets.only(right: 8),
                                            child: Text(tr('open'), style: TextStyle(fontSize: 12, color: dim)),
                                          ),
                                        Text(conn.host, style: TextStyle(fontSize: 12, color: dim)),
                                      ] else
                                        KeyCap(AppShortcuts.label(e.command!)),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(fontSize: 11.5, color: dim),
                    child: Row(
                      children: [
                        Text(tr('↑ ↓ to choose')),
                        const SizedBox(width: 16),
                        Text(tr('Enter to open')),
                        const SizedBox(width: 16),
                        Text(tr('Esc to close')),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
