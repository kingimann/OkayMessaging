import 'package:flutter/material.dart';

/// Central palette and [ThemeData]. A distinct violet/indigo identity — its
/// own look, not a WhatsApp clone. (Constant names are kept for stability;
/// they now hold the brand-violet palette rather than greens.)
class AppColors {
  AppColors._();

  // Brand violet/indigo.
  static const Color tealGreen = Color(0xFF5B3FE0); // deep brand violet
  static const Color tealGreenDark = Color(0xFF7A5CFF); // accent violet
  static const Color lightGreen = Color(0xFF9B87FF); // light accent
  static const Color accent = Color(0xFF7A5CFF);

  // Chat bubbles.
  static const Color outgoingBubbleLight = Color(0xFFEAE4FF); // soft violet
  static const Color incomingBubbleLight = Color(0xFFFFFFFF);
  static const Color outgoingBubbleDark = Color(0xFF4A3AA8);
  static const Color incomingBubbleDark = Color(0xFF262636);

  // Chat backgrounds.
  static const Color chatBgLight = Color(0xFFF4F1FC); // soft lavender
  static const Color chatBgDark = Color(0xFF141322);

  // Surfaces.
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBar = Color(0xFFF6F4FD);
  static const Color darkSurface = Color(0xFF15131F);
  static const Color darkAppBar = Color(0xFF1E1B2E);

  static const Color readTick = Color(0xFF7A5CFF); // violet read ticks
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
