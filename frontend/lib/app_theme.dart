import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color bg = Color(0xFF050A1C);
  static const Color panel = Color(0xFF0C1532);
  static const Color panelSoft = Color(0xFF121C3D);
  static const Color border = Color(0xFF243056);
  static const Color accent = Color(0xFF5964F1);
  static const Color accentSoft = Color(0xFF2F3EA5);
  static const Color danger = Color(0xFFE05668);
  static const Color textMuted = Color(0xFF90A1C4);

  // Semantic status colors used consistently across the studio.
  static const Color statusChanged = Color(0xFF5FA8FF);
  static const Color statusChangedBg = Color(0xFF1C345C);
  static const Color statusInvalid = Color(0xFFE05668);
  static const Color statusInvalidBg = Color(0xFF4A1D28);
  static const Color statusMatched = Color(0xFF4CD6A8);
  static const Color statusMatchedBg = Color(0xFF123D36);

  static ThemeData darkTheme(BuildContext context) {
    final base = ThemeData.dark();
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: Color(0xFF39D0D0),
        surface: panel,
        error: danger,
      ),
      scaffoldBackgroundColor: bg,
      textTheme: GoogleFonts.soraTextTheme(
        base.textTheme,
      ).apply(
        bodyColor: const Color(0xFFDDE7FF),
        displayColor: const Color(0xFFDDE7FF),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: panel,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: const CardTheme(
        color: panelSoft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
        ),
        elevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: panelSoft,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: TextStyle(color: textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          borderSide: BorderSide(color: border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          borderSide: BorderSide(color: accent, width: 1.6),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          textStyle: const TextStyle(fontSize: 11),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          textStyle: const TextStyle(fontSize: 11),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(fontSize: 11),
        ),
      ),
      dividerColor: border,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
