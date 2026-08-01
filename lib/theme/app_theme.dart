import 'package:flutter/material.dart';

/// Central palette and [ThemeData]. A clean monochrome black-and-white
/// identity, in the spirit of X. (Constant names are kept for stability; they
/// now hold the mono palette.)
class AppColors {
  AppColors._();

  // Brand mono — near-black in light, near-white in dark.
  static const Color tealGreen = Color(0xFF0F1419); // ink / brand
  static const Color tealGreenDark = Color(0xFF0F1419); // accent (light)
  static const Color lightGreen = Color(0xFF536471); // secondary grey
  static const Color accent = Color(0xFF0F1419);

  // Chat bubbles — outgoing high-contrast, incoming subtle grey.
  static const Color outgoingBubbleLight = Color(0xFF0F1419); // black bubble
  static const Color incomingBubbleLight = Color(0xFFEFF3F4); // light grey
  static const Color outgoingBubbleDark = Color(0xFFE7E9EA); // light bubble
  static const Color incomingBubbleDark = Color(0xFF262A30); // dark grey

  // Chat backgrounds. A soft near-black (not pure black) for a comfortable
  // dark mode, with elevated surfaces sitting slightly lighter on top.
  static const Color chatBgLight = Color(0xFFFFFFFF);
  static const Color chatBgDark = Color(0xFF16181C);

  // Surfaces.
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBar = Color(0xFFF7F9F9);
  static const Color darkSurface = Color(0xFF16181C); // base background
  static const Color darkAppBar = Color(0xFF23262B); // elevated surface
  static const Color darkElevated = Color(0xFF23262B); // cards / sheets

  static const Color readTick = Color(0xFF0F1419); // mono read ticks

