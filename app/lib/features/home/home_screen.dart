import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../certificate/certificate_issuer.dart';
import '../../core/l10n/app_localizations.dart';
import '../../core/services.dart';
import '../../core/theme/app_theme.dart';
import '../../data/device_identity.dart';
import '../../data/repositories.dart';
import '../../modules/catalogue.dart';
import '../certificate/certificate_screen.dart';
import '../enrolment/enrolment_screen.dart';
import '../module/module_screen.dart';
import '../verify/verify_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L.of(context);
    final theme = Theme.of(context);
    final worker = ref.watch(activeWorkerProvider);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(activeWorkerProvider);
            ref.invalidate(pendingSyncProvider);
          },
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            size: 32,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              l10n.appName,
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            tooltip: l10n.homeVerifyCertificate,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const VerifyScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.appTagline,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _OfflineBadge(),
                      const SizedBox(height: 12),
                      if (OrganisationKey.isDevelopmentRoot)
                        const _DevelopmentRootNotice(),
                      const SizedBox(height: 12),
                      worker.when(
                        data: (record) => _WorkerBar(worker: record),
                        loading: () => const LinearProgressIndicator(),
                        error: (e, _) => Text('$e'),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
              SliverList.separated(
                itemCount: kModuleCatalogue.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final module = kModuleCatalogue[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: _ModuleCard(
                      module: module,
                      onTap: () async {
                        final active = await _requireWorker(context, ref);
                        if (active == null || !context.mounted) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ModuleScreen(
                              domain: module.domain,
                              worker: active,
                            ),
                          ),
                        );
                        ref.invalidate(pendingSyncProvider);
                      },
                    ),
                  );
                },
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        ),
      ),
      floatingActionButton: worker.maybeWhen(
        data: (record) => record == null
            ? null
            : FloatingActionButton.extended(
                onPressed: () => _showCertificate(context, ref, record),
                icon: const Icon(Icons.workspace_premium_outlined),
                label: Text(L.of(context).homeMyCertificate),
              ),
        orElse: () => null,
      ),
    );
  }

  /// Ensures a worker is selected before any training is recorded.
  ///
  /// Attributing one worker's drill to another would be worse than having no
  /// record, so this blocks rather than guessing.
  static Future<WorkerRecord?> _requireWorker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final existing = await ref.read(servicesProvider).activeWorker();
    if (existing != null) return existing;
    if (!context.mounted) return null;

    return Navigator.of(context).push<WorkerRecord>(
      MaterialPageRoute(builder: (_) => const EnrolmentScreen()),
    );
  }

  static Future<void> _showCertificate(
    BuildContext context,
    WidgetRef ref,
    WorkerRecord worker,
  ) async {
    final services = ref.read(servicesProvider);
    final issuer = CertificateIssuer(
      attempts: services.attempts,
      certificates: services.certificates,
      codec: services.codec,
    );

    try {
      final issued = await issuer.issueProvisional(
        worker: worker,
        deviceKeyId: services.identity.keyId,
        deviceKeyPair: services.identity.keyPair,
      );
      if (!context.mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CertificateScreen(
            certificate: issued.certificate,
            qrPayload: issued.qrPayload,
          ),
        ),
      );
      ref.invalidate(pendingSyncProvider);
    } on NotCertifiable catch (e) {
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Not certified yet'),
          content: Text(e.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

class _WorkerBar extends ConsumerWidget {
  const _WorkerBar({required this.worker});

  final WorkerRecord? worker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final record = worker;

    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.of(context).push<WorkerRecord>(
            MaterialPageRoute(builder: (_) => const EnrolmentScreen()),
          );
          ref.invalidate(activeWorkerProvider);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  record == null ? Icons.person_add_alt : Icons.person,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record?.name ?? 'No worker selected',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      record == null
                          ? 'Tap to enrol before you start training'
                          : '${record.workerRef} · ${record.employerCode}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (record != null && record.isNewJoiner)
                const Tooltip(
                  message: 'First 30 days on site',
                  child: Icon(Icons.fiber_new, color: AppTheme.cautionAmber),
                )
              else
                const Icon(Icons.swap_horiz),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBadge extends ConsumerWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pending = ref.watch(pendingSyncProvider).maybeWhen(
          data: (count) => count,
          orElse: () => 0,
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.safeGreen.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.safeGreen.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 20, color: AppTheme.safeGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              pending == 0
                  ? 'Works with no internet. Nothing leaves this phone.'
                  : 'Works with no internet. $pending record'
                      '${pending == 1 ? '' : 's'} waiting to sync.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.safeGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Makes it impossible to mistake a demo build for a deployment.
///
/// The development trust root is public, so certificates it signs prove
/// nothing to anyone outside a demo. Saying so on the home screen is the
/// honest place for it.
class _DevelopmentRootNotice extends StatelessWidget {
  const _DevelopmentRootNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.cautionAmber.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cautionAmber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 20, color: AppTheme.cautionAmber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Demonstration build — signing with a development trust root. '
              'Certificates are not statutory records.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.cautionAmber,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({required this.module, required this.onTap});

  final TrainingModule module;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = L.of(context);
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: module.accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(module.icon, color: module.accent, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      module.title(l10n),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      module.summary(l10n),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _Chip(
                          icon: Icons.schedule,
                          label: '${module.estimatedMinutes} min',
                        ),
                        const SizedBox(width: 8),
                        _Chip(
                          icon: Icons.layers_outlined,
                          label: module.actCount == 1
                              ? '1 act'
                              : '${module.actCount} acts',
                        ),
                        if (module.depth == ModuleDepth.introductory) ...[
                          const SizedBox(width: 8),
                          const _Chip(icon: Icons.info_outline, label: 'Intro'),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
