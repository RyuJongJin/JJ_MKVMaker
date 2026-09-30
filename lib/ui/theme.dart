import 'package:flutter/material.dart';

/// CapCut 참고 어두운 테마
class JjColors {
  static const bg = Color(0xFF141417);
  static const panel = Color(0xFF1E1E23);
  static const panelHigh = Color(0xFF28282F);
  static const border = Color(0xFF2E2E36);
  static const accent = Color(0xFF00C4CC); // CapCut 계열 청록
  static const text = Color(0xFFE8E8EC);
  static const textDim = Color(0xFF8E8E99);
  static const danger = Color(0xFFFF5C6C);
  static const success = Color(0xFF3DD68C);
}

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: JjColors.accent,
      secondary: JjColors.accent,
      surface: JjColors.panel,
      error: JjColors.danger,
    ),
    scaffoldBackgroundColor: JjColors.bg,
    fontFamily: 'Malgun Gothic',
  );
  return base.copyWith(
    dividerColor: JjColors.border,
    textTheme: base.textTheme.apply(
      bodyColor: JjColors.text,
      displayColor: JjColors.text,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: JjColors.accent,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: JjColors.text,
        side: const BorderSide(color: JjColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
  );
}
