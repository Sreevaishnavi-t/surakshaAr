import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ar/anchor/barcode_scanner_service.dart';
import '../../ar/camera/ar_camera_view.dart';
import '../../certificate/certificate.dart';
import '../../certificate/certificate_codec.dart';
import '../../core/services.dart';
import '../../core/theme/app_theme.dart';
import '../../modules/catalogue.dart';

/// Scans and verifies a certificate QR, entirely offline.
///
/// This is the screen that answers the problem statement's complaint that
/// "physical certificates have no mechanism to verify comprehension". A safety
/// officer or DGMS inspector installs the APK, points it at a worker's code and
/// gets a definite answer — no account, no network, no prior contact with the
/// site that issued it, because the organisation's public key is compiled in.
class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key});

  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  // The scanner is the only consumer of camera frames, so it is the only place
  // that needs an NV21 analysis pipeline.
  final ArCameraController _camera = ArCameraController(forImageStream: true);
  final BarcodeScannerService _scanner = BarcodeScannerService();

  VerificationResult? _result;
  bool _streaming = false;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_camera);
    _camera.addListener(_onCameraChanged);
    unawaited(_start());
  }

  Future<void> _start() async {
    await _camera.initialise();
    if (!mounted) return;
    await _beginStream();
  }

  Future<void> _beginStream() async {
    final controller = _camera.controller;
    final description = _camera.description;
    if (controller == null || description == null || _streaming) return;

    _streaming = true;
    await controller.startImageStream((image) async {
      if (_verifying || _result != null) return;

      final barcodes = await _scanner.process(
        image: image,
        camera: description,
        // The activity is portrait-locked, so the display is always at its
        // natural rotation.
        deviceOrientationDegrees: 0,
      );

      for (final barcode in barcodes) {
        final value = barcode.rawValue;
        if (value == null) continue;
        // Ignore AR anchor markers — the same detector sees both.
        if (value.startsWith(kMarkerPrefix)) continue;
        await _verify(value);
        break;
      }
    });
  }

  Future<void> _verify(String qrData) async {
    if (_verifying) return;
    _verifying = true;

    try {
      final services = ref.read(servicesProvider);
      final result = await services.codec.verify(
        qrData: qrData,
        keys: await services.keyResolver(),
      );

      if (!mounted) return;
      setState(() => _result = result);
      await _stopStream();
    } finally {
      _verifying = false;
    }
  }

  Future<void> _stopStream() async {
    final controller = _camera.controller;
    if (controller != null && _streaming) {
      _streaming = false;
      try {
        await controller.stopImageStream();
      } catch (_) {
        // Already stopped, or the controller was torn down by a lifecycle
        // change. Either way there is nothing to recover.
      }
    }
  }

  void _onCameraChanged() {
    if (!mounted) return;
    setState(() {});
    if (_camera.controller != null && !_streaming && _result == null) {
      unawaited(_beginStream());
    }
  }

  Future<void> _scanAgain() async {
    setState(() => _result = null);
    await _beginStream();
  }

  @override
  void dispose() {
    _camera.removeListener(_onCameraChanged);
    WidgetsBinding.instance.removeObserver(_camera);
    unawaited(_stopStream());
    unawaited(_scanner.close());
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return Scaffold(
      backgroundColor: AppTheme.surfaceDark,
      appBar: AppBar(
        title: const Text('Verify a certificate'),
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: result == null ? _buildScanner() : _buildResult(result),
    );
  }

  Widget _buildScanner() {
    if (_camera.failure != null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'The camera is needed to scan a certificate code. Allow camera '
            'access and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.4),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ArCameraPreview(controller: _camera),
        const _ScanReticle(),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 40,
          child: Text(
            'Point the camera at the QR code on the worker\'s certificate.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              height: 1.4,
              shadows: [Shadow(blurRadius: 8, color: Colors.black)],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResult(VerificationResult result) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            switch (result) {
              VerificationValid() => _ValidPanel(result: result),
              VerificationExpired() => _ExpiredPanel(result: result),
              VerificationInvalid() => _FailurePanel(
                  icon: Icons.gpp_bad_outlined,
                  colour: AppTheme.hazardRed,
                  title: 'Not valid',
                  body: result.reason,
                ),
              VerificationUnknownKey() => _FailurePanel(
                  icon: Icons.help_outline,
                  colour: AppTheme.cautionAmber,
                  title: 'Cannot check this certificate',
                  body: 'This certificate was signed by a device this phone '
                      'does not know (${result.keyId}).\n\nIt is not '
                      'necessarily false — it may simply not have been '
                      'counter-signed by the training centre yet. Ask the '
                      'worker to sync their phone, then scan again.',
                ),
              VerificationMalformed() => _FailurePanel(
                  icon: Icons.qr_code_scanner,
                  colour: AppTheme.cautionAmber,
                  title: 'Could not read this code',
                  body: result.reason,
                ),
            },
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _scanAgain,
              child: const Text('Scan another'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanReticle extends StatelessWidget {
  const _ScanReticle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 240,
        height: 240,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white70, width: 3),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

class _ValidPanel extends StatelessWidget {
  const _ValidPanel({required this.result});

  final VerificationValid result;

  @override
  Widget build(BuildContext context) {
    final certificate = result.certificate;
    final provisional = result.isProvisional;
    final colour = provisional ? AppTheme.cautionAmber : AppTheme.safeGreen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          provisional ? Icons.verified_outlined : Icons.verified,
          size: 72,
          color: colour,
        ),
        const SizedBox(height: 14),
        Text(
          provisional ? 'Valid — provisional' : 'Valid certificate',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colour,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (provisional) ...[
          const SizedBox(height: 8),
          const Text(
            'Signed by the worker\'s own phone, not yet counter-signed by the '
            'training centre.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.35),
          ),
        ],
        const SizedBox(height: 22),
        _CertificateSummary(certificate: certificate),
      ],
    );
  }
}

class _ExpiredPanel extends StatelessWidget {
  const _ExpiredPanel({required this.result});

  final VerificationExpired result;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.event_busy, size: 72, color: AppTheme.cautionAmber),
        const SizedBox(height: 14),
        const Text(
          'Genuine but expired',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.cautionAmber,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'The signature is good, but this certificate lapsed '
          '${result.overdueBy.inDays} days ago. The worker needs refresher '
          'training before returning to this work.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 22),
        _CertificateSummary(certificate: result.certificate),
      ],
    );
  }
}

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.icon,
    required this.colour,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color colour;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 72, color: colour),
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colour,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 15,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _CertificateSummary extends StatelessWidget {
  const _CertificateSummary({required this.certificate});

  final WorkerCertificate certificate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceDarkElevated,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            certificate.workerName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${certificate.workerRef}  ·  ${certificate.employerCode}',
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const Divider(height: 26, color: Colors.white24),
          for (final attainment in certificate.modules)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    moduleFor(attainment.domain).icon,
                    size: 18,
                    color: moduleFor(attainment.domain).accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      attainment.domain.name,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                  Text(
                    '${attainment.score}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
