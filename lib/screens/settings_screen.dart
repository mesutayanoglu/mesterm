import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../providers/app_state.dart';
import '../services/app_shortcuts.dart';
import '../services/mcp_server.dart';
import '../services/terminal_appearance.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/custom_title_bar.dart';
import '../widgets/import_export_dialog.dart';
import '../widgets/status_bar.dart' show KeyCap;
import '../widgets/update_dialog.dart';
import '../l10n/strings.dart';

/// Opens the Settings page.
Future<void> showSettings(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
}

/// Everything that used to be scattered across four unlabelled icons in the
/// sidebar header -- theme, terminal colours, import, export -- plus checking
/// for updates, on one page with room to explain itself.
///
/// A full page rather than a dialog: it carries the app's own title bar, so
/// the window can still be moved and closed while it is open, and opening it
/// suspends any embedded RDP session the same way a dialog does (the session
/// is a window of its own, drawn above the app, and would otherwise cover it).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _keys = <String, GlobalKey>{};
  String? _current;

  GlobalKey _key(String section) => _keys.putIfAbsent(section, GlobalKey.new);

  void _goTo(String section) {
    setState(() => _current = section);
    final ctx = _keys[section]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    final hasMcpServer = context.watch<McpServer?>() != null;
    final sections = ['Appearance', 'Keyboard', 'Connections', if (hasMcpServer) 'MCP integration', 'Updates'];
    final current = _current ?? sections.first;
    Widget section(String title, List<Widget> children) =>
        KeyedSubtree(key: _key(title), child: _Section(title: title, children: children));
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section('Appearance', const [
          _Label('Theme'),
          _ThemePicker(),
          SizedBox(height: 28),
          _Label('SSH terminal'),
          _TerminalAppearance(),
          SizedBox(height: 28),
          _Label('Language'),
          _LanguagePicker(),
        ]),
        const SizedBox(height: 22),
        section('Keyboard', const [_KeyboardPanel()]),
        const SizedBox(height: 22),
        section('Connections', const [_ImportExport()]),
        const SizedBox(height: 22),
        if (hasMcpServer) ...[
          section('MCP integration', const [_McpPanel()]),
          const SizedBox(height: 22),
        ],
        section('Updates', const [_UpdatesPanel()]),
      ],
    );
    return Scaffold(
      body: Column(
        children: [
          const CustomTitleBar(),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: divider)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('Back'),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                Text(tr('Settings'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The section list needs room beside the page; on a narrow
                // window the page scrolls on its own.
                final wide = constraints.maxWidth >= 1040;
                final page = SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                  child: Center(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: content),
                  ),
                );
                if (!wide) return page;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionNav(sections: sections, current: current, onTap: _goTo),
                    Expanded(child: page),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The page's sections, down the left: a click scrolls to one.
class _SectionNav extends StatelessWidget {
  const _SectionNav({required this.sections, required this.current, required this.onTap});
  final List<String> sections;
  final String current;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dim = theme.textTheme.bodySmall?.color;
    return Container(
      key: const ValueKey('settings-nav'),
      width: 200,
      padding: const EdgeInsets.fromLTRB(12, 28, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in sections)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: s == current
                    ? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.10 : 0.06)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onTap(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      tr(s),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: s == current ? FontWeight.w600 : FontWeight.w400,
                        color: s == current ? null : dim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _McpPanel extends StatelessWidget {
  const _McpPanel();

  @override
  Widget build(BuildContext context) {
    final server = context.watch<McpServer>();
    final secondary = Theme.of(context).textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Allow MCP access')),
                  const SizedBox(height: 4),
                  Text(tr('Lets a connected agent open saved SSH connections, send commands, and read terminal output.'),
                      style: TextStyle(fontSize: 12, color: secondary)),
                ],
              ),
            ),
            Switch(
              value: server.enabled,
              onChanged: (value) async {
                if (value) {
                  await server.start();
                } else {
                  await server.stop();
                }
              },
            ),
          ],
        ),
        if (server.url case final url?) ...[
          const SizedBox(height: 12),
          Text(tr('MCP server URL'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText(url),
          const SizedBox(height: 8),
          Text(tr('Use this URL directly in ChatGPT Work desktop, or point a Secure MCP Tunnel at it for hosted ChatGPT Work. Keep the URL private.'),
              style: TextStyle(fontSize: 12, color: secondary)),
        ],
        if (server.enabled) ...[
          const SizedBox(height: 16),
          Text(tr('Allowed connections'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            tr('Right-click a connection in the list to allow it. The agent sees only the anonymous name. Every command asks you first. Terminal output is sent as it is, so it can still show device names and addresses.'),
            style: TextStyle(fontSize: 12, color: secondary),
          ),
          const SizedBox(height: 8),
          if (server.gateway case final AppMcpGateway gateway)
            ListenableBuilder(
              listenable: gateway,
              builder: (context, _) {
                final allowed = gateway.allowedConnections.toList();
                if (allowed.isEmpty) {
                  return Text(tr('None yet.'), style: TextStyle(fontSize: 12, color: secondary));
                }
                return Column(
                  children: [
                    for (final c in allowed)
                      Row(
                        children: [
                          Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                          Text(gateway.aliasOf(c.id)!, style: TextStyle(fontSize: 12, color: secondary)),
                          IconButton(
                            tooltip: tr('Remove access'),
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () => gateway.setAllowed(c.id, false),
                          ),
                        ],
                      ),
                  ],
                );
              },
            ),
        ],
        if (server.error case final error?) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Layout pieces
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr(title), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        tr(text),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Language
// ---------------------------------------------------------------------------

/// The app's own wording only: what remote machines print is never touched.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<AppLanguage>(
          showSelectedIcon: false,
          segments: [for (final l in AppLanguage.values) ButtonSegment(value: l, label: Text(l.label))],
          selected: {app.language},
          onSelectionChanged: (s) => app.setLanguage(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          tr('Applies to MesTerm itself; sessions are not affected.'),
          style: TextStyle(fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

class _ThemePicker extends StatelessWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: [
        _ThemeCard(
          label: 'Light',
          light: true,
          selected: app.themeMode == ThemeMode.light,
          onTap: () => app.setThemeMode(ThemeMode.light),
        ),
        _ThemeCard(
          label: 'Dark',
          light: false,
          selected: app.themeMode == ThemeMode.dark,
          onTap: () => app.setThemeMode(ThemeMode.dark),
        ),
      ],
    );
  }
}

/// A miniature of the app in one theme -- title bar, sidebar, content -- so
/// the choice is made by looking rather than by reading a word.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.label, required this.light, required this.selected, required this.onTap});

  final String label;
  final bool light;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final bg = light ? AppColors.lightBg : AppColors.darkBg;
    final panel = light ? AppColors.lightPanelAlt : AppColors.darkPanelAlt;
    final line = light ? AppColors.lightBorder : AppColors.darkBorder;
    final ink = light ? AppColors.lightText : AppColors.darkText;

    Widget bar(double width) => Container(
      width: width,
      height: 5,
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2)),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 220,
              height: 132,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? accent : Theme.of(context).dividerColor,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(height: 14, color: panel),
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 66,
                          color: panel,
                          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [bar(44), bar(36), bar(48), bar(30), bar(40)],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 60,
                                  height: 7,
                                  margin: const EdgeInsets.only(bottom: 9),
                                  decoration: BoxDecoration(
                                    color: ink,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                bar(100),
                                bar(84),
                                bar(92),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? accent : Theme.of(context).textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 6),
                Text(tr(label), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Terminal colours
// ---------------------------------------------------------------------------

/// Ready-made pairs of terminal colours, shown as small terminals.
class _Scheme {
  const _Scheme(this.name, this.background, this.foreground);
  final String name;
  final Color background;
  final Color foreground;
}

const _schemes = [
  _Scheme('MesTerm', Color(0xFF14161A), Color(0xFFE8E6E1)),
  _Scheme('Black', Color(0xFF000000), Color(0xFFFFFFFF)),
  _Scheme('Graphite', Color(0xFF1E1E1E), Color(0xFFD4D4D4)),
  _Scheme('Solarized Dark', Color(0xFF002B36), Color(0xFF839496)),
  _Scheme('Solarized Light', Color(0xFFFDF6E3), Color(0xFF586E75)),
  _Scheme('Paper', Color(0xFFFFFFFF), Color(0xFF1A1A1A)),
  _Scheme('Green phosphor', Color(0xFF0A0F0A), Color(0xFF33FF66)),
  _Scheme('Amber', Color(0xFF120D05), Color(0xFFFFB000)),
];

/// WCAG contrast ratio of two opaque colours, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

class _TerminalAppearance extends StatefulWidget {
  const _TerminalAppearance();

  @override
  State<_TerminalAppearance> createState() => _TerminalAppearanceState();
}

class _TerminalAppearanceState extends State<_TerminalAppearance> {
  List<String> _fonts = [defaultTerminalFont];

  @override
  void initState() {
    super.initState();
    installedTerminalFonts().then((fonts) {
      if (mounted) setState(() => _fonts = fonts);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final bg = app.terminalBackground;
    final fg = app.terminalForeground;
    final family = app.terminalFontFamily ?? defaultTerminalFont;
    final size = app.terminalFontSize;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A real terminal's worth of text in the chosen font, size and
        // colours, so the choice is judged on what a session will look like.
        Container(
          key: const ValueKey('terminal-preview'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Text(
            'admin@core-sw1:~\$ show ip interface brief\n'
            'Interface        IP-Address      Status   Protocol\n'
            'Vlan10           192.0.2.1       up       up\n'
            'Gi1/0/1          unassigned      up       up\n'
            'Türkçe: çağrı şişe ığdır öğün İstanbul',
            style: TextStyle(
              color: fg,
              fontFamily: family,
              fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
              fontSize: size,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SettingRow(
          label: 'Font',
          child: _FontField(
            family: family,
            fonts: _fonts,
            onPick: (f) => app.setTerminalFont(
              family: f == defaultTerminalFont ? null : f,
              resetFamily: f == defaultTerminalFont,
            ),
          ),
        ),
        _SettingRow(
          label: 'Size',
          child: _SizeStepper(
            value: size.round(),
            min: 9,
            max: 24,
            onChanged: (v) => app.setTerminalFont(size: v.toDouble()),
          ),
        ),
        _SettingRow(
          label: 'Color scheme',
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in _schemes)
                _SchemeCard(
                  scheme: s,
                  selected: s.background.toARGB32() == bg.toARGB32() && s.foreground.toARGB32() == fg.toARGB32(),
                  onTap: () => app.setTerminalColors(background: s.background, foreground: s.foreground),
                ),
            ],
          ),
        ),
        _SettingRow(
          label: 'Background',
          child: _ColorCodeField(color: bg, onChanged: (c) => app.setTerminalColors(background: c)),
        ),
        _SettingRow(
          label: 'Text',
          child: _ColorCodeField(color: fg, onChanged: (c) => app.setTerminalColors(foreground: c)),
        ),
        _SettingRow(label: 'Readability', last: true, child: _ContrastNote(background: bg, foreground: fg)),
      ],
    );
  }
}

/// One setting: its name on the left, the control on the right, rows ruled
/// off from each other. On a narrow page the name goes above.
class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.child, this.last = false});
  final String label;
  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = Text(tr(label), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [name, const SizedBox(height: 8), child],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 150, child: Padding(padding: const EdgeInsets.only(top: 8), child: name)),
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
                ],
              ),
      ),
    );
  }
}

