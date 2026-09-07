import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/l10n/app_localizations.dart';
import 'core/services.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Services are brought up before the first frame. If the database or the
  // device signing key cannot be initialised the app genuinely cannot record
  // anything, and a worker handed a phone that silently loses their training is
  // worse off than one told plainly that it is broken.
  Object? startupError;
  StackTrace? startupStack;
  AppServices? services;

  try {
    services = await AppServices.initialise();
  } catch (error, stack) {
    startupError = error;
    startupStack = stack;
  }

  runApp(
    services == null
        ? StartupFailureApp(error: startupError!, stackTrace: startupStack)
        : ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: const SurakshaArApp(),
          ),
  );
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
      localeListResolutionCallback: resolveLocale,
      home: const HomeScreen(),
    );
  }

  /// Falls back Santali → Hindi → English.
  ///
  /// A Santali speaker in Jharkhand is far likelier to read Devanagari than
  /// English, so an unreviewed or missing `sat` string should land on Hindi
  /// rather than jumping straight to the source locale. English stays the
  /// terminal fallback so nothing can ever render blank.
  @visibleForTesting
  static Locale? resolveLocale(List<Locale>? locales, Iterable<Locale> supported) {
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
      final hindi = supported.where((l) => l.languageCode == 'hi');
      if (hindi.isNotEmpty) return hindi.first;
    }

    return const Locale('en');
  }
}

/// Shown when startup fails outright.
///
/// Deliberately plain and specific rather than a generic crash screen: whoever
/// is holding the phone needs to be able to tell a supervisor what went wrong.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({super.key, required this.error, this.stackTrace});

  final Object error;
  final StackTrace? stackTrace;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 56,
                  color: AppTheme.hazardRed,
                ),
                const SizedBox(height: 18),
                Text(
                  'SurakshaAR could not start',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The training record store on this phone could not be opened, '
                  'so nothing you do would be saved. Show this screen to your '
                  'supervisor.',
                  style: TextStyle(fontSize: 16, height: 1.45),
                ),
                const SizedBox(height: 20),
                SelectableText(
                  '$error',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
