import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion;

import '../../ar/camera/ar_camera_view.dart';
import '../../ar/fx/fire_fx.dart';
import '../../ar/pose/device_pose.dart';
import '../../ar/pose/pose_service.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/ar_renderer.dart';
import '../../ar/session/ar_frame_notifier.dart';
import '../../core/theme/app_theme.dart';
import '../../modules/catalogue.dart';
import '../../modules/engine/scenario.dart';
import '../../modules/m1_fire/fire_act1_exit.dart';
import 'widgets/scenario_hud.dart';
import 'widgets/session_gates.dart';

/// Where the session currently is.
enum _SessionPhase { preparing, needsCamera, unsupported, calibrating, running, finished }

/// Hosts one AR act: camera passthrough, pose tracking, scene rendering and the
/// scenario's own step logic.
///
/// Deliberately knows nothing about fire or gas. It pumps the scenario once per
/// frame, forwards taps, and renders whatever the scenario currently exposes.
class ArSessionScreen extends StatefulWidget {
  const ArSessionScreen({super.key, required this.domain});

  final SafetyDomain domain;

  @override
  State<ArSessionScreen> createState() => _ArSessionScreenState();
}

class _ArSessionScreenState extends State<ArSessionScreen>
    with TickerProviderStateMixin {
  final PoseService _poseService = PoseService();
  final ArCameraController _cameraController = ArCameraController();

  late final ArFrameNotifier _frames;
  late final ArScenario _scenario;

  ArCameraIntrinsics _intrinsics = ArCameraIntrinsics.fallback;
  PoseCapabilities _capabilities = PoseCapabilities.unknown;
  _SessionPhase _phase = _SessionPhase.preparing;

  /// Scene rotation captured at calibration, so content appears in front of
  /// whichever way the worker happens to be facing when they start.
  Quaternion? _worldFromScene;

  double _calibrationScale = 1.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_cameraController);
    _frames = ArFrameNotifier(poseService: _poseService, vsync: this);
    _scenario = _createScenario(widget.domain);
    _cameraController.addListener(_onCameraChanged);
    _prepare();
  }

  ArScenario _createScenario(SafetyDomain domain) {
    // Phase 1 ships Fire Act 1. The remaining acts slot in here as they land,
    // and the screen itself needs no changes to host them.
    return switch (domain) {
      SafetyDomain.fire => FireAct1ExitScenario(),
      _ => FireAct1ExitScenario(),
    };
  }

  Future<void> _prepare() async {
    final capabilities = await _poseService.capabilities();
    final intrinsics = await _poseService.cameraIntrinsics();
    if (!mounted) return;

    setState(() {
      _capabilities = capabilities;
      _intrinsics = intrinsics;
    });

    await _cameraController.initialise();
    if (!mounted) return;

    await _frames.start();
    if (!mounted) return;

    setState(() {
      if (_cameraController.failure == CameraFailure.permissionDenied) {
        _phase = _SessionPhase.needsCamera;
      } else if (_cameraController.failure != null) {
        _phase = _SessionPhase.unsupported;
      } else {
        _phase = _SessionPhase.calibrating;
      }
    });
  }

  void _onCameraChanged() {
    if (mounted) setState(() {});
  }

  /// Pins the scenario's authoring "forward" to the worker's current heading.
  void _calibrate() {
    setState(() {
      _worldFromScene = ArCamera.calibrationFromYaw(_frames.pose.yaw);
      _phase = _SessionPhase.running;
    });
  }

  ArCamera _cameraFor(Size viewportSize, DevicePose pose) {
    return ArCamera(
      pose: pose,
      intrinsics: _intrinsics,
      previewSize: _cameraController.displayPreviewSize ?? viewportSize,
      viewportSize: viewportSize,
      worldFromScene: _worldFromScene,
      calibrationScale: _calibrationScale,
    );
  }

  void _onScenarioFinished() {
    if (_phase == _SessionPhase.finished) return;
    _frames.pause();
    setState(() => _phase = _SessionPhase.finished);
  }

  @override
  void dispose() {
    _cameraController.removeListener(_onCameraChanged);
    WidgetsBinding.instance.removeObserver(_cameraController);
    _frames.dispose();
    _cameraController.dispose();
    _scenario.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.surfaceDark,
      body: switch (_phase) {
        _SessionPhase.preparing => const SessionLoadingGate(),
        _SessionPhase.needsCamera => SessionCameraGate(
            onRetry: () {
              setState(() => _phase = _SessionPhase.preparing);
              _prepare();
            },
            onExit: () => Navigator.of(context).maybePop(),
          ),
        _SessionPhase.unsupported => SessionUnsupportedGate(
            onExit: () => Navigator.of(context).maybePop(),
          ),
        _ => _buildArStack(),
      },
    );
  }

  Widget _buildArStack() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);

        return Stack(
          fit: StackFit.expand,
          children: [
            ArCameraPreview(controller: _cameraController),

            // One AnimatedBuilder around everything pose-driven, so a frame
            // rebuilds this subtree only — not the gates, not the scaffold.
            AnimatedBuilder(
              animation: _frames,
              builder: (context, _) {
                final pose = _frames.pose;
                final camera = _cameraFor(viewport, pose);

                if (_phase == _SessionPhase.running && !_scenario.isFinished) {
                  _scenario.update(_frames.elapsed, camera);
                  if (_scenario.isFinished) {
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _onScenarioFinished(),
                    );
                  }
                }

                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ArSceneView(
                      camera: camera,
                      nodes: _scenario.nodes,
                      elapsed: _frames.elapsed,
                      onNodeTap: _phase == _SessionPhase.running
                          ? _scenario.handleTap
                          : null,
                      onEmptyTap: _phase == _SessionPhase.running
                          ? (_) => _scenario.handleEmptyTap()
                          : null,
                    ),

                    // Haze sits above the scene: it is the worker's own loss of
                    // visibility, not an object at some depth in the world.
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: SmokeHazePainter(
                          density: _phase == _SessionPhase.running
                              ? _scenario.hazeDensity
                              : 0,
                          seconds: _frames.elapsed.inMilliseconds / 1000.0,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),

            if (_phase == _SessionPhase.calibrating)
              SessionCalibrationGate(
                capabilities: _capabilities,
                intrinsicsAreMeasured: _intrinsics.isMeasured,
                onBegin: _calibrate,
                onExit: () => Navigator.of(context).maybePop(),
              ),

            if (_phase == _SessionPhase.running)
              AnimatedBuilder(
                animation: _scenario,
                builder: (context, _) => ScenarioHud(
                  prompt: _scenario.prompt,
                  poseSource: _frames.pose.source,
                  hasPose: _frames.hasPose,
                  onExit: _confirmExit,
                ),
              ),

            if (_phase == _SessionPhase.finished && _scenario.result != null)
              ScenarioResultSheet(
                result: _scenario.result!,
                // Hand the result back so the module screen can record it.
                // Every attempt is kept, passes and failures alike.
                onDone: () => Navigator.of(context).pop(_scenario.result),
              ),

            if (!_intrinsics.isMeasured && _phase == _SessionPhase.running)
              Positioned(
                left: 16,
                right: 16,
                bottom: 12,
                child: CalibrationSlider(
                  value: _calibrationScale,
                  onChanged: (v) => setState(() => _calibrationScale = v),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _confirmExit() async {
    _frames.pause();
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this drill?'),
        content: const Text(
          'Your progress in this drill will not be counted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (leave ?? false) {
      _scenario.abandon();
      if (mounted) Navigator.of(context).pop(_scenario.result);
    } else {
      _frames.resume(_frames.elapsed);
    }
  }
}
