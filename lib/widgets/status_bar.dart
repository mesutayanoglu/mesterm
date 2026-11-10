import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/mac_rdp_session.dart';
import '../services/pty_session.dart';
import '../services/rdp_session.dart';
import '../services/serial_session.dart';
import '../services/session_controller.dart';
import '../theme/app_theme.dart';

const double kStatusBarHeight = 26;

/// The colour of a session state, the same everywhere it is shown.
Color sessionStatusColor(SessionStatus status) => switch (status) {
  SessionStatus.running => const Color(0xFF2EB85C),
  SessionStatus.starting => const Color(0xFFE0A526),
  SessionStatus.error || SessionStatus.closed => const Color(0xFFE5484D),
};

/// The bottom line of the window: the active session's state, where it is
/// connected and how.
///
/// It watches only the active tab's state stream; session output does not
/// rebuild it.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.select<AppState, SessionController?>((a) {
      final i = a.activeTabIndex;
      return i >= 0 && i < a.tabs.length ? a.tabs[i].controller : null;
    });
    final count = context.select<AppState, int>((a) => a.tabs.length);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dim = dark ? AppColors.darkTextDim : AppColors.lightTextDim;
    return Container(
      key: const ValueKey('status-bar'),
      height: kStatusBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: dark ? AppColors.darkPanel : AppColors.lightPanel,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontSize: 12, color: dark ? const Color(0xFFB5B5B5) : const Color(0xFF3D3D3D)),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(
                child: controller == null
                    ? Text(
                        count == 0 ? tr('No open sessions') : '',
                        style: TextStyle(color: dim),
                        overflow: TextOverflow.ellipsis,
                      )
                    : _SessionSummary(key: ObjectKey(controller), controller: controller),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionSummary extends StatefulWidget {
  const _SessionSummary({super.key, required this.controller});
  final SessionController controller;

  @override
  State<_SessionSummary> createState() => _SessionSummaryState();
}

class _SessionSummaryState extends State<_SessionSummary> {
  StreamSubscription<SessionStatus>? _status;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _status = widget.controller.statusStream.listen((_) => _changed());
  }

  @override
  void dispose() {
    _status?.cancel();
    super.dispose();
  }

  String _label(SessionStatus s) => switch (s) {
    SessionStatus.running => tr('Connected'),
    SessionStatus.starting => tr('Connecting'),
    SessionStatus.closed => tr('Disconnected'),
    SessionStatus.error => tr('Failed'),
  };

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dim = dark ? AppColors.darkTextDim : AppColors.lightTextDim;
    String target;
    final meta = <String>[];
    if (c is PtySessionController) {
      target = '${c.username.isEmpty ? '' : '${c.username}@'}${c.host}:${c.port}';
      meta.add('SSH');
    } else if (c is SerialSessionController) {
      target = c.port;
      meta.add(tr('Serial'));
      meta.add('${c.baud} 8N1');
    } else if (c is RdpSessionController) {
      target = '${c.host}:${c.conn.port}';
      meta.add('RDP');
    } else if (c is MacRdpSessionController) {
      target = '${c.host}:${c.conn.port}';
      meta.add('RDP');
    } else {
      target = c.host;
    }
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: sessionStatusColor(c.status), shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(_label(c.status), key: const ValueKey('status-bar-state')),
        const SizedBox(width: 14),
        Flexible(
          child: Text(
            target,
            key: const ValueKey('status-bar-target'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['Menlo', 'monospace'], fontSize: 11.5),
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Text(meta.join(' · '), overflow: TextOverflow.ellipsis, style: TextStyle(color: dim)),
        ),
      ],
    );
  }
}

/// A key or key combination drawn as a small outlined cap.
class KeyCap extends StatelessWidget {
  const KeyCap(this.keys, {super.key});
  final String keys;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        keys,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontFamilyFallback: const ['Menlo', 'monospace'],
          fontSize: 11,
          height: 1.3,
          color: dark ? const Color(0xFFD9D9D9) : const Color(0xFF2A2A2A),
        ),
      ),
    );
  }
}
