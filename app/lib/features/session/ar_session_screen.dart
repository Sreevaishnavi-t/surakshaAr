import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Quaternion;

import '../../ar/camera/ar_camera_view.dart';
import '../../ar/fx/fire_fx.dart';
import '../../ar/pose/device_pose.dart';
import '../../ar/pose/pose_service.dart';
import '../../ar/scene/ar_camera.dart';
import '../../ar/scene/scene_graph.dart';
import '../../ar/scene/ar_renderer.dart';
import '../../ar/session/ar_frame_notifier.dart';
import '../../ar/environment/environment_map.dart';
import '../../ar/world/gallery_layout.dart';
import '../../ar/world/gallery_nodes.dart';
import '../../ar/environment/scene_scanner.dart';
import '../../core/diagnostics.dart';
import '../../core/theme/app_theme.dart';
import '../../modules/catalogue.dart';
import '../../modules/act_registry.dart';
import '../../modules/engine/scenario.dart';
import 'widgets/scenario_hud.dart';
import 'widgets/session_gates.dart';

/// Where the session currently is.
enum _SessionPhase {
  preparing,
  needsCamera,
  unsupported,

  /// Sweeping the phone across the space so the room can be mapped.
  ///
  /// Replaces what used to be a bare "face this way and tap Begin". That gave
  /// the engine a heading and nothing else, which is why content could only
  /// ever be placed at invented bearings. The sweep captures the heading *and*
  /// the room in one gesture the worker has to make anyway.
  scanning,
  running,
  finished,
}

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
  final ArCameraController _cameraController =
      ArCameraController(forImageStream: true);

  /// What the app has worked out about the room, built during the scan sweep.
  final EnvironmentMap _environment = EnvironmentMap();
  late final SceneScanner _scanner = SceneScanner(map: _environment);

  /// The simulated gallery the drill takes place inside.
  ///
  /// Held by the session rather than by each scenario, because every module
  /// happens underground and none of them should have to rebuild a tunnel. The
  /// scenario contributes what is *happening*; this is where it happens.
  GalleryLayout? _gallery;
  List<SceneNode> _galleryNodes = const [];

  late final ArFrameNotifier _frames;

  /// The acts making up this module, and where we are in them.
  late final List<ArScenario Function()> _actFactories;
  final List<ScenarioResult> _completedActs = [];
  late ArScenario _scenario;
  int _actIndex = 0;

  ArCameraIntrinsics _intrinsics = ArCameraIntrinsics.fallback;
  PoseCapabilities _capabilities = PoseCapabilities.unknown;
  _SessionPhase _phase = _SessionPhase.preparing;

  /// Scene rotation captured at calibration, so content appears in front of
  /// whichever way the worker happens to be facing when they start.
  Quaternion? _worldFromScene;

  double _calibrationScale = 1.0;

  /// Draw the camera only, with no scene layer.
  ///
  /// A diagnostic bisect, not a feature: it separates "the renderer kills the
  /// process" from "the camera or platform below it does", which is otherwise
  /// impossible to tell apart from a device with no debugger attached.
  bool _safeMode = false;

  /// Latest laid-out viewport, captured so [_pumpScenario] can construct a
  /// camera outside of build.
  Size? _lastViewport;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_cameraController);
    _frames = ArFrameNotifier(poseService: _poseService, vsync: this);
    _actFactories = ActRegistry.actsFor(widget.domain);
    _scenario = _actFactories.first();
    _cameraController.addListener(_onCameraChanged);
    // Advancing the scenario from the ticker rather than from build(). Doing it
    // inside build() meant update() -> notifyListeners() marked the HUD's
    // AnimatedBuilder dirty *during* a build, which trips a framework assert in
    // debug and leaves the tree in an inconsistent state in release.
    _frames.addListener(_pumpScenario);
    _prepare();
  }

  Future<void> _prepare() async {
    final diagnostics = Diagnostics.instance;
    diagnostics.breadcrumb('ar.prepare.begin domain=${widget.domain.name}');

    final capabilities = await _poseService.capabilities();
    diagnostics.breadcrumb(
      'ar.capabilities game=${capabilities.hasGameRotationVector} '
      'rot=${capabilities.hasRotationVector} '
      'gyro=${capabilities.hasGyroscope} '
      'accel=${capabilities.hasAccelerometer}',
    );

    final intrinsics = await _poseService.cameraIntrinsics();
    diagnostics.breadcrumb('ar.intrinsics measured=${intrinsics.isMeasured}');
    if (!mounted) return;

    setState(() {
      _capabilities = capabilities;
      _intrinsics = intrinsics;
    });

    _scanner.cameraProvider = () {
      final viewport = _lastViewport;
      return viewport == null ? null : _cameraFor(viewport, _frames.pose);
    };
    _scanner.quarterTurns =
        ((_cameraController.description?.sensorOrientation ?? 90) ~/ 90) & 3;
    _cameraController.onFrame = _scanner.onFrame;

    diagnostics.breadcrumb('ar.camera.init.begin');
    await _cameraController.initialise();
    final preview = _cameraController.displayPreviewSize;
    diagnostics.breadcrumb(
      'ar.camera.init.done failure=${_cameraController.failure} '
      // Interpolating the Size itself printed "Instance of 'Size'": release
      // builds strip dart:ui toString implementations, so the one number that
      // mattered was the one the log could not show.
      'preview=${preview == null ? 'null' : '${preview.width.toStringAsFixed(0)}x${preview.height.toStringAsFixed(0)}'}',
    );
    if (!mounted) return;

    diagnostics.breadcrumb(
      'ar.pose.stream.begin fallback=${!capabilities.supportsWorldLocking}',
    );
    await _frames.start(capabilities: capabilities);
    diagnostics.breadcrumb('ar.pose.stream.started');
    if (!mounted) return;

    diagnostics.breadcrumb('ar.phase.calibrating');

    setState(() {
      if (_cameraController.failure == CameraFailure.permissionDenied) {
        _phase = _SessionPhase.needsCamera;
      } else if (_cameraController.failure != null) {
        _phase = _SessionPhase.unsupported;
      } else {
        _phase = _SessionPhase.scanning;
      }
    });
  }

  void _onCameraChanged() {
    if (mounted) setState(() {});
  }

  /// Pins the scenario's authoring "forward" to the worker's current heading.
  void _calibrate() {
    Diagnostics.instance.breadcrumb(
      'ar.calibrate yaw=${_frames.pose.yaw.toStringAsFixed(3)} '
      'source=${_frames.pose.source.name} samples=${_frames.sampleCount} '
      'coverage=${(_environment.coverage * 100).round()}% '
      'doors=${_environment.doors.length}',
    );

    // Build the gallery to fit what was measured, before the scenario places
    // anything into it.
    final gallery = GalleryLayout.fit(
      map: _environment,
      eyeHeightMetres: _environment.ground.cameraHeightMetres,
    );

    setState(() {
      _worldFromScene = ArCamera.calibrationFromYaw(_frames.pose.yaw);
      _gallery = gallery;
      _galleryNodes = [
        MineGalleryNode(id: 'gallery', layout: gallery),
        MineRailsNode(id: 'gallery.rails', layout: gallery),
        GalleryPortalNode(id: 'gallery.portal', layout: gallery),
      ];
      _phase = _SessionPhase.running;
    });

    // Offer the room to the scenario now that the scene rotation is fixed, so
    // world-space detections can be converted into the scene space its nodes
    // live in.
    final viewport = _lastViewport;
    if (viewport != null) {
      _scenario.applyEnvironment(
        _environment,
        _cameraFor(viewport, _frames.pose),
      );
    }
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

  /// Advances the scenario one frame. Called from the frame ticker, outside of
  /// any build pass.
  void _pumpScenario() {
    if (_phase != _SessionPhase.running || _scenario.isFinished) return;
    final viewport = _lastViewport;
    if (viewport == null) return;

    _scenario.update(_frames.elapsed, _cameraFor(viewport, _frames.pose));

    if (_scenario.isFinished) _onScenarioFinished();
  }

  void _onScenarioFinished() {
    if (_phase == _SessionPhase.finished) return;
    _frames.pause();
    setState(() => _phase = _SessionPhase.finished);
  }

  bool get _hasMoreActs => _actIndex + 1 < _actFactories.length;

  int get _actNumber => _actIndex + 1;

  int get _actTotal => _actFactories.length;

  /// Records the finished act and moves to the next, or ends the module.
  ///
  /// A failed act still advances. Stopping the module on the first mistake
  /// would deny the worker the rest of the training over one wrong tap, and the
  /// failure is already recorded against them.
  void _advanceAct() {
    final result = _scenario.result;
    if (result != null) _completedActs.add(result);

    if (!_hasMoreActs) {
      Navigator.of(
        context,
      ).pop(combineActs(domain: widget.domain, acts: _completedActs));
      return;
    }

    setState(() {
      _actIndex++;
      _scenario.dispose();
      _scenario = _actFactories[_actIndex]();
      // Each act re-origins on the worker's current heading, so they are not
      // penalised for having turned during the previous one.
      _worldFromScene = ArCamera.calibrationFromYaw(_frames.pose.yaw);
      _phase = _SessionPhase.running;
    });

    _frames.resume(_frames.elapsed);
  }

  @override
  void dispose() {
    _frames.removeListener(_pumpScenario);
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
        _lastViewport = viewport;

        return Stack(
          fit: StackFit.expand,
          children: [
            ArCameraPreview(controller: _cameraController),

            // Safe mode draws the camera and nothing else. If the drill is
            // stable here but dies with the scene on, the fault is in the
            // renderer; if it dies either way, it is the camera or the
            // platform below it. One tap, one bit of information.
            if (!_safeMode)
              // One AnimatedBuilder around everything pose-driven, so a frame
              // rebuilds this subtree only — not the gates, not the scaffold.
              AnimatedBuilder(
                animation: _frames,
                builder: (context, _) {
                  final pose = _frames.pose;
                  final camera = _cameraFor(viewport, pose);

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ArSceneView(
                        camera: camera,
                        // Gallery first so it sorts behind everything else; the
                        // scenario's own content lives inside it.
                        nodes: [..._galleryNodes, ..._scenario.nodes],
                        elapsed: _frames.elapsed,
                        onNodeTap: _phase == _SessionPhase.running
                            ? _scenario.handleTap
                            : null,
                        onEmptyTap: _phase == _SessionPhase.running
                            ? (_) => _scenario.handleEmptyTap()
                            : null,
                        onDrag: _phase == _SessionPhase.running
                            ? _scenario.handleDrag
                            : null,
                        onPressStart: _phase == _SessionPhase.running
                            ? _scenario.handlePressStart
                            : null,
                        onPressEnd: _phase == _SessionPhase.running
                            ? _scenario.handlePressEnd
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

            if (_phase == _SessionPhase.scanning) ...[
              SessionCalibrationGate(
                capabilities: _capabilities,
                intrinsicsAreMeasured: _intrinsics.isMeasured,
                environment: _environment,
                onBegin: _calibrate,
                onExit: () => Navigator.of(context).maybePop(),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: SafeArea(
                  child: FilterChip(
                    label: Text(_safeMode ? 'Safe mode: on' : 'Safe mode'),
                    selected: _safeMode,
                    avatar: Icon(
                      _safeMode ? Icons.healing : Icons.bug_report_outlined,
                      size: 18,
                    ),
                    onSelected: (value) {
                      Diagnostics.instance.breadcrumb('ar.safeMode=$value');
                      setState(() => _safeMode = value);
                    },
                  ),
                ),
              ),
            ],

            // An unfitted gallery uses standard dimensions and can therefore
            // pass through a real wall. Say so rather than letting a worker
            // walk into one.
            if (_phase == _SessionPhase.running &&
                _gallery != null &&
                !_gallery!.fittedToRoom)
              Positioned(
                left: 16,
                right: 16,
                top: 12,
                child: SafeArea(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.cautionAmber.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 20, color: Colors.black87),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'The room was not scanned, so this gallery may not '
                            'match your surroundings. Watch your step.',
                            style: TextStyle(
                              color: Colors.black87,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
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
                actNumber: _actNumber,
                actTotal: _actTotal,
                hasMoreActs: _hasMoreActs,
                onDone: _advanceAct,
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
        content: const Text('Your progress in this drill will not be counted.'),
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
      final result = _scenario.result;
      if (result != null) _completedActs.add(result);
      if (mounted) {
        Navigator.of(context).pop(
          _completedActs.isEmpty
              ? null
              : combineActs(domain: widget.domain, acts: _completedActs),
        );
      }
    } else {
      _frames.resume(_frames.elapsed);
    }
  }
}
