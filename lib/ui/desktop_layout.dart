import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../platform/device.dart';

/// Two-finger swipes on a touchpad go back (right) and forward (left), as
/// in Chrome. A view that uses sideways two-finger swipes itself (the photo
/// viewer, the spatial People views) claims the gesture when it starts.
abstract final class NavSwipe {
  static bool _claimed = false;

  /// Call from a Listener's onPointerPanZoomStart below the window's.
  static void claim() => _claimed = true;

  /// Whether this gesture was claimed (and forget it for the next one).
  static bool take() {
    final c = _claimed;
    _claimed = false;
    return c;
  }
}

/// When ShareBro uses its desktop layout (a sidebar instead of the bottom
/// dock, toolbars instead of floating buttons, side panels instead of
/// pull-up sheets). Phones never do. See design/desktop_layout_demo.html.
abstract final class DesktopLayout {
  /// The sidebar with labels; below [wideFrom] it folds into an icon rail.
  static const sidebarWidth = 236.0;
  static const railWidth = 60.0;

  /// Window width from which the sidebar shows labels, and side panels
  /// (the viewer's info) fit beside the content.
  static const wideFrom = 1000.0;

  /// Content wider than this is split into columns (Share) or capped.
  static const twoColumnsFrom = 820.0;

  /// The desktop layout is on (Windows, Mac, Linux).
  static bool get on => Device.desktop;

  /// How wide a page of rows and cards gets on a computer; past this the
  /// lines get too long to read and the page looks empty at the sides.
  static const pageWidth = 860.0;

  /// Extra side padding that keeps a page's content [max] wide and centred
  /// in a wide window. It goes on the scroll view's own padding, so the
  /// scroll view still fills the window and the mouse wheel works anywhere
  /// on it. Nothing on phones.
  static double inset(BuildContext context, {double max = pageWidth}) =>
      on ? math.max(0.0, (MediaQuery.sizeOf(context).width - max) / 2) : 0.0;

  /// [base] padding plus [inset] on both sides.
  static EdgeInsets pad(BuildContext context, EdgeInsets base, {double max = pageWidth}) {
    final i = inset(context, max: max);
    return i == 0 ? base : base.add(EdgeInsets.symmetric(horizontal: i)) as EdgeInsets;
  }

  /// On, and the window is wide enough for labels and side panels.
  static bool wide(BuildContext context) => on && MediaQuery.sizeOf(context).width >= wideFrom;
}
