import 'package:flutter/material.dart';

import '../../../ar/pose/pose_service.dart';
import '../../../core/theme/app_theme.dart';

/// Shown while capabilities, camera and sensors are being brought up.
class SessionLoadingGate extends StatelessWidget {
  const SessionLoadingGate({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text(
            'Checking your phone',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

/// Camera permission was refused.
///
/// Explains the trade in the worker's terms — what the camera is for and what
/// happens to the footage — rather than restating an Android error. "Nothing is
/// recorded" is the sentence that actually unblocks people.
class SessionCameraGate extends StatelessWidget {
  const SessionCameraGate({
    super.key,
    required this.onRetry,
    required this.onExit,
  });

  final VoidCallback onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return _GatePanel(
      icon: Icons.photo_camera_outlined,
      accent: AppTheme.cautionAmber,
      title: 'Camera access is needed',
      body: 'The drill places hazards in the space around you, so it needs to '
          'see through the camera.\n\n'
          'Nothing is recorded, nothing is saved, and nothing is sent anywhere. '
          'The picture is only used to draw on while you train.',
      primaryLabel: 'Allow camera',
      onPrimary: onRetry,
      secondaryLabel: 'Go back',
      onSecondary: onExit,
    );
  }
}

/// No usable camera at all.
class SessionUnsupportedGate extends StatelessWidget {
  const SessionUnsupportedGate({super.key, required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return _GatePanel(
      icon: Icons.no_photography_outlined,
      accent: AppTheme.hazardRed,
      title: 'Camera not available',
      body: 'This phone did not give us a working camera, so the AR drill '
          'cannot run.\n\n'
          'You can still take the written assessment for this module and be '
          'certified. Ask your supervisor to open assessment-only mode.',
      primaryLabel: 'Go back',
      onPrimary: onExit,
    );
  }
}

/// Origins the scene on the worker's current heading before the act begins.
///
/// Also the right moment to be honest about tracking quality: a phone that will
/// rely on the magnetometer should say so *before* the drill, not drift halfway
/// through and leave the worker thinking they did something wrong.
class SessionCalibrationGate extends StatelessWidget {
  const SessionCalibrationGate({
    super.key,
    required this.capabilities,
    required this.intrinsicsAreMeasured,
    required this.onBegin,
    required this.onExit,
  });

  final PoseCapabilities capabilities;
  final bool intrinsicsAreMeasured;
  final VoidCallback onBegin;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final warnings = <String>[
      if (!capabilities.supportsWorldLocking)
        'This phone has no motion sensor, so the scene cannot stay locked to '
            'your surroundings. The drill still works, and still counts.',
      if (capabilities.isMagnetometerDependent)
        'This phone tracks using its compass. Near heavy machinery or '
            'underground, the view may drift.',
      if (!intrinsicsAreMeasured)
        'We could not read this camera\'s lens details. If things look '
            'misaligned, use the Fit slider at the bottom.',
    ];

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.threesixty,
                size: 56,
                color: AppTheme.infoBlue,
              ),
              const SizedBox(height: 18),
              const Text(
                'Face your work area',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Stand where you have room to turn around. Hold the phone up '
                'like a window and look towards open space, then start.\n\n'
                'During the drill you will need to turn your body to look '
                'around you.',
                style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.45),
              ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 18),
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 18,
                          color: AppTheme.cautionAmber,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            warning,
                            style: const TextStyle(
                              color: AppTheme.cautionAmber,
                              fontSize: 13.5,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onBegin,
                  child: const Text('Begin drill'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: onExit,
                  child: const Text('Go back'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GatePanel extends StatelessWidget {
  const _GatePanel({
    required this.icon,
    required this.accent,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 60, color: accent),
              const SizedBox(height: 20),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                body,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onPrimary,
                  child: Text(primaryLabel),
                ),
              ),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
