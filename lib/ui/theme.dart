import 'package:flutter/material.dart';

import '../data/db.dart';
import '../platform/device.dart';

/// Light or dark: follow the phone (the default), or always one of them.
/// Picked in Settings and remembered.
class Appearance {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);
  static const _key = 'appearance';

  static Future<void> load(AppDb db) async {
    mode.value = switch (await db.setting(_key)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  static Future<void> set(AppDb db, ThemeMode m) async {
    mode.value = m;
    await db.setSetting(_key, m.name);
  }
}

/// Brand palette: "golden hour" — a warm sunset accent for the one or two
/// actions that matter, with violet and teal kept for the drifting aurora in
/// the content layer. Contrast figures are against the matching surface.
class Brand {
  /// Primary actions and the selected tab. White text on it: 5.5:1; as
  /// text on [surfaceLight]: 5.0:1 (plain text needs 4.5:1).
  static const accentLight = Color(0xFFBF3A22);

  /// Accent on dark surfaces: 8.0:1 against [surfaceDark].
  static const accentDark = Color(0xFFFF8A6B);

  /// Aurora-only colours (never used for text or controls).
  static const violet = Color(0xFF6E5BFF);
  static const teal = Color(0xFF2BB5A6);

  static const surfaceLight = Color(0xFFF6F5F8);
  static const surfaceDark = Color(0xFF0F0E12);

  /// Body text: 16.9:1 on [surfaceLight], 17.6:1 on [surfaceDark].
  static const inkLight = Color(0xFF1A1820);
  static const inkDark = Color(0xFFF2EFF5);

  static const success = Color(0xFF1FA971);
  /// White text on it: 4.9:1.
  static const danger = Color(0xFFD13438);
}

/// The computer version's look, after Apple's Mac apps: neutral greys for
/// the window, sidebar and grouped cards, hairline separators, and the
/// label greys used for secondary text. The phone keeps its own palette.
abstract final class Mac {
  /// The page behind cards (like System Settings' content area).
  static const windowLight = Color(0xFFF5F5F7);
  static const windowDark = Color(0xFF1C1C1E);

  /// The sidebar: a step darker in the light, a step lighter in the dark.
  static const sidebarLight = Color(0xFFEBEBEE);
  static const sidebarDark = Color(0xFF262628);

  /// Grouped cards, menus, popovers and dialogs.
  static const cardLight = Color(0xFFFFFFFF);
  static const cardDark = Color(0xFF2C2C2E);
  static const raisedDark = Color(0xFF323234);

  /// Text.
  static const inkLight = Color(0xFF1D1D1F);
  static const inkDark = Color(0xFFF5F5F7);
  static const secondaryLight = Color(0xFF6E6E73);
  static const secondaryDark = Color(0xFF98989D);

  /// Hairlines between rows and around cards.
  static const hairlineLight = Color(0x1F000000);
  static const hairlineDark = Color(0x1FFFFFFF);

  /// The system green, for live transfers.
  static const green = Color(0xFF34C759);

  /// Rounded corners: cards and panels, controls (buttons, fields), and
  /// small pieces (menu rows, sidebar rows).
  static const cardRadius = 12.0;
  static const controlRadius = 8.0;
  static const rowRadius = 6.0;

  static Color window(BuildContext context) => _dark(context) ? windowDark : windowLight;
  static Color sidebar(BuildContext context) => _dark(context) ? sidebarDark : sidebarLight;
  static Color card(BuildContext context) => _dark(context) ? cardDark : cardLight;
  static Color hairline(BuildContext context) => _dark(context) ? hairlineDark : hairlineLight;
  static Color secondary(BuildContext context) => _dark(context) ? secondaryDark : secondaryLight;

  /// The quiet fill of a hovered row or button.
  static Color hover(BuildContext context) => _dark(context) ? const Color(0x14FFFFFF) : const Color(0x0D000000);

  /// The fill of a selected sidebar row.
  static Color selection(BuildContext context) => _dark(context) ? const Color(0x24FFFFFF) : const Color(0x17000000);

  static bool _dark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  /// Windows' own UI font (the closest to Apple's SF on a PC), with the
  /// older Segoe UI when it isn't installed.
  static const font = 'Segoe UI Variable Text';
  static const fontDisplay = 'Segoe UI Variable Display';
  static const fontFallback = ['Segoe UI', 'Helvetica Neue', 'Arial'];
}

/// The app's text sizes. Hand-set sizes pick from these, never a loose
/// number, so the steps stay even and nothing drops below 11.
abstract final class TextSize {
  /// Badges and labels on photos; the smallest allowed.
  static const tiny = 11.0;
  static const small = 12.0;
  static const caption = 13.0;
  static const label = 14.0;
  static const callout = 15.0;
  static const body = 16.0;
  static const headline = 18.0;
  static const title3 = 20.0;
  static const title2 = 22.0;
  static const title1 = 28.0;
  static const display = 34.0;
}

/// Kept for code that still asks for "the seed".
const seedColor = Brand.accentLight;

ColorScheme brandScheme(Brightness b) {
  final dark = b == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: Brand.accentLight,
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );
  final branded = base.copyWith(
    primary: dark ? Brand.accentDark : Brand.accentLight,
    onPrimary: dark ? const Color(0xFF2A0D06) : Colors.white,
    surface: dark ? Brand.surfaceDark : Brand.surfaceLight,
    onSurface: dark ? Brand.inkDark : Brand.inkLight,
    error: Brand.danger,
  );
  if (!Device.desktop) return branded;
  // On a computer: Apple's neutral greys instead of the tinted ones, so
  // the coral accent is the only colour in the chrome.
  return branded.copyWith(
    surface: dark ? Mac.windowDark : Mac.windowLight,
    onSurface: dark ? Mac.inkDark : Mac.inkLight,
    onSurfaceVariant: dark ? Mac.secondaryDark : Mac.secondaryLight,
    surfaceContainerLowest: dark ? const Color(0xFF161618) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF232325) : const Color(0xFFFAFAFC),
    surfaceContainer: dark ? Mac.cardDark : Colors.white,
    surfaceContainerHigh: dark ? Mac.raisedDark : const Color(0xFFF0F0F2),
    surfaceContainerHighest: dark ? const Color(0xFF3A3A3C) : const Color(0xFFE8E8ED),
    outline: dark ? const Color(0xFF5A5A5E) : const Color(0xFFC7C7CC),
    outlineVariant: dark ? const Color(0xFF3A3A3C) : const Color(0xFFD9D9DE),
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildTheme(ColorScheme scheme) =>
    Device.desktop ? _buildDesktopTheme(scheme) : _buildPhoneTheme(scheme);

/// The computer version: Mac-like density and shapes. Controls are 32-36
/// tall with 8 px corners, menus and dialogs float on hairline-rimmed
/// cards, clicks don't ripple (hover and press tint instead), tooltips are
/// small and quick, and pages cross-fade.
ThemeData _buildDesktopTheme(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: Mac.font,
    fontFamilyFallback: Mac.fontFallback,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
  );
  final t = base.textTheme;
  TextStyle? display(TextStyle? s, double size, FontWeight w, double tracking) =>
      s?.copyWith(fontFamily: Mac.fontDisplay, fontSize: size, fontWeight: w, letterSpacing: tracking, height: 1.15);
  final text = t.copyWith(
    displayLarge: display(t.displayLarge, 48, FontWeight.w700, -1.2),
    displayMedium: display(t.displayMedium, 38, FontWeight.w700, -0.9),
    // The large title on every page (26-28 pt on a Mac).
    displaySmall: display(t.displaySmall, 28, FontWeight.w700, -0.6),
    headlineLarge: display(t.headlineLarge, 26, FontWeight.w700, -0.5),
    headlineMedium: display(t.headlineMedium, 24, FontWeight.w700, -0.4),
    headlineSmall: display(t.headlineSmall, 20, FontWeight.w700, -0.3),
    titleLarge: display(t.titleLarge, 17, FontWeight.w600, -0.2),
    titleMedium: t.titleMedium?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
    titleSmall: t.titleSmall?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 14, height: 1.35),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 13, height: 1.35),
    bodySmall: t.bodySmall?.copyWith(fontSize: 12, height: 1.3),
    labelLarge: t.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0),
    labelMedium: t.labelMedium?.copyWith(fontSize: 12, letterSpacing: 0),
    labelSmall: t.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0),
  );
  final hairline = dark ? Mac.hairlineDark : Mac.hairlineLight;
  final card = dark ? Mac.cardDark : Mac.cardLight;
  final popover = dark ? Mac.raisedDark : const Color(0xFFFDFDFD);
  const control = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Mac.controlRadius)));
  const buttonSize = Size(64, 34);
  const buttonPad = EdgeInsets.symmetric(horizontal: 16);
  final buttonText = text.labelLarge;
  final hover = scheme.onSurface.withValues(alpha: dark ? 0.08 : 0.05);
  final press = scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.1);

  // Hover and press tints for buttons that have no ripple.
  WidgetStateProperty<Color?> overlay(Color base) => WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return base.withValues(alpha: 0.16);
        if (s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)) return base.withValues(alpha: 0.08);
        return null;
      });

  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    hoverColor: hover,
    highlightColor: press,
    focusColor: scheme.primary.withValues(alpha: 0.18),
    iconTheme: IconThemeData(size: 20, color: scheme.onSurface),
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Mac.cardRadius),
        side: BorderSide(color: hairline, width: 0.5),
      ),
      elevation: 0,
      color: card,
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 52,
      iconTheme: IconThemeData(size: 20, color: scheme.onSurface),
      actionsIconTheme: IconThemeData(size: 20, color: scheme.onSurface),
      titleTextStyle: text.titleMedium?.copyWith(color: scheme.onSurface),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: hairline),
      backgroundColor: card,
      selectedColor: scheme.primary.withValues(alpha: 0.16),
      labelStyle: text.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: control,
        minimumSize: buttonSize,
        padding: buttonPad,
        textStyle: buttonText,
        elevation: 0,
      ).copyWith(overlayColor: overlay(scheme.onPrimary)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: control,
        minimumSize: buttonSize,
        padding: buttonPad,
        textStyle: buttonText,
        elevation: 0,
        backgroundColor: card,
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: hairline),
      ).copyWith(overlayColor: overlay(scheme.onSurface)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: control,
        minimumSize: buttonSize,
        padding: buttonPad,
        textStyle: buttonText,
        foregroundColor: scheme.onSurface,
        backgroundColor: card,
        side: BorderSide(color: dark ? const Color(0x33FFFFFF) : const Color(0x26000000)),
      ).copyWith(overlayColor: overlay(scheme.onSurface)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: control,
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: buttonText,
      ).copyWith(overlayColor: overlay(scheme.primary)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: control,
        minimumSize: const Size(34, 34),
        padding: const EdgeInsets.all(7),
        iconSize: 19,
        visualDensity: VisualDensity.compact,
      ).copyWith(overlayColor: overlay(scheme.onSurface)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: control,
      elevation: 1,
      hoverElevation: 2,
      focusElevation: 2,
      highlightElevation: 1,
      extendedTextStyle: buttonText,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: hairline),
        shape: control,
        minimumSize: const Size(0, 30),
        textStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w500),
        selectedBackgroundColor: card,
        selectedForegroundColor: scheme.onSurface,
        backgroundColor: scheme.onSurface.withValues(alpha: dark ? 0.1 : 0.05),
        visualDensity: VisualDensity.compact,
      ),
    ),
    switchTheme: SwitchThemeData(
      // An Apple switch: always a white thumb, accent track when on, a
      // quiet grey one when off, no outline.
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? Colors.white.withValues(alpha: 0.7) : Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? scheme.primary
          : (dark ? const Color(0xFF48484A) : const Color(0xFFE2E2E7))),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: scheme.outline, width: 1.2),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    radioTheme: const RadioThemeData(
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: dark ? 0.18 : 0.12),
      thumbColor: Colors.white,
      overlayShape: SliderComponentShape.noOverlay,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 2, pressedElevation: 3),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.08),
      linearMinHeight: 4,
      borderRadius: BorderRadius.circular(2),
      circularTrackColor: Colors.transparent,
      strokeWidth: 3,
    ),
    inputDecorationTheme: InputDecorationTheme(
      // A Mac text field: a light fill, a hairline, an accent ring on focus.
      filled: true,
      fillColor: dark ? const Color(0x14FFFFFF) : Colors.white,
      hoverColor: Colors.transparent,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Mac.controlRadius),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Mac.controlRadius),
        borderSide: BorderSide(color: dark ? const Color(0x29FFFFFF) : const Color(0x24000000)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Mac.controlRadius),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.75), width: 2),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: scheme.primary,
      selectionColor: scheme.primary.withValues(alpha: 0.28),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: hairline, width: 0.5),
      ),
      backgroundColor: popover,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.25),
      titleTextStyle: text.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
      contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 460),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      // On a computer a sheet is a panel of readable width, not the whole
      // window's width.
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: hairline, width: 0.5),
      ),
      backgroundColor: popover,
      surfaceTintColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 600),
      modalBarrierColor: Colors.black.withAlpha(dark ? 110 : 60),
      elevation: 0,
      dragHandleColor: scheme.onSurface.withValues(alpha: 0.2),
      dragHandleSize: const Size(36, 4),
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: hairline, width: 0.5),
      ),
      color: popover,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.2),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      textStyle: text.bodyMedium?.copyWith(color: scheme.onSurface),
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium?.copyWith(color: scheme.onSurface)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(popover),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: hairline, width: 0.5),
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 5)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: MenuItemButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Mac.rowRadius)),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      textStyle: text.bodyMedium,
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(popover),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: hairline, width: 0.5),
        )),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      // Small and quick, like a Mac help tag.
      waitDuration: const Duration(milliseconds: 600),
      showDuration: const Duration(milliseconds: 1500),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle: text.labelMedium?.copyWith(color: scheme.onSurface),
      decoration: BoxDecoration(
        color: popover,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: hairline, width: 0.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.4 : 0.12), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      // A thin overlay scroller that widens under the mouse.
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) ? 8 : 6),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith((s) => scheme.onSurface
          .withValues(alpha: s.contains(WidgetState.dragged) ? 0.5 : s.contains(WidgetState.hovered) ? 0.4 : 0.28)),
      trackVisibility: const WidgetStatePropertyAll(false),
      crossAxisMargin: 2,
      mainAxisMargin: 4,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 440,
      elevation: 6,
      backgroundColor: dark ? const Color(0xFF3A3A3C) : const Color(0xFF2C2C2E),
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
      actionTextColor: Brand.accentDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Mac.cardRadius)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Mac.controlRadius)),
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 24,
      horizontalTitleGap: 12,
      titleTextStyle: text.bodyLarge?.copyWith(color: scheme.onSurface),
      subtitleTextStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      iconColor: scheme.onSurfaceVariant,
    ),
    dividerTheme: DividerThemeData(color: hairline, space: 1, thickness: 0.5),
    tabBarTheme: TabBarThemeData(
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      dividerColor: hairline,
      overlayColor: overlay(scheme.onSurface),
    ),
    badgeTheme: BadgeThemeData(textStyle: text.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.windows: DesktopPageTransitions(),
      TargetPlatform.linux: DesktopPageTransitions(),
      TargetPlatform.macOS: DesktopPageTransitions(),
    }),
  );
}

