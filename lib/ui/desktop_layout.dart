import 'package:flutter/widgets.dart';

import '../platform/device.dart';

/// When ShareBro uses its desktop layout (a sidebar instead of the bottom
/// dock, toolbars instead of floating buttons, side panels instead of
/// pull-up sheets). Phones never do. See design/desktop_layout_demo.html.
abstract final class DesktopLayout {
  /// The sidebar with labels; below [wideFrom] it folds into an icon rail.
  static const sidebarWidth = 252.0;
  static const railWidth = 68.0;

  /// Window width from which the sidebar shows labels, and side panels
  /// (the viewer's info) fit beside the content.
  static const wideFrom = 1000.0;

  /// Content wider than this is split into columns (Share) or capped.
  static const twoColumnsFrom = 820.0;

  /// The desktop layout is on (Windows, Mac, Linux).
  static bool get on => Device.desktop;

  /// On, and the window is wide enough for labels and side panels.
  static bool wide(BuildContext context) => on && MediaQuery.sizeOf(context).width >= wideFrom;
}
