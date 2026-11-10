import 'package:flutter/material.dart';

/// The MesTerm mark: a terminal prompt and "M_" in cyan to green on a dark
/// rounded tile, matching the window/taskbar icon.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/icon/mesterm_mark.png', width: size, height: size);
  }
}
