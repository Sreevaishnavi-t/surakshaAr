import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Records what the app was doing, so a crash can be diagnosed from the device
/// rather than from a guess.
///
/// Two things are captured, and the distinction matters:
///
/// * **Breadcrumbs** — short markers written *as they happen* and flushed to
///   disk immediately. These survive a native crash, where the process dies
///   without Dart ever seeing an exception. A camera or sensor failure inside
///   the platform layer is exactly that kind of crash, and the last breadcrumb
///   before the app restarts localises it to a few lines of code.
/// * **Errors** — Dart exceptions caught from [FlutterError.onError] and
///   [PlatformDispatcher.onError], with stack traces.
///
/// Written to app-private storage, shown in the in-app diagnostics screen, and
/// never transmitted anywhere. The whole point of this platform is that nothing
/// leaves the handset, and crash reporting is not an exception to that.
class Diagnostics {
  Diagnostics._();

  static final Diagnostics instance = Diagnostics._();

  static const int _maxEntries = 200;
  static const String _fileName = 'surakshaar-diagnostics.log';

  final List<String> _entries = <String>[];
  File? _file;
  bool _installed = false;

  List<String> get entries => List.unmodifiable(_entries);

  /// The breadcrumb trail from the previous run, if the app died unexpectedly.
  ///
  /// This is the payload that makes an unreproducible crash actionable: it says
  /// how far the previous session got before the process disappeared.
  List<String> previousRun = const [];

  /// Installs global error handlers and loads the previous run's log.
  ///
  /// Safe to call more than once.
  Future<void> install() async {
    if (_installed) return;
    _installed = true;

    final previousError = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        'FLUTTER ERROR: ${details.exceptionAsString()}',
        stackTrace: details.stack,
      );
      previousError?.call(details);
    };

    // Catches asynchronous errors that never reach a Dart zone handler.
    PlatformDispatcher.instance.onError = (error, stack) {
      record('UNCAUGHT: $error', stackTrace: stack);
      // Return true: the error has been recorded. Returning false would tell
      // the Flutter engine the error is *unhandled*, which re-throws it,
      // crashes the Dart isolate, and terminates the process — Android records
      // that as REASON_CRASH (Java/Kotlin exception) with description "crash".
      return true;
    };

    try {
      final directory = await getApplicationSupportDirectory();
      final file = File(p.join(directory.path, _fileName));

      if (await file.exists()) {
        final lines = await file.readAsLines();
        // Keep the tail: the interesting part of a crash log is the end.
        previousRun = lines.length > 60
            ? lines.sublist(lines.length - 60)
            : lines;
      }

      // Truncate for this run so the file never grows without bound.
      _file = await file.writeAsString(
        '--- session started ${DateTime.now().toIso8601String()} ---\n',
        mode: FileMode.write,
        flush: true,
      );
    } catch (e) {
      // Diagnostics must never be the reason the app fails to start.
      debugPrint('Diagnostics: could not open log file: $e');
    }
  }

  /// Notes that the app reached a particular point.
  ///
  /// Kept short and flushed immediately — a breadcrumb that is still buffered
  /// when the process dies is worthless.
  void breadcrumb(String message) {
    record('· $message');
  }

  void record(String message, {StackTrace? stackTrace}) {
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final line = '$stamp $message';

    _entries.add(line);
    if (stackTrace != null) {
      // First few frames only: enough to locate the fault, short enough to read
      // on a phone screen.
      final frames = stackTrace.toString().split('\n').take(8);
      _entries.addAll(frames.map((f) => '    $f'));
    }
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    debugPrint('[diag] $line');
    _appendSync(line, stackTrace);
  }

  /// Writes synchronously, on purpose.
  ///
  /// Asynchronous appends made the trail a *lagging* indicator: several writes
  /// could still be queued when the process died, so the last visible line sat
  /// behind where execution actually reached — and a breadcrumb that points at
  /// the wrong line is worse than none, because it sends you hunting in the
  /// wrong place.
  ///
  /// Blocking I/O on the UI thread is normally indefensible. Here it is a few
  /// hundred bytes appended a few dozen times per session, and it is the only
  /// way to guarantee the trail is true at the instant of a native crash.
  void _appendSync(String line, StackTrace? stackTrace) {
    final file = _file;
    if (file == null) return;
    try {
      final buffer = StringBuffer(line)..writeln();
      if (stackTrace != null) {
        for (final frame in _stackFrames(stackTrace)) {
          buffer.writeln('    ' + frame);
        }
      }
      file.writeAsStringSync(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never throw into the caller.
    }
  }

  /// First few stack frames: enough to locate a fault, short enough to read on
  /// a phone screen.
  static Iterable<String> _stackFrames(StackTrace stackTrace) =>
      const LineSplitter().convert(stackTrace.toString()).take(8);

  /// Everything worth showing on the diagnostics screen, as copyable text.
  String asReport({Map<String, Object?> environment = const {}}) {
    final buffer = StringBuffer()
      ..writeln('SurakshaAR diagnostics')
      ..writeln('Generated ${DateTime.now().toIso8601String()}')
      ..writeln();

    if (environment.isNotEmpty) {
      buffer.writeln('== Environment ==');
      environment.forEach((key, value) => buffer.writeln('$key: $value'));
      buffer.writeln();
    }

    if (previousRun.isNotEmpty) {
      buffer
        ..writeln('== Previous run (ended unexpectedly?) ==')
        ..writeAll(previousRun.map((l) => '$l\n'))
        ..writeln();
    }

    buffer
      ..writeln('== This run ==')
      ..writeAll(_entries.map((l) => '$l\n'));

    return buffer.toString();
  }
}
