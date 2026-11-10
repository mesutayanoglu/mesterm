import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import '../services/app_shortcuts.dart';

import '../widgets/command_palette.dart';
import '../widgets/connection_tree.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/new_connection_dialog.dart';
import '../widgets/quick_connect_bar.dart';
import '../widgets/split_view_dialog.dart';
import '../widgets/status_bar.dart';
import '../widgets/terminal_tabs.dart';
import '../widgets/update_dialog.dart';
import 'settings_screen.dart';
import '../l10n/strings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    AppShortcuts.dispatcher = _run;
  }

  @override
  void dispose() {
    if (AppShortcuts.dispatcher == _run) AppShortcuts.dispatcher = null;
    super.dispose();
  }

  /// Carries out a window shortcut or a palette command.
  void _run(AppCommand command) {
    if (!mounted) return;
    // Nothing runs behind an open dialog: a shortcut typed in one would
    // otherwise open a second dialog under it or switch tabs out of sight.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final app = context.read<AppState>();
    switch (command) {
      case AppCommand.palette:
        showCommandPalette(context, run: _run);
      case AppCommand.newConnection:
        showNewConnectionDialog(context);
      case AppCommand.nextTab:
        app.cycleTab(1);
      case AppCommand.previousTab:
        app.cycleTab(-1);
      case AppCommand.closeTab:
        if (app.activeTabIndex >= 0 && app.activeTabIndex < app.tabs.length) app.closeTab(app.activeTabIndex);
      case AppCommand.splitView:
        if (app.tabs.length >= 2) showSplitViewDialog(context);
      case AppCommand.settings:
        showSettings(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = context.select<AppState, double>((a) => a.sidebarWidth);
    // Keys pressed outside a terminal (in the tree, the filter box, on a
    // button) come here; a terminal pane passes them on itself.
    return Focus(
      onKeyEvent: (_, event) => AppShortcuts.handle(event),
      child: Scaffold(
        body: Column(
          children: [
            CustomTitleBar(
              center: _PaletteButton(onTap: () => _run(AppCommand.palette)),
              actions: [
                // Only appears once a newer release has been found.
                const UpdateButton(compact: true),
                const SizedBox(width: 6),
                _HeaderIcon(icon: Icons.settings_outlined, tooltip: tr('Settings'), onTap: () => showSettings(context)),
                const SizedBox(width: 6),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: width,
                    // The sidebar is a panel a step lighter than the window,
                    // as the terminal side is a step darker.
                    child: ColoredBox(
                      color: Theme.of(context).brightness == Brightness.dark ? AppColors.darkPanel : AppColors.lightPanel,
                      child: const Column(
                        children: [
                          Expanded(child: ConnectionTree()),
                          QuickConnectBar(),
                        ],
                      ),
                    ),
                  ),
                  const _SidebarResizer(),
                  // Sessions take whatever the panel leaves: terminals re-wrap
                  // and RDP sessions resize to the new pane.
                  const Expanded(child: TerminalTabsArea()),
                ],
              ),
            ),
            const StatusBar(),
          ],
        ),
      ),
    );
  }
}

/// Opens the command palette from the title bar, and says how to open it
/// from the keyboard.
class _PaletteButton extends StatelessWidget {
  const _PaletteButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dim = theme.textTheme.bodySmall?.color;
    // A fixed height: sized by its content, the box shrank to the height of
    // the key hint and looked squashed.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440, minWidth: 160),
      child: SizedBox(
        height: 28,
        child: Material(
          color: dark ? AppColors.darkPanel : AppColors.lightPanelAlt,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: theme.dividerColor),
          ),
          child: InkWell(
            key: const ValueKey('title-bar-search'),
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 6),
              child: Row(
                children: [
                  Icon(Icons.search, size: 14, color: dim),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('Search connections and commands'),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: TextStyle(fontSize: 12.5, color: dim),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // The keys as a quiet tag inside the box, not a second
                  // outlined box squeezed into it.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: dark ? AppColors.darkPanelAlt : AppColors.lightBorder,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      AppShortcuts.label(AppCommand.palette),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        fontFamily: 'Consolas',
                        fontFamilyFallback: const ['Menlo', 'monospace'],
                        color: dark ? const Color(0xFFB5B5B5) : const Color(0xFF3D3D3D),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The connections panel's right edge: drag to make it wider or narrower
/// (long names stop being cut off), double-click to go back to the default.
class _SidebarResizer extends StatefulWidget {
  const _SidebarResizer();

  @override
  State<_SidebarResizer> createState() => _SidebarResizerState();
}

class _SidebarResizerState extends State<_SidebarResizer> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => app.setSidebarWidth(app.sidebarWidth + d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          app.setSidebarWidth(app.sidebarWidth, save: true);
        },
        onDoubleTap: () => app.setSidebarWidth(AppState.defaultSidebarWidth, save: true),
        // A wider grip than the 1px line it draws, so it is easy to catch.
        child: SizedBox(
          width: 7,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 3 : 1,
              color: active ? theme.colorScheme.primary.withValues(alpha: 0.5) : theme.dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small fixed-size icon button that never claims Material's 48px tap
/// target — keeps the 32px header row from overflowing.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 15)),
      ),
    );
  }
}
