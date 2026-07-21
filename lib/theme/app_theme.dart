import 'package:flutter/material.dart';

/// Central palette and [ThemeData], refreshed to match WhatsApp's current
/// (light-header + bottom-navigation) look.
class AppColors {
  AppColors._();

  // Modern brand greens.
  static const Color tealGreen = Color(0xFF008069); // deep brand green
  static const Color tealGreenDark = Color(0xFF00A884); // accent green
  static const Color lightGreen = Color(0xFF25D366);
  static const Color accent = Color(0xFF00A884);

  // Chat bubbles.
  static const Color outgoingBubbleLight = Color(0xFFD9FDD3);
  static const Color incomingBubbleLight = Color(0xFFFFFFFF);
  static const Color outgoingBubbleDark = Color(0xFF005C4B);
  static const Color incomingBubbleDark = Color(0xFF202C33);

  // Chat backgrounds.
  static const Color chatBgLight = Color(0xFFEFEAE2);
  static const Color chatBgDark = Color(0xFF0B141A);

  // Surfaces.
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightBar = Color(0xFFF7F8FA);
  static const Color darkSurface = Color(0xFF111B21);
  static const Color darkAppBar = Color(0xFF1F2C34);

  static const Color readTick = Color(0xFF53BDEB);
}

class AppTheme {
  AppTheme._();

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
