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
  static const Color incomingBubbleDark = Color(0xFF202327); // dark grey

  // Chat backgrounds.
  static const Color chatBgLight = Color(0xFFFFFFFF);
  static const Color chatBgDark = Color(0xFF000000);

  // Surfaces.
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBar = Color(0xFFF7F9F9);
  static const Color darkSurface = Color(0xFF000000);
  static const Color darkAppBar = Color(0xFF16181C);

  static const Color readTick = Color(0xFF0F1419); // mono read ticks
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
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        backgroundColor: const Color(0xFFEFF2F3),
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.tealGreenDark,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.tealGreenDark,
      secondary: AppColors.accent,
      surface: AppColors.darkSurface,
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
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.darkAppBar,
        indicatorColor: AppColors.tealGreenDark.withValues(alpha: 0.30),
        elevation: 3,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.tealGreenDark
                : Colors.grey.shade400,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.tealGreenDark,
        foregroundColor: Colors.white,
      ),
      chipTheme: base.chipTheme.copyWith(
        side: BorderSide.none,
        backgroundColor: const Color(0xFF202C33),
      ),
    );
  }
}
