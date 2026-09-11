import 'package:flutter/material.dart';

import '../../../ar/environment/camera_height.dart';
import '../../../ar/environment/environment_map.dart';
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
    required this.environment,
    required this.bodyHeightMetres,
    required this.hold,
    required this.onHeightChanged,
    required this.onBegin,
    required this.onExit,
  });

  final PoseCapabilities capabilities;
  final bool intrinsicsAreMeasured;

  /// Live room map, so the sweep shows the worker what it is actually finding
  /// rather than an indeterminate spinner.
  final EnvironmentMap environment;

  /// The worker's stated stature, and how they say they hold the phone.
  final double bodyHeightMetres;
  final PhoneHold hold;

  final void Function(double bodyHeightMetres, PhoneHold hold) onHeightChanged;

  final VoidCallback onBegin;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    // Rebuilds as the map fills, so progress is honest and visible.
    return ListenableBuilder(
      listenable: environment,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final coverage = environment.coverage;
    final doors = environment.doors;
    final ready = environment.isUsable;

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
              Icon(
                ready ? Icons.check_circle_outline : Icons.threesixty,
                size: 56,
                color: ready ? AppTheme.safeGreen : AppTheme.infoBlue,
              ),
              const SizedBox(height: 18),
              Text(
                ready ? 'Ready' : 'Look around your workplace',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                ready
                    ? 'The drill will use the real space around you. The doors '
                        'and clear floor found here are where things will '
                        'appear.'
                    : 'Stand where you have room to turn. Hold the phone up '
                        'like a window and turn slowly on the spot, so the app '
                        'can see the floor and find the doors around you.',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              _HeightControl(
                bodyHeightMetres: bodyHeightMetres,
                hold: hold,
                onChanged: onHeightChanged,
              ),
              const SizedBox(height: 18),
              _ScanProgress(coverage: coverage, doorsFound: doors.length),
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

/// Live feedback during the room scan.
///
/// Shows what has actually been found rather than a spinner. That matters for
/// trust as much as for usability: a worker who can see the app counting real
/// doors around them understands that the drill is about their workplace, and a
/// worker who sees zero doors found learns something true about the limits of
/// what the app can see before the drill starts rather than during it.
class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.coverage, required this.doorsFound});

  final double coverage;
  final int doorsFound;

  @override
  Widget build(BuildContext context) {
    // Full marks at a third of the circle — the sweep a worker makes without
    // moving their feet, and enough to place content in front of them.
    final progress = (coverage / 0.33).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation(
              progress >= 1 ? AppTheme.safeGreen : AppTheme.infoBlue,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Icon(Icons.door_front_door_outlined,
                size: 18, color: Colors.white70),
            const SizedBox(width: 8),
            Text(
              switch (doorsFound) {
                0 => 'No doorways found yet',
                1 => '1 doorway found',
                _ => '$doorsFound doorways found',
              },
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ],
    );
  }
}

/// Asks how tall the worker is and how they hold the phone.
///
/// This looks like a small courtesy and is not. The camera's height above the
/// floor is the only unknown in the ground plane — gravity fixes the other
/// three numbers for free — so it sets the scale of everything the engine
/// measures: where content stands, how far away the tunnel wall is, and how
/// wide a detected doorway comes out in metres. Guessing it wrong by 20 cm
/// pushes content through the floor and makes real doors measure out of range.
class _HeightControl extends StatelessWidget {
  const _HeightControl({
    required this.bodyHeightMetres,
    required this.hold,
    required this.onChanged,
  });

  final double bodyHeightMetres;
  final PhoneHold hold;
  final void Function(double bodyHeightMetres, PhoneHold hold) onChanged;

  @override
  Widget build(BuildContext context) {
    final ground = CameraHeight.forWorker(
      bodyHeightMetres: bodyHeightMetres,
      hold: hold,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.straighten, size: 18, color: Colors.white70),
              const SizedBox(width: 10),
              const Text(
                'Your height',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${(bodyHeightMetres * 100).round()} cm',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          Slider(
            value: bodyHeightMetres.clamp(
              CameraHeight.minBodyHeightMetres,
              CameraHeight.maxBodyHeightMetres,
            ),
            min: CameraHeight.minBodyHeightMetres,
            max: CameraHeight.maxBodyHeightMetres,
            // One notch per centimetre: finer than anyone can state their own
            // height, and coarse enough to land on a round number.
            divisions:
                ((CameraHeight.maxBodyHeightMetres -
                            CameraHeight.minBodyHeightMetres) *
                        100)
                    .round(),
            onChanged: (value) => onChanged(value, hold),
          ),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<PhoneHold>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(
                      value: PhoneHold.atEyeLevel,
                      label: Text('Up at eye level'),
                    ),
                    ButtonSegment(
                      value: PhoneHold.atChestLevel,
                      label: Text('At chest'),
                    ),
                  ],
                  selected: {hold},
                  onSelectionChanged: (selection) =>
                      onChanged(bodyHeightMetres, selection.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Camera about ${ground.cameraHeightMetres.toStringAsFixed(2)} m '
            'above the floor.',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
