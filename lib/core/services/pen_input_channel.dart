import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Native pen-button bridge for the Windows runner.
///
/// Background: Flutter on Windows reads pen events via the legacy
/// mouse path, which strips `POINTER_PEN_INFO.penFlags`. Tablet
/// drivers (Gaomon / Huion / Wacom) expose the barrel side buttons
/// through those flags — but to Flutter the press arrives as a
/// generic `kind=mouse buttons=0x4`, indistinguishable from a real
/// middle-click. The C++ runner subscribes to WM_POINTER* in
/// parallel with Flutter, reads `penFlags`, and forwards transitions
/// over this channel.
///
/// Two logical buttons:
///   - `barrel`   → lower side button (`PEN_FLAG_BARREL`)
///   - `inverted` → upper side button or actual eraser end
///     (`PEN_FLAG_INVERTED`). Most Huion-class tablets report the
///     upper button this way.
///
/// No-op on non-Windows platforms (Apple Pencil / Android stylus
/// already arrive with full pressure + buttons via Flutter's normal
/// pointer pipeline).
class PenInputChannel {
  static const MethodChannel _channel = MethodChannel('handwriter/pen_input');

  static bool _registered = false;

  /// Hook callbacks for barrel-button state transitions and the
  /// barrel-driven pen gesture. Idempotent — calling twice with new
  /// callbacks replaces the previous ones.
  ///
  /// [onBarrelPen] receives `phase` ("down" / "move" / "up"),
  /// `position` in Flutter logical pixels (renderer-local — convert
  /// with `RenderBox.globalToLocal` before feeding the canvas), and
  /// normalised `pressure` in `[0, 1]`. Fires only while a side button
  /// is held — needed because Gaomon driverless suppresses Flutter's
  /// regular PointerEvents while the barrel is pressed.
  static void register({
    required void Function(bool down) onBarrel,
    required void Function(bool down) onInverted,
    void Function(String phase, Offset position, double pressure)? onBarrelPen,
  }) {
    if (kIsWeb || !Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?)?.cast<Object?, Object?>();
      if (args == null) return;
      switch (call.method) {
        case 'onBarrelChange':
          final button = args['button'] as String?;
          final down = args['down'] as bool? ?? false;
          switch (button) {
            case 'barrel':
              onBarrel(down);
              break;
            case 'inverted':
              onInverted(down);
              break;
          }
          break;
        case 'onBarrelPen':
          if (onBarrelPen == null) return;
          final phase = args['phase'] as String?;
          final x = (args['x'] as num?)?.toDouble();
          final y = (args['y'] as num?)?.toDouble();
          final pressure = (args['pressure'] as num?)?.toDouble() ?? 0.5;
          if (phase == null || x == null || y == null) return;
          onBarrelPen(phase, Offset(x, y), pressure);
          break;
      }
    });
    _registered = true;
  }

  /// Clear the handler. Safe to call even if [register] was never
  /// invoked.
  static void unregister() {
    if (!_registered) return;
    _channel.setMethodCallHandler(null);
    _registered = false;
  }
}
