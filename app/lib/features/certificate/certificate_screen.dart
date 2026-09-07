import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../certificate/certificate.dart';
import '../../core/theme/app_theme.dart';
import '../../modules/catalogue.dart';

/// Displays a worker's certificate as a scannable QR plus a plain-language
/// summary.
///
/// The QR *is* the certificate. Everything a verifier needs is inside it, so a
/// screenshot on a cracked handset, or this screen printed onto paper and
/// pinned in a site office, both remain fully verifiable with no network.
class CertificateScreen extends StatelessWidget {
  const CertificateScreen({
    super.key,
    required this.certificate,
    required this.qrPayload,
  });

  final WorkerCertificate certificate;
  final String qrPayload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Safety certificate'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy certificate code',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: qrPayload));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Certificate code copied')),
                );
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TrustBanner(tier: certificate.trustTier),
            const SizedBox(height: 18),

            // White ground regardless of theme: QR contrast is not a styling
            // preference, and a dark-mode inversion is unreadable to many
            // scanners.
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: qrPayload,
                  version: QrVersions.auto,
                  size: 260,
                  backgroundColor: Colors.white,
                  // Medium error correction: enough to survive a scuffed
                  // printout or a cracked screen without inflating the symbol.
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),

            const SizedBox(height: 22),
            Text(
              certificate.workerName,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${certificate.workerRef}  ·  ${certificate.employerCode}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 24),
            Text('Certified domains', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            for (final attainment in certificate.modules)
              _AttainmentRow(attainment: attainment),

            const SizedBox(height: 20),
            _MetaTable(certificate: certificate),
          ],
        ),
      ),
    );
  }
}

/// States plainly how far this certificate can be trusted.
///
/// A provisional certificate is genuine but signed only by the handset that
/// issued it. Presenting that with the same weight as a counter-signed one
/// would misrepresent what has actually been checked, so the difference is
/// stated in words rather than implied by a colour.
class _TrustBanner extends StatelessWidget {
  const _TrustBanner({required this.tier});

  final TrustTier tier;

  @override
  Widget build(BuildContext context) {
    final verified = tier == TrustTier.verified;
    final signal = verified ? SafetySignal.safe : SafetySignal.caution;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: signal.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: signal.color.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(signal.icon, color: signal.color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verified ? 'Verified certificate' : 'Provisional certificate',
                  style: TextStyle(
                    color: signal.color,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  verified
                      ? 'Counter-signed by the training centre. Anyone with the '
                          'SurakshaAR app can check this, with no internet.'
                      : 'Signed by this phone and valid on this site. Sync with '
                          'the training centre to have it counter-signed so that '
                          'any inspector can verify it.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttainmentRow extends StatelessWidget {
  const _AttainmentRow({required this.attainment});

  final ModuleAttainment attainment;

  @override
  Widget build(BuildContext context) {
    final module = moduleFor(attainment.domain);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: module.accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(module.icon, color: module.accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              _domainLabel(attainment.domain),
              style: theme.textTheme.bodyLarge,
            ),
          ),
          Text(
            '${attainment.score}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: attainment.score >= 80
                  ? AppTheme.safeGreen
                  : AppTheme.cautionAmber,
            ),
          ),
        ],
      ),
    );
  }

  static String _domainLabel(SafetyDomain domain) => switch (domain) {
        SafetyDomain.fire => 'Fire & Explosion Response',
        SafetyDomain.gas => 'Gas Leak & Confined Space',
        SafetyDomain.machinery => 'Machinery & Lockout-Tagout',
        SafetyDomain.strata => 'Roof Fall & Working at Height',
        SafetyDomain.electrical => 'Electrical Hazards & First Aid',
      };
}

class _MetaTable extends StatelessWidget {
  const _MetaTable({required this.certificate});

  final WorkerCertificate certificate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiring = certificate.expiresAt
            .difference(DateTime.now().toUtc())
            .inDays <
        30;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _row(context, 'Issued', _formatDate(certificate.issuedAt)),
          _row(
            context,
            'Valid until',
            _formatDate(certificate.expiresAt),
            highlight: expiring,
          ),
          _row(
            context,
            'Overall score',
            certificate.overallScore.round().toString(),
          ),
          _row(context, 'Signed by', certificate.keyId),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool highlight = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: highlight ? AppTheme.cautionAmber : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime value) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}
