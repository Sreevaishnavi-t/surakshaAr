import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;

/// Why the camera is not currently showing anything.
enum CameraFailure {
  permissionDenied,
  noCameraAvailable,
  initialisationFailed,
}

/// Owns the rear-camera preview used as the AR backdrop.
///
/// Lifecycle matters more than usual here. A worker gets a phone call mid-drill,
/// Android tears the camera down, and on resume the session must come back
/// without losing scenario progress. So the controller is disposed on pause and
/// rebuilt on resume, while the scenario state lives entirely outside this class.
class ArCameraController extends ChangeNotifier with WidgetsBindingObserver {
  ArCameraController({this.forImageStream = false});

  /// Whether this controller will actually call `startImageStream`.
  ///
  /// Only the certificate scanner does. Requesting an image format configures
  /// a CameraX ImageAnalysis pipeline with native YUV-to-NV21 conversion, and
  /// standing that up for a consumer that never reads a frame is pure overhead
  /// on the drill path — overhead running in native code, on the exact step
  /// where the AR session was dying. The drill uses the camera purely as a
  /// backdrop, so it asks for no analysis pipeline at all.
  final bool forImageStream;

  CameraController? _controller;
  CameraDescription? _description;
  CameraFailure? _failure;
  bool _initialising = false;
  bool _disposed = false;

  CameraController? get controller => _controller;

  /// The selected camera. Needed to work out frame rotation for ML Kit.
  CameraDescription? get description => _description;

  CameraFailure? get failure => _failure;
  bool get isReady => _controller?.value.isInitialized ?? false;

  /// Preview dimensions rotated into the orientation actually being displayed.
  ///
  /// `previewSize` is reported in sensor orientation, which is landscape on
  /// essentially every phone. The activity is portrait-locked, so the width and
  /// height must be swapped before any projection maths touches them — skipping
  /// this stretches the overlay by the aspect ratio, roughly 1.8x.
  Size? get displayPreviewSize {
    final size = _controller?.value.previewSize;
    if (size == null) return null;
    return Size(size.height, size.width);
  }

  Future<void> initialise() async {
    if (_initialising || _disposed) return;
    _initialising = true;
    _failure = null;

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _fail(CameraFailure.noCameraAvailable);
        return;
      }

      final rear = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        rear,
        // Medium is deliberate. The preview is a backdrop, not the subject, and
        // on a mid-range phone a higher resolution costs frame time that the
        // overlay needs far more than the passthrough does.
        ResolutionPreset.medium,
        enableAudio: false,
        // NV21 only when frames are actually consumed, so ML Kit gets a single
        // contiguous plane. YUV420 would mean interleaving three planes by hand
        // with per-device row and pixel strides — a well-known source of frames
        // that look fine in the preview but detect nothing.
        imageFormatGroup: forImageStream ? ImageFormatGroup.nv21 : null,
      );

      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }

      // Locking capture orientation keeps the preview stable if the OS briefly
      // reports a rotation change during startup.
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);

      _controller = controller;
      _description = rear;
      _failure = null;
    } on CameraException catch (e) {
      debugPrint('ArCameraController: ${e.code} ${e.description}');
      _fail(
        e.code == 'CameraAccessDenied' || e.code == 'CameraAccessDeniedWithoutPrompt'
            ? CameraFailure.permissionDenied
            : CameraFailure.initialisationFailed,
      );
    } catch (e) {
      debugPrint('ArCameraController: $e');
      _fail(CameraFailure.initialisationFailed);
    } finally {
      _initialising = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _fail(CameraFailure failure) {
    _failure = failure;
    _controller = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        if (controller != null) {
          _controller = null;
          notifyListeners();
          unawaited(controller.dispose());
        }
      case AppLifecycleState.resumed:
        if (controller == null && !_initialising) {
          unawaited(initialise());
        }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller?.dispose());
    _controller = null;
    super.dispose();
  }
}

/// Full-bleed camera preview, cover-fitted to the viewport.
///
/// Cover rather than contain: letterbox bars would break the illusion that the
/// worker is looking through the phone at the real space in front of them. The
/// crop this introduces is accounted for in `ArCameraIntrinsics.focalPixels`, so
/// the overlay stays aligned with what is actually visible.
class ArCameraPreview extends StatelessWidget {
  const ArCameraPreview({
    super.key,
    required this.controller,
    this.fallbackColor = const Color(0xFF11151C),
  });

  final ArCameraController controller;
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    final cameraController = controller.controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return ColoredBox(color: fallbackColor, child: const SizedBox.expand());
    }

    final preview = controller.displayPreviewSize;
    if (preview == null) {
      return ColoredBox(color: fallbackColor, child: const SizedBox.expand());
    }

    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: preview.width,
            height: preview.height,
            child: CameraPreview(cameraController),
          ),
        ),
      ),
    );
  }
}
