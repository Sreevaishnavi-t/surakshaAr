import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n/app_localizations.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ProviderScope(child: SurakshaArApp()));
}

class SurakshaArApp extends StatelessWidget {
  const SurakshaArApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SurakshaAR',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // AR sessions dominate usage and run against a camera feed, so the dark
      // surface is the default rather than following the system setting.
      themeMode: ThemeMode.dark,
      localizationsDelegates: L.localizationsDelegates,
      supportedLocales: L.supportedLocales,
      localeListResolutionCallback: _resolveLocale,
      home: const HomeScreen(),
    );
  }

  /// Falls back Santali → Hindi → English.
  ///
  /// A Santali speaker in Jharkhand is far likelier to read Devanagari than
  /// English, so an unreviewed or missing `sat` string should land on Hindi
  /// rather than jumping straight to the source locale. English stays the
  /// terminal fallback so nothing can ever render blank.
  static Locale? _resolveLocale(List<Locale>? locales, Iterable<Locale> supported) {
    if (locales == null || locales.isEmpty) return const Locale('en');

    for (final locale in locales) {
      for (final candidate in supported) {
        if (candidate.languageCode == locale.languageCode) return candidate;
      }
    }

    // Nothing matched. If the device is set to any Indic language we are more
    // useful in Hindi than in English.
    const indicLanguages = {
      'hi', 'bn', 'or', 'mr', 'ne', 'mai', 'bho', 'sat', 'kru', 'hoc', 'mwr',
    };
    if (locales.any((l) => indicLanguages.contains(l.languageCode))) {
      return const Locale('hi');
    }

    return const Locale('en');
  }
}
