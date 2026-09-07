import 'package:flutter/material.dart';

import '../core/l10n/app_localizations.dart';
import '../core/theme/app_theme.dart';

/// The five statutory safety domains the platform covers.
///
/// The numeric [code] is what gets written into a certificate payload, so these
/// values are part of the wire format and must never be renumbered. Adding a
/// domain means appending a new code.
enum SafetyDomain {
  fire(1),
  gas(2),
  machinery(3),
  strata(4),
  electrical(5);

  const SafetyDomain(this.code);

  final int code;

  static SafetyDomain? fromCode(int code) {
    for (final domain in SafetyDomain.values) {
      if (domain.code == code) return domain;
    }
    return null;
  }
}

/// How complete a module's content is.
///
/// Shown honestly in the UI. A worker who opens a shorter module should know it
/// is an introduction rather than a full drill, and an evaluator should not have
/// to guess which modules were built to depth.
enum ModuleDepth {
  /// Multi-act drill with full AR interaction, telemetry and assessment.
  full,

  /// Single act. Playable and assessed, but shorter.
  introductory,
}

/// Static description of a training module.
class TrainingModule {
  const TrainingModule({
    required this.domain,
    required this.icon,
    required this.accent,
    required this.depth,
    required this.actCount,
    required this.estimatedMinutes,
    required this.requiresCamera,
  });

  final SafetyDomain domain;
  final IconData icon;
  final Color accent;
  final ModuleDepth depth;
  final int actCount;
  final int estimatedMinutes;

  /// Whether the module needs the AR view. Assessment-only fallbacks exist for
  /// phones with no working camera, so a broken lens never blocks certification.
  final bool requiresCamera;

  String title(L l10n) => switch (domain) {
        SafetyDomain.fire => l10n.moduleFireTitle,
        SafetyDomain.gas => l10n.moduleGasTitle,
        SafetyDomain.machinery => l10n.moduleMachineryTitle,
        SafetyDomain.strata => l10n.moduleStrataTitle,
        SafetyDomain.electrical => l10n.moduleElectricalTitle,
      };

  String summary(L l10n) => switch (domain) {
        SafetyDomain.fire => l10n.moduleFireSummary,
        SafetyDomain.gas => l10n.moduleGasSummary,
        SafetyDomain.machinery => l10n.moduleMachinerySummary,
        SafetyDomain.strata => l10n.moduleStrataSummary,
        SafetyDomain.electrical => l10n.moduleElectricalSummary,
      };
}

/// The module catalogue, in the order workers should encounter it.
///
/// Fire and gas lead because they are the two domains built to full depth and,
/// not coincidentally, the two that kill fastest when a new recruit gets them
/// wrong.
const List<TrainingModule> kModuleCatalogue = [
  TrainingModule(
    domain: SafetyDomain.fire,
    icon: Icons.local_fire_department_outlined,
    accent: AppTheme.hazardRed,
    depth: ModuleDepth.full,
    actCount: 3,
    estimatedMinutes: 9,
    requiresCamera: true,
  ),
  TrainingModule(
    domain: SafetyDomain.gas,
    icon: Icons.air_outlined,
    accent: AppTheme.cautionAmber,
    depth: ModuleDepth.full,
    actCount: 3,
    estimatedMinutes: 11,
    requiresCamera: true,
  ),
  TrainingModule(
    domain: SafetyDomain.machinery,
    icon: Icons.precision_manufacturing_outlined,
    accent: AppTheme.infoBlue,
    depth: ModuleDepth.introductory,
    actCount: 1,
    estimatedMinutes: 5,
    requiresCamera: true,
  ),
  TrainingModule(
    domain: SafetyDomain.strata,
    icon: Icons.landscape_outlined,
    accent: Color(0xFF6D4C41),
    depth: ModuleDepth.introductory,
    actCount: 1,
    estimatedMinutes: 5,
    requiresCamera: true,
  ),
  TrainingModule(
    domain: SafetyDomain.electrical,
    icon: Icons.electric_bolt_outlined,
    accent: Color(0xFF7B1FA2),
    depth: ModuleDepth.introductory,
    actCount: 1,
    estimatedMinutes: 6,
    requiresCamera: true,
  ),
];

TrainingModule moduleFor(SafetyDomain domain) =>
    kModuleCatalogue.firstWhere((m) => m.domain == domain);
