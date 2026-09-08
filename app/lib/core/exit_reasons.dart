import 'package:flutter/services.dart';

/// Why a previous instance of this process died, straight from Android.
///
/// See [ExitReasonChannel] on the Kotlin side. This is ground truth in a way
/// breadcrumbs are not: a breadcrumb trail ends at the last thing the *Dart*
/// isolate did, so a kernel memory kill, a native signal on the raster thread
/// and an ANR all look identical from Dart — the log just stops. This says
/// which one it actually was.
class ProcessExit {
  const ProcessExit({
    required this.reason,
    required this.description,
    required this.status,
    required this.pssKb,
    required this.rssKb,
    required this.timestampMs,
    this.trace,
  });

  /// Human-readable, e.g. "CRASH_NATIVE (native signal)" or "LOW_MEMORY".
  final String reason;

  final String? description;
  final int status;

  /// Memory in use at the moment of death. Settles the OOM question outright.
  final int pssKb;
  final int rssKb;

  final int timestampMs;

  /// ANR trace or native tombstone, reduced to its printable strings.
  final String? trace;

  bool get isNativeCrash => reason.startsWith('CRASH_NATIVE');
  bool get isLowMemory => reason.startsWith('LOW_MEMORY');
  bool get isAnr => reason.startsWith('ANR');

  /// Deaths the user caused. Backing out of the app is not a fault to report.
  bool get isBenign =>
      reason.startsWith('USER_REQUESTED') ||
      reason.startsWith('USER_STOPPED') ||
      reason.startsWith('EXIT_SELF');

  DateTime get when => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  static ProcessExit fromMap(Map<Object?, Object?> raw) {
    int intOf(String key) {
      final value = raw[key];
      return value is num ? value.toInt() : 0;
    }

    return ProcessExit(
      reason: raw['reason']?.toString() ?? 'UNKNOWN',
      description: raw['description']?.toString(),
      status: intOf('status'),
      pssKb: intOf('pssKb'),
      rssKb: intOf('rssKb'),
      timestampMs: intOf('timestampMs'),
      trace: raw['trace']?.toString(),
    );
  }

  String get memorySummary =>
      'PSS ${(pssKb / 1024).toStringAsFixed(0)} MB, '
      'RSS ${(rssKb / 1024).toStringAsFixed(0)} MB';
}

class ExitReasonService {
  ExitReasonService({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('org.suraksha.surakshaar/exit_reasons');

  final MethodChannel _channel;

  /// Most recent first. Empty below Android 11, where the API does not exist.
  Future<List<ProcessExit>> recent() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('lastExits');
      if (raw == null) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(ProcessExit.fromMap)
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      // Unit tests and the desktop harness.
      return const [];
    }
  }
}
