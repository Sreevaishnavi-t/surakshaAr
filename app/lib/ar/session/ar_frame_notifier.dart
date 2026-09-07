import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../core/diagnostics.dart';

import '../pose/device_pose.dart';
import '../pose/pose_service.dart';

/// Drives one AR frame clock and decouples it from the sensor rate.
///
/// The pose sensor delivers around 100 Hz while the display runs at 60. Calling
/// `setState` per sensor sample would rebuild the tree roughly 40 extra times a
/// second for frames nobody ever sees — a real cost on the budget hardware this
/// targets. So sensor samples update a plain field, and only the vsync ticker
/// notifies listeners. Widgets rebuild exactly once per rendered frame.
class ArFrameNotifier extends ChangeNotifier {
  ArFrameNotifier({
    required PoseService poseService,
    required TickerProvider vsync,
    // Dart forbids a named parameter starting with an underscore, so the lint's
    // suggested `this._poseService` is not expressible here.
    // ignore: prefer_initializing_formals
  }) : _poseService = poseService {
    _ticker = vsync.createTicker(_onTick);
  }

  final PoseService _poseService;
  late final Ticker _ticker;

  StreamSubscription<DevicePose>? _poseSubscription;

  /// Falls back to an upright phone rather than the identity orientation.
  ///
  /// Identity points the rear camera at the floor, which culls the entire scene
  /// and makes the app look broken on a device whose sensors have not reported
  /// yet — or do not exist at all.
  DevicePose _pose = DevicePose.upright();
  Duration _elapsed = Duration.zero;
  Duration _pausedAt = Duration.zero;
  bool _paused = false;
  int _sampleCount = 0;

  /// Current orientation.
  ///
  /// Until a real sample arrives this is a synthetic upright pose, so content
  /// is visible and the drill is playable. [hasPose] says which it is, and the
  /// HUD surfaces that to the worker rather than pretending to track.
  DevicePose get pose => _pose;

  /// Total pose samples received. Exposed for the diagnostics screen, where
  /// "camera works but nothing appears" needs to be distinguishable from
  /// "sensors are silent".
  int get sampleCount => _sampleCount;

  /// Time since [start], excluding any paused spans. Everything visual and every
  /// scoring timer reads from this one clock, so a replay is reproducible.
  Duration get elapsed => _elapsed;

  bool get isPaused => _paused;

  /// True once at least one real sensor sample has arrived. Until then the view
  /// is showing the identity pose and should say so rather than silently
  /// pretending to track.
  bool get hasPose => _sampleCount > 0;

  PoseSource get source => _pose.source;

  /// Begins the frame clock and subscribes to the best available pose source.
  ///
  /// [capabilities] decides between the platform's fused sensor and the Dart
  /// Madgwick fallback. Passing null uses the platform stream, which is the
  /// right default when capabilities could not be queried.
  Future<void> start({PoseCapabilities? capabilities}) async {
    final stream = capabilities == null
        ? _poseService.poses
        : _poseService.streamFor(capabilities);

    Diagnostics.instance.breadcrumb('frames.subscribe.begin');
    _poseSubscription ??= stream.listen(
      (pose) {
        if (_sampleCount == 0) {
          Diagnostics.instance.breadcrumb('frames.pose.first source=${pose.source.name}');
        }
        _pose = pose;
        _sampleCount++;
      },
      onError: (Object error) {
        Diagnostics.instance.record('frames.pose.error: $error');
      },
      cancelOnError: false,
    );
    Diagnostics.instance.breadcrumb('frames.subscribe.done');

    if (!_ticker.isActive) {
      _ticker.start();
      Diagnostics.instance.breadcrumb('frames.ticker.started');
    }
  }

  void _onTick(Duration tickerElapsed) {
    if (_paused) return;
    _elapsed = tickerElapsed - _pausedAt;
    notifyListeners();
  }

  /// Freezes the scene clock. Used when a step completes and a result overlay is
  /// shown, so animation and timers do not keep running behind the dialog.
  void pause() {
    if (_paused) return;
    _paused = true;
    notifyListeners();
  }

  void resume(Duration tickerNow) {
    if (!_paused) return;
    _pausedAt = tickerNow - _elapsed;
    _paused = false;
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_poseSubscription?.cancel());
    _poseSubscription = null;
    super.dispose();
  }
}
