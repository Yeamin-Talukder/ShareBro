import 'package:flutter/material.dart';

/// Brand palette: "golden hour" — a warm sunset accent for the one or two
/// actions that matter, with violet and teal kept for the drifting aurora in
/// the content layer. Contrast figures are against the matching surface.
class Brand {
  /// Primary actions and the selected tab. White text on it: 5.7:1.
  static const accentLight = Color(0xFFD9432B);

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
  static const danger = Color(0xFFE5484D);
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
  return base.copyWith(
    primary: dark ? Brand.accentDark : Brand.accentLight,
    onPrimary: dark ? const Color(0xFF2A0D06) : Colors.white,
    surface: dark ? Brand.surfaceDark : Brand.surfaceLight,
    onSurface: dark ? Brand.inkDark : Brand.inkLight,
    error: Brand.danger,
  );
}

ThemeData buildTheme(ColorScheme scheme) {
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
      backgroundColor: dark ? const Color(0xF21C1A22) : const Color(0xF7FFFFFF),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      backgroundColor: dark ? const Color(0xF51C1A22) : const Color(0xF7FFFFFF),
      modalBarrierColor: Colors.black.withAlpha(90),
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: dark ? const Color(0xF51C1A22) : const Color(0xF7FFFFFF),
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
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
    }),
  );
}
