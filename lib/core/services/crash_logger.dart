import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// File-backed crash / error logger for environments where a native crash
/// reporter isn't available (iPad sideloaded builds that don't produce
/// `.ips` files, headless Linux/Windows runs without Xcode Console, etc.).
///
/// Captures:
///   - uncaught Flutter framework errors (`FlutterError.onError`)
///   - platform-dispatcher errors (`PlatformDispatcher.onError`)
///   - zone-level async errors (via `runZonedGuarded` wrapper in `main.dart`)
///
/// The log is append-only to `<documents>/handwriter_crash.log`, rotated
/// when it grows past [_maxBytes] so it doesn't balloon over time. The
/// library UI exposes a button that reads this file and copies it to the
/// clipboard so the user can forward it without Xcode / a Mac.
class CrashLogger {
  static const int _maxBytes = 256 * 1024; // 256 KB cap

  static File? _logFile;
  static bool _initialised = false;

  /// Must be called once at app startup (before `runApp`).
  static Future<void> init() async {
    if (_initialised) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/handwriter_crash.log');
      _initialised = true;
      await _rotateIfTooBig();
      await append(
        '--- app start '
        '${DateTime.now().toIso8601String()} '
        '(${defaultTargetPlatform.name}) ---',
      );
    } catch (e) {
      // If even the logger can't initialise, swallow — we don't want the
      // logger itself to crash the app.
      debugPrint('[CrashLogger] init failed: $e');
    }

    // Flutter framework errors (build / layout / paint exceptions).
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      previousOnError?.call(details);
      append(
        'FlutterError: ${details.exceptionAsString()}\n'
        '${details.stack ?? "(no stack)"}',
      );
    };

    // Errors coming from the platform dispatcher (e.g. async errors that
    // escape the framework).
    PlatformDispatcher.instance.onError = (error, stack) {
      append('PlatformDispatcher: $error\n$stack');
      return false; // not handled — let default behaviour continue
    };
  }

  /// Append one line to the log with an ISO-8601 timestamp. Never throws.
  static Future<void> append(String message) async {
    final file = _logFile;
    if (file == null) return;
    try {
      final stamp = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$stamp] $message\n',
        mode: FileMode.append,
        flush: true,
      );
      await _rotateIfTooBig();
    } catch (_) {
      // Never let logging failures propagate.
    }
  }

  /// Returns the entire log contents or an empty string if nothing logged.
  static Future<String> read() async {
    final file = _logFile;
    if (file == null || !await file.exists()) return '';
    try {
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// Truncate the log file to zero bytes.
  static Future<void> clear() async {
    final file = _logFile;
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.writeAsString('', mode: FileMode.write, flush: true);
      }
    } catch (_) {}
  }

  /// Absolute file path (may be null before `init()` completes).
  static String? get path => _logFile?.path;

  static Future<void> _rotateIfTooBig() async {
    final file = _logFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final stat = await file.stat();
      if (stat.size <= _maxBytes) return;
      // Keep only the tail (second half) — preserves recent entries.
      final content = await file.readAsString();
      final tailStart = content.length - (_maxBytes ~/ 2);
      final firstNewline = content.indexOf('\n', tailStart);
      final trimmed = firstNewline >= 0
          ? content.substring(firstNewline + 1)
          : content.substring(tailStart);
      await file.writeAsString(trimmed, mode: FileMode.write, flush: true);
    } catch (_) {}
  }
}
