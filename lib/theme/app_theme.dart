import 'package:flutter/material.dart';

/// Central palette and [ThemeData] for the app, modeled on WhatsApp's look.
class AppColors {
  AppColors._();

  // Brand greens.
  static const Color tealGreen = Color(0xFF075E54);
  static const Color tealGreenDark = Color(0xFF128C7E);
  static const Color lightGreen = Color(0xFF25D366);
  static const Color accent = Color(0xFF25D366);

  // Chat bubbles.
  static const Color outgoingBubbleLight = Color(0xFFDCF8C6);
  static const Color incomingBubbleLight = Color(0xFFFFFFFF);
  static const Color outgoingBubbleDark = Color(0xFF005C4B);
  static const Color incomingBubbleDark = Color(0xFF202C33);

  // Chat backgrounds.
  static const Color chatBgLight = Color(0xFFECE5DD);
  static const Color chatBgDark = Color(0xFF0B141A);

  // Surfaces (dark).
  static const Color darkSurface = Color(0xFF121B22);
  static const Color darkAppBar = Color(0xFF1F2C34);

  static const Color readTick = Color(0xFF53BDEB);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.tealGreen,
        secondary: AppColors.accent,
      ),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.tealGreen,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.tealGreenDark,
        foregroundColor: Colors.white,
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white70,
        indicatorColor: Colors.white,
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: AppColors.tealGreen,
        unselectedItemColor: Colors.grey,
        backgroundColor: Colors.white,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.tealGreenDark,
        secondary: AppColors.accent,
        surface: AppColors.darkSurface,
      ),
      scaffoldBackgroundColor: AppColors.darkSurface,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.darkAppBar,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w500,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.tealGreenDark,
        foregroundColor: Colors.white,
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.lightGreen,
        unselectedLabelColor: Colors.white54,
        indicatorColor: AppColors.lightGreen,
        indicatorSize: TabBarIndicatorSize.tab,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        selectedItemColor: AppColors.lightGreen,
        unselectedItemColor: Colors.grey,
        backgroundColor: AppColors.darkAppBar,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