/// A colour scheme drawn as a tiny terminal in its own colours.
class _SchemeCard extends StatelessWidget {
  const _SchemeCard({required this.scheme, required this.selected, required this.onTap});
  final _Scheme scheme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Tooltip(
      message: tr(scheme.name),
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        selected: selected,
        label: tr(scheme.name),
        child: InkWell(
          key: ValueKey('scheme-${scheme.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 112,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? accent : theme.dividerColor, width: selected ? 2 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 46,
                  padding: const EdgeInsets.fromLTRB(8, 7, 8, 0),
                  decoration: BoxDecoration(color: scheme.background, borderRadius: BorderRadius.circular(5)),
                  child: Text(
                    '\$ ls -la\nup  up',
                    style: TextStyle(
                      color: scheme.foreground,
                      fontFamily: defaultTerminalFont,
                      fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr(scheme.name),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
                        ),
                      ),
                      if (selected) Icon(Icons.check, size: 14, color: accent),
                    ],
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

/// How readable the text is on the background, from the contrast ratio.
class _ContrastNote extends StatelessWidget {
  const _ContrastNote({required this.background, required this.foreground});
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final ratio = contrastRatio(background, foreground);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (String verdict, Color color) = ratio >= 7
        ? ('Very readable', dark ? const Color(0xFF6BD68F) : const Color(0xFF1E7A3D))
        : ratio >= 4.5
        ? ('Readable', dark ? const Color(0xFF6BD68F) : const Color(0xFF1E7A3D))
        : ('Hard to read', dark ? const Color(0xFFFF8A8E) : const Color(0xFFC62828));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Text(
            tr('Contrast {ratio}:1', {'ratio': ratio.toStringAsFixed(1)}),
            key: const ValueKey('contrast-ratio'),
            style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(width: 10),
          Text(tr(verdict), style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// The font size as a number with a step down and a step up.
class _SizeStepper extends StatelessWidget {
  const _SizeStepper({required this.value, required this.min, required this.max, required this.onChanged});
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(IconData icon, String tip, int to, Key key) => SizedBox(
      width: 34,
      height: 34,
      child: IconButton(
        key: key,
        tooltip: tr(tip),
        padding: EdgeInsets.zero,
        iconSize: 16,
        onPressed: to < min || to > max ? null : () => onChanged(to),
        icon: Icon(icon),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(kControlRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(Icons.remove, 'Smaller', value - 1, const ValueKey('font-size-down')),
          Container(
            width: 64,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.symmetric(vertical: BorderSide(color: theme.dividerColor)),
            ),
            child: Text(
              tr('{n} pt', {'n': value}),
              key: const ValueKey('font-size'),
              style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          step(Icons.add, 'Larger', value + 1, const ValueKey('font-size-up')),
        ],
      ),
    );
  }
}

/// The terminal font: a field showing the current one in its own face, which
/// opens a searchable list of the installed fixed-width fonts.
class _FontField extends StatelessWidget {
  const _FontField({required this.family, required this.fonts, required this.onPick});
  final String family;
  final List<String> fonts;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 320,
      child: Material(
        color: theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kControlRadius),
          side: BorderSide(color: theme.dividerColor),
        ),
        child: InkWell(
          key: const ValueKey('font-field'),
          borderRadius: BorderRadius.circular(kControlRadius),
          onTap: () async {
            final picked = await showDialog<String>(
              context: context,
              builder: (_) => _FontPickerDialog(fonts: fonts, current: family),
            );
            if (picked != null) onPick(picked);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    family == defaultTerminalFont ? tr('{font} (default)', {'font': family}) : family,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: family,
                      fontFamilyFallback: const ['Consolas', 'Menlo'],
                      fontSize: 13,
                    ),
                  ),
                ),
                Icon(Icons.unfold_more, size: 16, color: theme.textTheme.bodySmall?.color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FontPickerDialog extends StatefulWidget {
  const _FontPickerDialog({required this.fonts, required this.current});
  final List<String> fonts;
  final String current;

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    final q = _query.text.trim();
    final shown = widget.fonts.where((f) => f.toLowerCase().contains(q.toLowerCase())).toList();
    // A font typed by name that is not in the list (not detected, or not
    // fixed-width) can still be used.
    final typed = q.isNotEmpty && !widget.fonts.any((f) => f.toLowerCase() == q.toLowerCase());
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        key: const ValueKey('font-picker'),
        width: 480,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Text(tr('Terminal font'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                key: const ValueKey('font-search'),
                controller: _query,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) {
                  if (shown.length == 1) {
                    Navigator.of(context).pop(shown.single);
                  } else if (typed) {
                    Navigator.of(context).pop(v.trim());
                  }
                },
                decoration: InputDecoration(
                  isDense: true,
                  hintText: tr('Search installed fonts, or type a font name'),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                children: [
                  if (typed)
                    _FontRow(
                      name: q,
                      label: tr('Use "{font}"', {'font': q}),
                      selected: false,
                      onTap: () => Navigator.of(context).pop(q),
                    ),
                  for (final f in shown)
                    _FontRow(
                      name: f,
                      label: f == defaultTerminalFont ? tr('{font} (default)', {'font': f}) : f,
                      selected: f == widget.current,
                      onTap: () => Navigator.of(context).pop(f),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 8, 12, 10),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.dividerColor))),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('A font that is not installed falls back to the default.'),
                      style: TextStyle(fontSize: 12, color: dim),
                    ),
                  ),
                  TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancel'))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A font in the list: its name, and a sample in the font itself.
class _FontRow extends StatelessWidget {
  const _FontRow({required this.name, required this.label, required this.selected, required this.onTap});
  final String name;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Material(
      color: selected ? (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.10 : 0.06) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text(
                      'admin@sw1# show run  0O 1lI {}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: name,
                        fontFamilyFallback: const ['Consolas', 'Menlo'],
                        fontSize: 13,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A colour: its swatch, its code (`#1E1E1E`, `#FFF`, `rgb(30, 30, 30)` or
/// `30,30,30`, applied as soon as it parses) and the full palette.
class _ColorCodeField extends StatefulWidget {
  const _ColorCodeField({required this.color, required this.onChanged});
  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<_ColorCodeField> createState() => _ColorCodeFieldState();
}

class _ColorCodeFieldState extends State<_ColorCodeField> {
  late final _text = TextEditingController(text: colorToHex(widget.color));
  final _focus = FocusNode();
  bool _invalid = false;

  @override
  void didUpdateWidget(_ColorCodeField old) {
    super.didUpdateWidget(old);
    // A scheme or the palette changed it: show its code, unless the user is
    // mid-typing.
    if (old.color != widget.color && !_focus.hasFocus) {
      _text.text = colorToHex(widget.color);
      _invalid = false;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _apply(String v) {
    final c = parseColorCode(v);
    setState(() => _invalid = c == null && v.trim().isNotEmpty);
    if (c != null) widget.onChanged(c);
  }

  Future<void> _palette() async {
    final c = await showColorPicker(context, initial: widget.color, title: 'Pick a color');
    if (c != null) widget.onChanged(c);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: tr('Pick a color'),
          child: InkWell(
            onTap: _palette,
            borderRadius: BorderRadius.circular(kControlRadius),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(kControlRadius),
                border: Border.all(color: theme.dividerColor),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 200,
          child: TextField(
            controller: _text,
            focusNode: _focus,
            onChanged: _apply,
            onSubmitted: _apply,
            style: TextStyle(fontSize: 13, fontFamily: defaultTerminalFont, fontFamilyFallback: const ['Consolas', 'Menlo']),
            decoration: InputDecoration(
              isDense: true,
              labelText: tr('Color code'),
              hintText: tr('#1E1E1E or rgb(30, 30, 30)'),
              errorText: _invalid ? tr('Use #RRGGBB, #RGB or rgb(r, g, b)') : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: tr('Pick a color'),
          onPressed: _palette,
          iconSize: 16,
          icon: const Icon(Icons.colorize),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

/// The window's shortcuts and the tree's keys, and the Vim option.
class _KeyboardPanel extends StatelessWidget {
  const _KeyboardPanel();

  static const _window = <AppCommand, String>{
    AppCommand.palette: 'Command palette',
    AppCommand.newConnection: 'New connection',
    AppCommand.nextTab: 'Next tab',
    AppCommand.previousTab: 'Previous tab',
    AppCommand.closeTab: 'Close tab',
    AppCommand.splitView: 'Split view',
    AppCommand.settings: 'Open settings',
  };

  static const _tree = <(String, String)>[
    ('↑ ↓', 'Move'),
    ('→ ←', 'Open or close a folder'),
    ('Enter', 'Connect, or open a folder'),
    ('F2', 'Rename'),
    ('Delete', 'Delete'),
    ('/', 'Filter connections'),
  ];

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dim = Theme.of(context).textTheme.bodySmall?.color;
    Widget line(String keys, String what) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 150, child: Align(alignment: Alignment.centerLeft, child: KeyCap(keys))),
          Expanded(child: Text(tr(what), style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('Vim keys in the connection tree'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr(
                      'j and k move, h and l close and open folders, g and G jump to the top and bottom. Never inside a terminal.',
                    ),
                    style: TextStyle(fontSize: 12, color: dim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(key: const ValueKey('vim-keys'), value: app.vimKeys, onChanged: app.setVimKeys),
          ],
        ),
        const SizedBox(height: 22),
        const _Label('Window'),
        for (final e in _window.entries) line(AppShortcuts.label(e.key), e.value),
        const SizedBox(height: 18),
        const _Label('Connection tree'),
        for (final (keys, what) in _tree) line(keys, what),
        const SizedBox(height: 10),
        Text(
          tr('Every other key, plain Ctrl ones included, goes to the session, as in PuTTY.'),
          style: TextStyle(fontSize: 12, color: dim),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Import / export
// ---------------------------------------------------------------------------

class _ImportExport extends StatelessWidget {
  const _ImportExport();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = constraints.maxWidth >= 560
            ? (constraints.maxWidth - 14) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            SizedBox(
              width: tileWidth,
              child: _ActionTile(
                icon: Icons.file_download_outlined,
                title: 'Import connections',
                description: 'From an export file (JSON, XML or CSV).',
                action: 'Import…',
                onPressed: () => showImportDialog(context),
              ),
            ),
            SizedBox(
              width: tileWidth,
              child: _ActionTile(
                icon: Icons.file_upload_outlined,
                title: 'Export connections',
                description: 'Save some or all of your connections as JSON, XML or CSV.',
                action: 'Export…',
                onPressed: () => showExportDialog(context),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 10),
              Flexible(
                child: Text(tr(title), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            tr(description),
            style: TextStyle(fontSize: 12, height: 1.45, color: theme.textTheme.bodySmall?.color),
          ),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onPressed, child: Text(tr(action))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Updates
// ---------------------------------------------------------------------------

enum _Phase { idle, checking, upToDate, available, installing, failed }

/// "Check for updates", answered on the page itself rather than in a popup.
///
/// Separate from the prompt shown at launch, which stays: that one comes to
/// the user; this is for the user who comes looking.
class _UpdatesPanel extends StatefulWidget {
  const _UpdatesPanel();

  @override
  State<_UpdatesPanel> createState() => _UpdatesPanelState();
}

class _UpdatesPanelState extends State<_UpdatesPanel> {
  _Phase _phase = _Phase.idle;
  UpdateInfo? _info;
  double? _progress;
  String? _error;
  bool _installFailed = false;

  @override
  void initState() {
    super.initState();
    // Already found at launch: say so straight away instead of making the
    // user press a button to learn what the app already knows.
    final known = UpdateService.available.value;
    if (known != null) {
      _info = known;
      _phase = _Phase.available;
    }
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _installFailed = false;
    });
    final result = await UpdateService.checkNow();
    if (!mounted) return;
    setState(() {
      if (result.failed) {
        _phase = _Phase.failed;
        _error = tr(
          'Could not reach GitHub to check for updates. Check the internet connection and try again.',
        );
      } else if (result.info == null) {
        _phase = _Phase.upToDate;
      } else {
        _info = result.info;
        UpdateService.available.value = result.info;
        _phase = _Phase.available;
      }
    });
  }

  Future<void> _chooseChannel(ReleaseChannel channel) async {
    await context.read<AppState>().setUpdateChannel(channel);
    UpdateService.available.value = null;
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _info = null;
    });
  }

  Future<void> _install() async {
    final info = _info;
    if (info == null) return;
    setState(() {
      _phase = _Phase.installing;
      _progress = 0;
      _error = null;
    });
    final error = await installUpdate(
      info,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _installFailed = true;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    final busy = _phase == _Phase.checking || _phase == _Phase.installing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Receive beta updates')),
                  const SizedBox(height: 4),
                  Text(
                    tr('Betas are offered too, as they come out. A beta replaces this version, with the same connections and settings, and may have bugs.'),
                    style: TextStyle(fontSize: 12, color: dim),
                  ),
                ],
              ),
            ),
            Switch(
              key: const ValueKey('beta-updates'),
              value: context.watch<AppState>().updateChannel == ReleaseChannel.beta,
              onChanged: (on) => _chooseChannel(on ? ReleaseChannel.beta : ReleaseChannel.stable),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$appName $appVersion',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(tr('Installed version'), style: TextStyle(fontSize: 12, color: dim)),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _check,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(tr('Check for updates')),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          alignment: Alignment.topCenter,
          child: _status(context),
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.color;
    switch (_phase) {
      case _Phase.idle:
        return const SizedBox(width: double.infinity);
      case _Phase.checking:
        return _StatusBox(
          child: Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text(tr('Checking for updates…'), style: TextStyle(color: dim)),
            ],
          ),
        );
      case _Phase.upToDate:
        return _StatusBox(
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr("You're up to date — {version} is the latest version.", {'version': appVersion}),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        );
      case _Phase.available:
        final info = _info!;
        final notes = info.plainNotes;
        return _StatusBox(
          emphasised: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.new_releases_outlined, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tr(info.channel == ReleaseChannel.beta
                          ? 'MesTerm Beta {version} is available'
                          : 'MesTerm {version} is available', {'version': info.version}),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (info.sizeLabel.isNotEmpty)
                    Text(info.sizeLabel, style: TextStyle(fontSize: 12, color: dim)),
                ],
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(notes, style: const TextStyle(fontSize: 12, height: 1.5)),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                tr('Update to {version} now?', {'version': info.version}),
                style: TextStyle(fontSize: 12, color: dim),
              ),
              const SizedBox(height: 10),
              if (info.canSelfInstall)
                ElevatedButton.icon(
                  onPressed: _install,
                  icon: const Icon(Icons.system_update_alt, size: 16),
                  label: Text(tr('Yes, update')),
                )
              else
                // Only when the release itself is missing this platform's
                // build; every copy that has a build to use updates in place.
                OutlinedButton(
                  onPressed: () => UpdateService.openReleasePage(info),
                  child: Text(tr('Open download page')),
                ),
            ],
          ),
        );
      case _Phase.installing:
        final p = _progress;
        return _StatusBox(
          emphasised: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                p == null
                    ? tr('Downloading {version}…', {'version': _info?.version ?? tr('the update')})
                    : tr('Downloading {version}… {percent}%', {
                        'version': _info?.version ?? tr('the update'),
                        'percent': (p * 100).toStringAsFixed(0),
                      }),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: p),
              const SizedBox(height: 10),
              Text(
                tr('MesTerm will close and reopen on the new version by itself.'),
                style: TextStyle(fontSize: 12, color: dim),
              ),
            ],
          ),
        );
      case _Phase.failed:
        return _StatusBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_error ?? tr('Something went wrong.'), style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton(onPressed: _installFailed ? _install : _check, child: Text(tr('Try again'))),
                  // The last resort, and only after an update has actually
                  // failed: the normal path never sends anyone to a web page.
                  if (_installFailed && _info != null)
                    TextButton(
                      onPressed: () => UpdateService.openReleasePage(_info!),
                      child: Text(tr('Open download page')),
                    ),
                ],
              ),
            ],
          ),
        );
    }
  }
}

class _StatusBox extends StatelessWidget {
  const _StatusBox({required this.child, this.emphasised = false});
  final Widget child;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: emphasised ? theme.colorScheme.primary.withValues(alpha: 0.06) : null,
        border: Border.all(
          color: emphasised ? theme.colorScheme.primary.withValues(alpha: 0.5) : theme.dividerColor,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}