/// A Mac-like page change: the new page fades in while settling a few
/// pixels into place; nothing zooms or slides across the window.
class DesktopPageTransitions extends PageTransitionsBuilder {
  const DesktopPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(curved),
        // The page underneath stays opaque, so the new one fades over it
        // rather than through an empty window.
        child: ColoredBox(color: Theme.of(context).colorScheme.surface, child: child),
      ),
    );
  }
}

ThemeData _buildPhoneTheme(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  // System font for UI; hierarchy comes from weight and tight tracking on
  // the large titles.
  final text = base.textTheme.copyWith(
    displayLarge: base.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.5),
    displayMedium: base.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1.2),
    displaySmall: base.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
    headlineLarge: base.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
    headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
    titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
    titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
  );
  final hairline = scheme.outlineVariant.withAlpha(dark ? 70 : 110);
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: hairline),
      ),
      elevation: 0,
      color: dark ? const Color(0xFF1A1820) : Colors.white,
      margin: EdgeInsets.zero,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: hairline),
      backgroundColor: dark ? const Color(0xFF1A1820) : Colors.white,
      selectedColor: scheme.primaryContainer,
      labelStyle: text.labelLarge,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 48),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        minimumSize: const Size(64, 48),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(48, 44)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        side: BorderSide(color: hairline),
        selectedBackgroundColor: scheme.primaryContainer,
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      backgroundColor: dark ? const Color(0xFF1C1A22) : Colors.white,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      backgroundColor: dark ? const Color(0xFF1C1A22) : Colors.white,
      // On a computer a sheet is a panel of readable width, not the whole
      // window's width.
      constraints: Device.desktop ? const BoxConstraints(maxWidth: 640) : null,
      modalBarrierColor: Colors.black.withAlpha(90),
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: dark ? const Color(0xFF1C1A22) : Colors.white,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dividerTheme: DividerThemeData(color: hairline, space: 1),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: SnappyPageTransitions(),
    }),
  );
}

/// Android's own page transition (the back gesture still peeks at the page
/// behind), but quicker: the stock 450 ms makes every tap feel slow.
class SnappyPageTransitions extends PredictiveBackPageTransitionsBuilder {
  const SnappyPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);
}
