// ═══════════════════════════════════════════════════════════════
//  canvas_painter_notifiers.dart
//
//  Lightweight ChangeNotifiers used for zero-Riverpod-rebuild
//  rendering of active strokes and lasso paths during drawing.
//  Extracted from canvas_screen.dart.
// ═══════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io' as io;
import 'dart:math' show sqrt;
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

  /// True when the pointing device reports no pressure (mouse / touchpad /
  /// some plain touch panels). When set, [addPoint] synthesises a velocity-
  /// derived pseudo-pressure so the rendered stroke isn't stuck at a flat
  /// 0.5 fallback. Detected from the first [start] pressure: anything <= 0
  /// means "no real pressure data", at which point we synth.
  bool _synthPressure = false;
  /// EMA state for synth pressure (0..1). Smoothed across points so width
  /// modulation isn't choppy on irregular sample rates.
  double _synthEma = 0.6;

  List<StrokePoint> get points => _points;
  bool get isActive => _active;

  void start(Offset pos, double pressure) {
    _points.clear();
    _active = true;
    _isDesktop = !kIsWeb &&
        (io.Platform.isWindows || io.Platform.isMacOS || io.Platform.isLinux);
    // Devices without pressure (mouse, touchpad, plain touch) report 0.
    // Stylus / Apple Pencil always report > 0, so this check leaves the
    // pen-input pipeline bit-equivalent.
    _synthPressure = pressure <= 0.0;
    _synthEma = 0.6;
    final p0 = _synthPressure ? 0.6 : pressure;
    _points.add(StrokePoint(x: pos.dx, y: pos.dy, pressure: p0,
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

    // Synthesise a velocity-derived pseudo-pressure for devices without real
    // pressure (mouse / touchpad). Slow movement → high pressure (full body),
    // fast movement → low pressure (thin), smoothed by an EMA so width
    // modulation isn't jittery on irregular sample rates. Range [0.30, 0.85]
    // stays inside the renderer's existing pressureFactor mapping
    // (0.45 + p*0.60), giving a stroke that breathes 0.63→0.96 of baseWidth
    // before the velocity factor is applied — very close to a stylus feel.
    if (_synthPressure && _points.isNotEmpty) {
      final last = _points.last;
      final dx2 = pos.dx - last.x;
      final dy2 = pos.dy - last.y;
      final v = sqrt(dx2 * dx2 + dy2 * dy2);
      // Page-units per sample. ~8 page-units/sample = "fast scribble" → thin.
      final target = (0.85 - (v / 8.0).clamp(0.0, 0.55)).clamp(0.30, 0.85);
      _synthEma = _synthEma * 0.7 + target * 0.3;
      sp = _synthEma;
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

  /// Resume tracking with the provided history. Used to recover from
  /// spurious PointerUp+PointerDown sequences on iPad where the pen
  /// never actually lifted — without this, each segment would commit
  /// as its own stroke and the user would see a mid-letter break.
  ///
  /// The synth-pressure / desktop flags are preserved (they were set
  /// by the original [start] call and survive [clear]); _synthEma is
  /// re-anchored to the last point's pressure so width modulation
  /// continues smoothly across the seam.
  void restoreActive(List<StrokePoint> previousPoints) {
    _points.clear();
    if (previousPoints.isNotEmpty) {
      _points.addAll(previousPoints);
      _synthEma = previousPoints.last.pressure.clamp(0.30, 0.85).toDouble();
    }
    _active = true;
    notifyListeners();
  }
}

/// Live transform of an existing lasso selection (drag offset / rotation /
/// scale) tracked locally so every pointer-move event doesn't fire a full
/// Riverpod state update. The painter reads the live values via [snapshot]
/// and the CustomPaint listens on [this] to schedule repaint without
/// rebuilding the widget tree above it.
class LassoTransformNotifier extends ChangeNotifier {
  bool _active = false;
  Offset _dragOffset = Offset.zero;
  double _rotation = 0.0;
  double _scale = 1.0;

  bool get isActive => _active;
  Offset get dragOffset => _dragOffset;
  double get rotation => _rotation;
  double get scale => _scale;

  ({Offset dragOffset, double rotation, double scale}) snapshot() =>
      (dragOffset: _dragOffset, rotation: _rotation, scale: _scale);

  void begin({
    Offset dragOffset = Offset.zero,
    double rotation = 0.0,
    double scale = 1.0,
  }) {
    _active = true;
    _dragOffset = dragOffset;
    _rotation = rotation;
    _scale = scale;
    notifyListeners();
  }

  void translate(Offset delta) {
    if (!_active) return;
    _dragOffset += delta;
    notifyListeners();
  }

  void rotateBy(double delta) {
    if (!_active) return;
    _rotation += delta;
    notifyListeners();
  }

  void setScale(double s) {
    if (!_active) return;
    _scale = s;
    notifyListeners();
  }

  void end() {
    if (!_active) return;
    _active = false;
    _dragOffset = Offset.zero;
    _rotation = 0.0;
    _scale = 1.0;
    notifyListeners();
  }
}

/// Live drag/rotate/resize of a single non-lasso selected element
/// (image / shape / text picked via double-tap). Same pattern as
/// LassoTransformNotifier: pan-update writes go here instead of into
/// Riverpod, the painter reads the live values each frame, and Riverpod
/// catches up exactly once on pan-end.
class ElementTransformNotifier extends ChangeNotifier {
  String? _elementId;
  // Live page-space delta applied to the element's stored (x, y).
  Offset _dragOffset = Offset.zero;
  // Live rotation delta added to the element's stored rotation.
  double _rotationDelta = 0.0;
  // Live multiplicative scale applied to the element's stored
  // (width, height) — only used by resize.
  double _scaleW = 1.0;
  double _scaleH = 1.0;

  bool get isActive => _elementId != null;
  String? get elementId => _elementId;
  Offset get dragOffset => _dragOffset;
  double get rotationDelta => _rotationDelta;
  double get scaleW => _scaleW;
  double get scaleH => _scaleH;

  void begin(String elementId) {
    _elementId = elementId;
    _dragOffset = Offset.zero;
    _rotationDelta = 0.0;
    _scaleW = 1.0;
    _scaleH = 1.0;
    notifyListeners();
  }

  void translate(Offset delta) {
    if (_elementId == null) return;
    _dragOffset += delta;
    notifyListeners();
  }

  void rotateBy(double delta) {
    if (_elementId == null) return;
    _rotationDelta += delta;
    notifyListeners();
  }

  /// Replace the live scale (e.g. when the user drags a corner handle —
  /// the screen helper has already converted the new bounds back to a
  /// (sw, sh) factor relative to the original bounds).
  void setScale(double sw, double sh) {
    if (_elementId == null) return;
    _scaleW = sw;
    _scaleH = sh;
    notifyListeners();
  }

  void end() {
    _elementId = null;
    _dragOffset = Offset.zero;
    _rotationDelta = 0.0;
    _scaleW = 1.0;
    _scaleH = 1.0;
    notifyListeners();
  }
}

/// Laser-pointer trail — points are tagged with timestamps and the
/// painter renders them with an opacity that fades to zero over
/// [trailMs]. Once a point has fully faded it's pruned from the
/// buffer. Never committed to a page (this is presentation ink, not
/// annotation ink).
class LaserStrokeNotifier extends ChangeNotifier {
  /// Total fade-out window in ms. ~1.5 s feels right — long enough to
  /// follow the user pointing out something on a page, short enough not
  /// to clutter when they sweep around.
  static const int trailMs = 1500;

  final List<({double x, double y, int t})> _points = [];
  Timer? _ticker;

  List<({double x, double y, int t})> get points => _points;

  /// Append a point. Starts a periodic ticker that prunes faded points
  /// and re-paints. Idempotent.
  void addPoint(Offset pos) {
    _points.add((
      x: pos.dx,
      y: pos.dy,
      t: DateTime.now().millisecondsSinceEpoch,
    ));
    _ticker ??= Timer.periodic(const Duration(milliseconds: 30), (_) {
      _prune();
    });
    notifyListeners();
  }

  void _prune() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - trailMs;
    var pruned = false;
    while (_points.isNotEmpty && _points.first.t < cutoff) {
      _points.removeAt(0);
      pruned = true;
    }
    if (_points.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
    if (pruned || _points.isNotEmpty) {
      // Always notify while there are points so the painter can
      // re-render them at lower opacity each tick.
      notifyListeners();
    }
  }

  /// Cancel the trail outright (e.g. when the user switches tools).
  void clear() {
    _points.clear();
    _ticker?.cancel();
    _ticker = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
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
