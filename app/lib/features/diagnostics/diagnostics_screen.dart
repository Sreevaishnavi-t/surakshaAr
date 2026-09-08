import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ar/camera/ar_camera_view.dart';
import '../../ar/pose/pose_service.dart';
import '../../ar/scene/ar_camera.dart';
import '../../core/diagnostics.dart';
import '../../core/exit_reasons.dart';
import '../../core/services.dart';
import '../../core/theme/app_theme.dart';
import '../../data/device_identity.dart';

/// Shows what the app can actually see of this device, plus the breadcrumb
/// trail from the previous run.
///
/// Exists because the deployment target is a contract worker's phone in a
/// district with no developer nearby. When something fails there, nobody is
/// going to attach a debugger — so the app has to be able to explain itself
/// from its own screen, and the report has to be copyable in one tap.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  PoseCapabilities? _capabilities;
  ArCameraIntrinsics? _intrinsics;
  String? _cameraProbe;
  List<ProcessExit> _exits = const [];
  bool _probing = true;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  /// Exercises the same platform calls the AR session makes, so a failure shows
  /// up here instead of as an unexplained crash on the drill screen.
  Future<void> _probe() async {
    final poseService = PoseService();

    PoseCapabilities? capabilities;
    ArCameraIntrinsics? intrinsics;
    String cameraProbe;

    try {
      capabilities = await poseService.capabilities();
    } catch (e) {
      Diagnostics.instance.record('diag.capabilities failed: $e');
    }

    try {
      intrinsics = await poseService.cameraIntrinsics();
    } catch (e) {
      Diagnostics.instance.record('diag.intrinsics failed: $e');
    }

    // Android's own record of why previous processes died. Ground truth, and
    // the reason this screen exists rather than a logcat session.
    final exits = await ExitReasonService().recent();

    final controller = ArCameraController();
    try {
      await controller.initialise();
      cameraProbe = controller.failure != null
          ? 'FAILED: ${controller.failure}'
          : 'ok, preview ${controller.displayPreviewSize}';
    } catch (e) {
      cameraProbe = 'THREW: $e';
      Diagnostics.instance.record('diag.camera failed: $e');
    } finally {
      controller.dispose();
    }

    if (!mounted) return;
    setState(() {
      _capabilities = capabilities;
      _intrinsics = intrinsics;
      _cameraProbe = cameraProbe;
      _exits = exits;
      _probing = false;
    });
  }

  Map<String, Object?> get _environment {
    final services = ref.read(servicesProvider);
    final capabilities = _capabilities;
    final intrinsics = _intrinsics;

    return {
      'appVersion': '0.1.0',
      'deviceKeyId': services.identity.keyId,
      'orgKeyId': OrganisationKey.keyId,
      'developmentRoot': OrganisationKey.isDevelopmentRoot,
      'camera': _cameraProbe ?? 'not probed',
      'gameRotationVector': capabilities?.hasGameRotationVector,
      'rotationVector': capabilities?.hasRotationVector,
      'gyroscope': capabilities?.hasGyroscope,
      'accelerometer': capabilities?.hasAccelerometer,
      'magnetometer': capabilities?.hasMagnetometer,
      'worldLocking': capabilities?.supportsWorldLocking,
      'intrinsicsMeasured': intrinsics?.isMeasured,
      'focalLengthMm': intrinsics?.focalLengthMm,
      'horizontalFovDeg': intrinsics == null
          ? null
          : (intrinsics.horizontalFovRad * 180 / 3.14159265).toStringAsFixed(1),
    };
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = Diagnostics.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy full report',
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(
                  text: diagnostics.asReport(environment: _environment),
                ),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Report copied to clipboard')),
                );
              }
            },
          ),
        ],
      ),
      body: _probing
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const _SectionHeader('Device capability'),
                for (final entry in _environment.entries)
                  _KeyValueRow(label: entry.key, value: '${entry.value}'),

                if (_exits.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionHeader('Why the app closed last time'),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      "Recorded by Android itself, not by this app. This is the "
                      'part a breadcrumb trail cannot tell you.',
                      style: TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                  for (final exit in _exits.take(4)) _ExitCard(exit: exit),
                ],

                if (diagnostics.previousRun.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const _SectionHeader('Previous run'),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'The last thing the app did before it closed. If it '
                      'crashed, the fault is at or just after the final line.',
                      style: TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                  _LogBlock(
                    lines: diagnostics.previousRun,
                    accent: AppTheme.cautionAmber,
                  ),
                ],

                const SizedBox(height: 20),
                const _SectionHeader('This run'),
                _LogBlock(lines: diagnostics.entries),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final looksWrong = value == 'false' ||
        value == 'null' ||
        value.startsWith('FAILED') ||
        value.startsWith('THREW');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: looksWrong ? AppTheme.cautionAmber : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogBlock extends StatelessWidget {
  const _LogBlock({required this.lines, this.accent});

  final List<String> lines;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (lines.isEmpty) {
      return Text(
        'Nothing recorded.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: accent == null
            ? null
            : Border.all(color: accent!.withValues(alpha: 0.5)),
      ),
      child: SelectableText(
        lines.join('\n'),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          height: 1.45,
        ),
      ),
    );
  }
}

/// One recorded process death, as Android described it.
class _ExitCard extends StatelessWidget {
  const _ExitCard({required this.exit});

  final ProcessExit exit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serious = !exit.isBenign;
    final accent = serious ? AppTheme.hazardRed : theme.colorScheme.outline;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                serious ? Icons.report_problem_outlined : Icons.check_circle_outline,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  exit.reason,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${exit.when.toIso8601String().substring(0, 19)}  ·  '
            '${exit.memorySummary}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          ),
          if (exit.description != null && exit.description!.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              exit.description!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
          ],
          // What this exit means for the bug being chased, in plain words.
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              verdictFor(exit),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ),
          if (exit.trace != null && exit.trace!.isNotEmpty) ...[
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: const Text('Tombstone / trace', style: TextStyle(fontSize: 13)),
              children: [
                SelectableText(
                  exit.trace!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Turns a recorded process death into a one-line verdict a non-specialist can
/// act on — the difference between "Android ran out of memory and killed us"
/// and "our own native code took a fatal signal" decides where to look next,
/// and the raw reason code says neither.
///
/// TODO(human): implement this.
///
/// Return a short sentence for each case that matters:
///   - exit.isLowMemory  -> the kernel reclaimed us; point at exit.memorySummary
///                          and say the fix is to allocate less, not to catch
///                          anything. Note that PSS above roughly 400 MB on a
///                          mid-range handset is already the answer.
///   - exit.isNativeCrash -> a fatal signal in native code. Say the tombstone
///                          below names the faulting library, and that this
///                          rules out every Dart-level explanation.
///   - exit.isAnr        -> the main thread blocked past the watchdog. Point at
///                          the trace for what it was blocked on.
///   - exit.isBenign     -> the user closed it; nothing to investigate.
///   - anything else     -> say plainly that it is not yet diagnosable and the
///                          tombstone, if present, is the next thing to read.
///
/// Keep it to one or two sentences per case: this renders on a phone, and it is
/// read by whoever is holding it rather than by someone with a debugger.
String verdictFor(ProcessExit exit) {
  return '';
}
