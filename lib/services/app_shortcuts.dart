import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What the window-wide keyboard shortcuts do.
enum AppCommand { palette, newConnection, nextTab, previousTab, closeTab, splitView, settings }

/// The window's own shortcuts.
///
/// Every one of them has Ctrl+Shift (or is Ctrl+Tab / Ctrl+,), because a
/// plain Ctrl key belongs to the session, as in PuTTY: Ctrl+A, Ctrl+K,
/// Ctrl+W and the rest are shell and editor keys. A terminal pane passes each
/// key here before it types it ([handle]), and the home screen does the same
/// for keys pressed anywhere else, so the shortcuts work wherever the focus is.
class AppShortcuts {
  AppShortcuts._();

  static const bindings = <AppCommand, SingleActivator>{
    AppCommand.palette: SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true),
    AppCommand.newConnection: SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true),
    AppCommand.nextTab: SingleActivator(LogicalKeyboardKey.tab, control: true),
    AppCommand.previousTab: SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
    AppCommand.closeTab: SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true),
    AppCommand.splitView: SingleActivator(LogicalKeyboardKey.keyD, control: true, shift: true),
    AppCommand.settings: SingleActivator(LogicalKeyboardKey.comma, control: true),
  };

  /// Runs a command. Set by the home screen while it is shown; null in a
  /// window without one (the SFTP window, tests of a single widget).
  static void Function(AppCommand command)? dispatcher;

  /// The command a key press stands for, if any.
  static AppCommand? match(KeyEvent event) {
    if (event is KeyUpEvent) return null;
    for (final entry in bindings.entries) {
      if (entry.value.accepts(event, HardwareKeyboard.instance)) return entry.key;
    }
    return null;
  }

  /// Runs the command [event] stands for. Handled only when there is one and
  /// something to run it, so every other key goes on to the session.
  static KeyEventResult handle(KeyEvent event) {
    final command = match(event);
    final run = dispatcher;
    if (command == null || run == null) return KeyEventResult.ignored;
    // A held key repeats; a repeated shortcut would open the same dialog
    // again on top of itself. Only tab switching repeats.
    if (event is KeyRepeatEvent && command != AppCommand.nextTab && command != AppCommand.previousTab) {
      return KeyEventResult.handled;
    }
    run(command);
    return KeyEventResult.handled;
  }

  /// The keys of a command as shown in hints: "Ctrl+Shift+P".
  static String label(AppCommand command) {
    final a = bindings[command]!;
    final key = switch (a.trigger) {
      LogicalKeyboardKey.tab => 'Tab',
      LogicalKeyboardKey.comma => ',',
      final k => k.keyLabel.toUpperCase(),
    };
    return [if (a.control) 'Ctrl', if (a.shift) 'Shift', if (a.alt) 'Alt', key].join('+');
  }
}