  /// The accent that actually contrasts with what's behind it: near-black in
  /// light mode, near-white in dark. Filled controls must use this rather than
  /// [tealGreenDark] — that constant is the *light* accent, and hard-coding it
  /// paints a near-black button onto a near-black screen.
  static Color accentOn(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// The colour for text and icons sitting on [accentOn].
  static Color onAccent(BuildContext context) =>
      Theme.of(context).colorScheme.onPrimary;

  /// Secondary text — captions, timestamps, the grey half of a two-tone line.
  ///
  /// USE THIS RATHER THAN A GREY FROM THE PALETTE. `Colors.grey.shade600`
  /// contrasts 4.61:1 against the light surface and **3.86:1** against the
  /// dark one; `shade500` is 6.63:1 on dark and **2.68:1** on light. Each
  /// fails in one theme and neither fails in the same one, so no fixed grey
  /// can pass both — the app had 300 of them, half of them unreadable
  /// depending on which theme you were in.
  ///
  /// This is 9.36:1 and 10.44:1, because the theme picks it per brightness.
  static Color subtle(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
}

class AppTheme {
  AppTheme._();

  /// A consistent, modern zoom page transition on every platform (including
  /// web, which otherwise has no motion).
  static const PageTransitionsTheme _transitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
      TargetPlatform.linux: ZoomPageTransitionsBuilder(),
      TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
      TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      TargetPlatform.fuchsia: ZoomPageTransitionsBuilder(),
    },
  );

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.tealGreen,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.tealGreen,
      secondary: AppColors.accent,
      surface: AppColors.lightSurface,
      // Neutral containers. `fromSeed` builds these from a tonal palette and
      // bumps the chroma while it does — from a seed that is very nearly
      // black it still handed back #CDE5FF, #D4E4F6 and #EDDCFF, all at full
      // saturation. Nobody chose those, and every widget that reaches for a
      // container colour got one: the onboarding card on the chat list, the
      // selected filter chip on Alerts, the storage card. Saturated blocks
      // scattered through an app whose identity is black and white.
      //
      // errorContainer keeps its red on purpose — that one is saying
      // something.
      primaryContainer: const Color(0xFFE9EDEF),
      onPrimaryContainer: const Color(0xFF11181C),
      secondaryContainer: const Color(0xFFE9EDEF),
      onSecondaryContainer: const Color(0xFF11181C),
      tertiaryContainer: const Color(0xFFEFF2F3),
      onTertiaryContainer: const Color(0xFF11181C),
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.lightSurface,
      textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
      pageTransitionsTheme: _transitions,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightSurface,
        foregroundColor: Color(0xFF11181C),
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          // Named explicitly: an AppBarTheme style does not inherit from the
          // textTheme, so without this the one piece of chrome on every screen
          // was the one piece not drawn in the app's own type.
          fontFamily: 'Roboto',
          color: Color(0xFF11181C),
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.lightBar,
        indicatorColor: AppColors.tealGreenDark.withValues(alpha: 0.18),
        elevation: 3,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.tealGreen
                : Colors.grey.shade600,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.tealGreenDark,
        foregroundColor: Colors.white,
      ),
      dividerTheme: DividerThemeData(
          thickness: 0.6, color: Colors.black.withValues(alpha: 0.08)),
      // App-wide control polish: filled rounded inputs, pill filled buttons,
      // soft popup menus — so every screen matches without hand-styling.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF0F2F3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          // Same reason as the app bar title: a component theme's textStyle
          // does not inherit the textTheme's family, so every filled button
          // in the app was labelled in a different typeface to the app.
          textStyle: const TextStyle(
              fontFamily: 'Roboto', fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 4,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      // A selected chip takes the accent, like every other selected thing
      // here — the nav pill, a filled button. It used to fall through to the
      // scheme's `secondaryContainer`, which is how the filter row on Alerts
      // ended up with one teal chip in it; with that neutralised, selected
      // and unselected became the same grey and the row stopped saying which
      // filter was on.
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        backgroundColor: const Color(0xFFEFF2F3),
        selectedColor: AppColors.tealGreen,
        labelStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF11181C)),
        secondaryLabelStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: Colors.white),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // Softer, modern popups everywhere: rounded dialogs and sheets.
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    // In dark mode the accent flips to near-white (X-style), so switches,
    // selected states and filled controls are visible on black.
    const darkInk = Color(0xFFE7E9EA);
    final scheme = ColorScheme.fromSeed(
      seedColor: darkInk,
      brightness: Brightness.dark,
    ).copyWith(
      primary: darkInk,
      onPrimary: Colors.black,
      secondary: darkInk,
      onSecondary: Colors.black,
      surface: AppColors.darkSurface,
      // See the light theme: `fromSeed` gave these #004E5C, #334A50 and
      // #3E4565 — a teal, a teal and a violet, at full chroma, on a screen
      // that is otherwise greyscale.
      primaryContainer: const Color(0xFF2A2E34),
      onPrimaryContainer: const Color(0xFFE7E9EA),
      secondaryContainer: const Color(0xFF2A2E34),
      onSecondaryContainer: const Color(0xFFE7E9EA),
      tertiaryContainer: const Color(0xFF262A30),
      onTertiaryContainer: const Color(0xFFE7E9EA),
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.darkSurface,
      textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
      pageTransitionsTheme: _transitions,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkAppBar,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 1,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: 'Roboto',
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.darkAppBar,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
        elevation: 3,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : Colors.grey.shade400,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
      ),
      dividerTheme: DividerThemeData(
          thickness: 0.6, color: Colors.white.withValues(alpha: 0.10)),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF2A2E34),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.3),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          // Same reason as the app bar title: a component theme's textStyle
          // does not inherit the textTheme's family, so every filled button
          // in the app was labelled in a different typeface to the app.
          textStyle: const TextStyle(
              fontFamily: 'Roboto', fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.darkElevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 4,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xFF20232A),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      // See the light theme.
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        backgroundColor: const Color(0xFF2A2E34),
        selectedColor: darkInk,
        labelStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFFE7E9EA)),
        secondaryLabelStyle: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: Colors.black),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // Softer, modern popups everywhere: rounded dialogs and sheets.
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
    );
  }
}
