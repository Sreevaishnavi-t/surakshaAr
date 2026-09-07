import 'package:flutter/material.dart';

/// Visual design tuned for the actual conditions of use.
///
/// Three constraints drive every choice here, and they are not the usual ones:
///
/// * **Sunlight and headlamps.** Screens get read at a pit head in glare or in a
///   dark gallery. Contrast is pushed well past the usual Material defaults.
/// * **Gloves.** Touch targets are 56 dp minimum rather than 48. A worker in
///   rigger gloves has an effective fingertip well over a centimetre across.
/// * **Low literacy.** Colour and icon always carry the meaning together, never
///   colour alone, and every instruction pairs with audio narration.
class AppTheme {
  const AppTheme._();

  /// Minimum interactive dimension. Above the Material 48 dp guidance because
  /// the users are wearing gloves.
  static const double minTouchTarget = 56;

  // Safety-signal palette. Deliberately close to industrial signage convention
  // so meaning transfers from the signs already on the wall.
  static const Color hazardRed = Color(0xFFD32F2F);
  static const Color cautionAmber = Color(0xFFF9A825);
  static const Color safeGreen = Color(0xFF2E7D32);
  static const Color infoBlue = Color(0xFF1565C0);

  static const Color surfaceDark = Color(0xFF11151C);
  static const Color surfaceDarkElevated = Color(0xFF1B212B);
  static const Color onSurfaceDark = Color(0xFFF2F5F9);

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: infoBlue,
      brightness: Brightness.dark,
      surface: surfaceDark,
      error: hazardRed,
    );

    return _build(scheme);
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: infoBlue,
      brightness: Brightness.light,
      error: hazardRed,
    );

    return _build(scheme);
  }

  static ThemeData _build(ColorScheme scheme) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.apply(
        // Slightly larger than default throughout: these screens are read at
        // arm's length, often in poor light, sometimes through safety glasses.
        fontSizeFactor: 1.08,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(minTouchTarget * 2, minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(minTouchTarget * 2, minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 14,
        contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Colour plus icon for a safety signal, so meaning never rests on hue alone —
/// which would fail the roughly 1 in 12 men with colour vision deficiency, a
/// meaningful share of a mining workforce.
class SafetySignal {
  const SafetySignal({
    required this.color,
    required this.icon,
    required this.semanticLabel,
  });

  final Color color;
  final IconData icon;
  final String semanticLabel;

  static const SafetySignal danger = SafetySignal(
    color: AppTheme.hazardRed,
    icon: Icons.dangerous_outlined,
    semanticLabel: 'Danger',
  );

  static const SafetySignal caution = SafetySignal(
    color: AppTheme.cautionAmber,
    icon: Icons.warning_amber_rounded,
    semanticLabel: 'Caution',
  );

  static const SafetySignal safe = SafetySignal(
    color: AppTheme.safeGreen,
    icon: Icons.check_circle_outline,
    semanticLabel: 'Safe',
  );

  static const SafetySignal info = SafetySignal(
    color: AppTheme.infoBlue,
    icon: Icons.info_outline,
    semanticLabel: 'Information',
  );
}
