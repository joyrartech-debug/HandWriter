// ═══════════════════════════════════════════════════════════════
//  canvas_painter_notifiers.dart
//
//  Lightweight ChangeNotifiers used for zero-Riverpod-rebuild
//  rendering of active strokes and lasso paths during drawing.
//  Extracted from canvas_screen.dart.
// ═══════════════════════════════════════════════════════════════

import 'dart:io' as io;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

/// High-performance stroke tracker — bypasses Riverpod so every new point
/// does NOT trigger a full widget tree rebuild.
///
/// The CanvasScreen subscribes to this directly via [ListenableBuilder],
/// which only repaints the canvas layer, not the toolbar or page nav.
class ActiveStrokeNotifier extends ChangeNotifier {
  final List<StrokePoint> _points = [];
  bool _active = false;

  /// True when running on a desktop OS (Windows / macOS / Linux).
  ///
  /// Desktop graphics tablets produce ADC jitter that requires a wider
  /// smoothing window than Apple Pencil on iPad, which delivers hardware-
  /// filtered, 120 Hz coalesced events.
  bool _isDesktop = false;

  List<StrokePoint> get points => _points;
  bool get isActive => _active;

  void start(Offset pos, double pressure) {
    _points.clear();
    _active = true;
    _isDesktop = !kIsWeb &&
        (io.Platform.isWindows || io.Platform.isMacOS || io.Platform.isLinux);
    _points.add(StrokePoint(x: pos.dx, y: pos.dy, pressure: pressure,
        timestamp: DateTime.now().millisecondsSinceEpoch));
    notifyListeners();
  }

  void addPoint(Offset pos, double pressure) {
    // ── Jitter rejection ────────────────────────────────────────────────────
    // Drop points that are < 0.4 page-units from the previous point.
    // On desktop tablets this eliminates ADC noise without losing real movement.
    if (_points.isNotEmpty) {
      final last = _points.last;
      final dx = pos.dx - last.x;
      final dy = pos.dy - last.y;
      if (dx * dx + dy * dy < 0.16) return; // 0.4² = 0.16
    }

    double sx = pos.dx, sy = pos.dy, sp = pressure;

    if (_isDesktop) {
      // ── Desktop / graphics-tablet smoothing (5-point window) ─────────────
      // Heavier history weighting (current = 6/16 ≈ 38 %) irons out the
      // waviness caused by the tablet digitiser's analog noise.
      if (_points.length >= 4) {
        final p3 = _points[_points.length - 1];
        final p2 = _points[_points.length - 2];
        final p1 = _points[_points.length - 3];
        final p0 = _points[_points.length - 4];
        sx = (p0.x + p1.x * 2 + p2.x * 3 + p3.x * 4 + pos.dx * 6) / 16;
        sy = (p0.y + p1.y * 2 + p2.y * 3 + p3.y * 4 + pos.dy * 6) / 16;
        sp = (p0.pressure + p1.pressure*2 + p2.pressure*3 + p3.pressure*4 + pressure*6) / 16;
      } else if (_points.length >= 3) {
        final p2 = _points[_points.length - 1];
        final p1 = _points[_points.length - 2];
        final p0 = _points[_points.length - 3];
        sx = (p0.x + p1.x * 2 + p2.x * 3 + pos.dx * 4) / 10;
        sy = (p0.y + p1.y * 2 + p2.y * 3 + pos.dy * 4) / 10;
        sp = (p0.pressure + p1.pressure*2 + p2.pressure*3 + pressure*4) / 10;
      } else if (_points.length >= 2) {
        final p1 = _points[_points.length - 1];
        final p0 = _points[_points.length - 2];
        sx = (p0.x + p1.x * 2 + pos.dx * 3) / 6;
        sy = (p0.y + p1.y * 2 + pos.dy * 3) / 6;
        sp = (p0.pressure + p1.pressure*2 + pressure*3) / 6;
      } else if (_points.length == 1) {
        final p1 = _points.last;
        sx = (p1.x + pos.dx) / 2;
        sy = (p1.y + pos.dy) / 2;
        sp = (p1.pressure + pressure) / 2;
      }
    } else {
      // ── Touch / Apple Pencil smoothing (very light, high current-weight) ─
      // Apple Pencil is already hardware-filtered at 120 Hz. Heavier
      // smoothing (old: current=53 %, 4-point window) caused two user-
      // visible defects:
      //   1. the stroke visibly lags the pen tip, and
      //   2. the tail end is "pulled back" toward earlier points so the
      //      final letter looks squeezed vs. what the user drew.
      // A 3-point window with ~80 % weight on the current point removes
      // sub-pixel ADC jitter without any perceptible drag.
      if (_points.length >= 2) {
        final p1 = _points[_points.length - 1];
        final p0 = _points[_points.length - 2];
        sx = (p0.x + p1.x * 3 + pos.dx * 16) / 20;
        sy = (p0.y + p1.y * 3 + pos.dy * 16) / 20;
        sp = (p0.pressure + p1.pressure * 3 + pressure * 16) / 20;
      } else if (_points.length == 1) {
        final p1 = _points.last;
        sx = (p1.x + pos.dx * 7) / 8;
        sy = (p1.y + pos.dy * 7) / 8;
        sp = (p1.pressure + pressure * 7) / 8;
      }
    }

    _points.add(StrokePoint(x: sx, y: sy, pressure: sp,
        timestamp: DateTime.now().millisecondsSinceEpoch));
    notifyListeners();
  }

  void clearPoints() {
    _points.clear();
    notifyListeners();
  }

  void clear() {
    _points.clear();
    _active = false;
    notifyListeners();
  }
}

/// Local lasso path tracker — zero Riverpod rebuilds during drawing.
/// At pointer-up the collected path is committed to the provider in one shot.
class LassoPathNotifier extends ChangeNotifier {
  final List<Offset> _points = [];
  bool _active = false;

  List<Offset> get points => _points;
  bool get isActive => _active;

  void start(Offset pos) {
    _points.clear();
    _active = true;
    _points.add(pos);
    notifyListeners();
  }

  void addPoint(Offset pos) {
    _points.add(pos);
    notifyListeners();
  }

  void clear() {
    _points.clear();
    _active = false;
    notifyListeners();
  }
}
