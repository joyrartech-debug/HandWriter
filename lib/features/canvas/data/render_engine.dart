import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

/// High-performance canvas render engine.
/// Handles all rendering including zoom/pan transform internally.
class CanvasRenderEngine extends CustomPainter {
  final PageData pageData;
  final List<StrokePoint>? activeStroke;
  final String? activeToolType;
  final int? activeColor;
  final double? activeWidth;
  final LassoSelection? lassoSelection;
  final List<Offset>? lassoPath;
  final List<Offset> Function()? lassoPathGetter;
  final (Offset, Offset, String)? shapePreview;
  final ShapeData? recognizedShapePreview;
  final double zoom;
  final Offset panOffset;
  final Map<String, ui.Image> imageCache;

  CanvasRenderEngine({
    required this.pageData,
    this.activeStroke,
    this.activeToolType,
    this.activeColor,
    this.activeWidth,
    this.lassoSelection,
    this.lassoPath,
    this.lassoPathGetter,
    this.shapePreview,
    this.recognizedShapePreview,
    this.zoom = 1.0,
    this.panOffset = Offset.zero,
    this.imageCache = const {},
    Listenable? repaintNotifier,
  }) : super(repaint: repaintNotifier);

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / pageData.width;
    final scaleY = size.height / pageData.height;
    final baseScale = min(scaleX, scaleY);

    // Center the page in the canvas area
    final scaledW = pageData.width * baseScale;
    final scaledH = pageData.height * baseScale;
    final centerOffsetX = (size.width - scaledW) / 2;
    final centerOffsetY = (size.height - scaledH) / 2;

    canvas.save();

    // Apply pan + centering + zoom + base scale
    canvas.translate(
      panOffset.dx + centerOffsetX * zoom,
      panOffset.dy + centerOffsetY * zoom,
    );
    canvas.scale(zoom * baseScale);

    // 0. Page shadow (behind the page)
    final shadowPaint = Paint()
      ..color = const Color(0x33000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawRect(
      Rect.fromLTWH(3, 3, pageData.width, pageData.height),
      shadowPaint,
    );

    // 1. Page background (white rect)
    _paintBackground(canvas, pageData.layers.background);

    // 2. Page border
    _paintPageBorder(canvas);

    // 3. Content elements (cached sort to avoid O(n log n) per frame)
    final sortedContent = _getSortedContent(pageData.layers.content);

    final selectedIds = lassoSelection?.selectedIds ?? [];
    final selDragOffset = lassoSelection?.dragOffset ?? Offset.zero;
    final selRotation = lassoSelection?.rotation ?? 0.0;
    final selScale = lassoSelection?.scale ?? 1.0;
    final selCenter = lassoSelection != null
        ? lassoSelection!.bounds.center
        : Offset.zero;
    final hasTransform = selDragOffset != Offset.zero || selRotation != 0.0 || selScale != 1.0;

    for (final element in sortedContent) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      final isSelected = selectedIds.contains(id);

      // If this element is being moved/rotated/scaled via lasso, apply transform
      if (isSelected && hasTransform) {
        canvas.save();
        canvas.translate(selDragOffset.dx, selDragOffset.dy);
        canvas.translate(selCenter.dx, selCenter.dy);
        if (selScale != 1.0) {
          canvas.scale(selScale);
        }
        if (selRotation != 0.0) {
          canvas.rotate(selRotation);
        }
        canvas.translate(-selCenter.dx, -selCenter.dy);
      }

      element.map(
        stroke: (e) => _paintStroke(canvas, e.data),
        text: (e) => _paintText(canvas, e.data),
        image: (e) => _paintImage(canvas, e.data),
        shape: (e) => _paintShape(canvas, e.data),
      );

      if (isSelected && hasTransform) {
        canvas.restore();
      }
    }

    // 4. Active stroke being drawn
    if (activeStroke != null && activeStroke!.length >= 2) {
      _paintStroke(canvas, StrokeData(
        points: activeStroke!,
        toolType: activeToolType ?? 'pen',
        color: activeColor ?? 0xFF000000,
        baseWidth: activeWidth ?? AppConfig.defaultStrokeWidth,
      ));
    }

    // 5. Shape preview
    if (shapePreview != null) {
      _paintShapePreview(canvas, shapePreview!);
    }

    // 5b. Recognized shape preview (interactive adjustment)
    if (recognizedShapePreview != null) {
      _paintRecognizedShapePreview(canvas, recognizedShapePreview!);
    }

    // 6. Lasso path — read live from getter if available
    final currentLassoPath = lassoPathGetter?.call() ?? lassoPath;
    if (currentLassoPath != null && currentLassoPath.length >= 2) {
      _paintLassoPathFromPoints(canvas, currentLassoPath);
    }

    // 7. Lasso selection bounds
    if (lassoSelection != null) {
      _paintSelectionBounds(canvas);
    }

    canvas.restore();
  }

  /// Paint the page content without zoom/pan transform.
  /// Used for export (PNG/PDF).
  void paintPage(Canvas canvas, Size size, double scale, Offset offset) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);

    // Background
    _paintBackground(canvas, pageData.layers.background);

    // Content
    final sortedContent = List<ContentElement>.from(pageData.layers.content)
      ..sort((a, b) {
        final aZ = a.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        final bZ = b.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        return aZ.compareTo(bZ);
      });

    for (final element in sortedContent) {
      element.map(
        stroke: (e) => _paintStroke(canvas, e.data),
        text: (e) => _paintText(canvas, e.data),
        image: (e) => _paintImage(canvas, e.data),
        shape: (e) => _paintShape(canvas, e.data),
      );
    }

    canvas.restore();
  }

  void _paintPageBorder(Canvas canvas) {
    final borderPaint = Paint()
      ..color = const Color(0xFFD0D0D0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(Rect.fromLTWH(0, 0, pageData.width, pageData.height), borderPaint);
  }

  void _paintBackground(Canvas canvas, BackgroundLayer bg) {
    final bgPaint = Paint()..color = Color(bg.color);
    canvas.drawRect(Rect.fromLTWH(0, 0, pageData.width, pageData.height), bgPaint);

    final linePaint = Paint()
      ..color = Color(bg.lineColor)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    switch (bg.type) {
      case 'lined':
      case 'lined_wide':
        _paintLinedBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 35.0, linePaint, showMargin: true);
        break;
      case 'lined_narrow':
        _paintLinedBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 20.0, linePaint, showMargin: false);
        break;
      case 'grid':
        _paintGridBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 25.0, linePaint);
        break;
      case 'dotted':
        _paintDottedBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 25.0, linePaint);
        break;
      case 'cornell':
        _paintCornellBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 25.0, linePaint);
        break;
      case 'isometric':
        _paintIsometricBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 30.0, linePaint);
        break;
      case 'music':
        _paintMusicBackground(canvas, bg.lineSpacing > 0 ? bg.lineSpacing : 8.0, linePaint);
        break;
    }
  }

  void _paintLinedBackground(Canvas canvas, double spacing, Paint paint, {required bool showMargin}) {
    if (showMargin) {
      final marginPaint = Paint()
        ..color = const Color(0xFFE8B4B8)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      canvas.drawLine(const Offset(60, 0), Offset(60, pageData.height), marginPaint);
    }
    for (double y = spacing; y < pageData.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(pageData.width, y), paint);
    }
  }

  void _paintGridBackground(Canvas canvas, double spacing, Paint paint) {
    for (double y = spacing; y < pageData.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(pageData.width, y), paint);
    }
    for (double x = spacing; x < pageData.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, pageData.height), paint);
    }
  }

  void _paintDottedBackground(Canvas canvas, double spacing, Paint paint) {
    final dotPaint = Paint()
      ..color = Color(pageData.layers.background.lineColor)
      ..style = PaintingStyle.fill;
    for (double y = spacing; y < pageData.height; y += spacing) {
      for (double x = spacing; x < pageData.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.5, dotPaint);
      }
    }
  }

  void _paintCornellBackground(Canvas canvas, double spacing, Paint paint) {
    // Cornell notes: horizontal lines + left margin (cue column) + bottom summary area
    final w = pageData.width;
    final h = pageData.height;
    const cueWidth = 120.0;
    const summaryHeight = 140.0;

    // Horizontal lines in note-taking area
    for (double y = spacing + 50; y < h - summaryHeight; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(w, y), paint);
    }

    // Vertical cue column line
    final cuePaint = Paint()
      ..color = const Color(0xFFE8B4B8)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(cueWidth, 0), Offset(cueWidth, h - summaryHeight), cuePaint);

    // Horizontal summary separator
    canvas.drawLine(Offset(0, h - summaryHeight), Offset(w, h - summaryHeight), cuePaint);

    // Title area separator at top
    final titlePaint = Paint()
      ..color = const Color(0xFFB0B0B0)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 50), Offset(w, 50), titlePaint);
  }

  void _paintIsometricBackground(Canvas canvas, double spacing, Paint paint) {
    final w = pageData.width;
    final h = pageData.height;
    final isoHeight = spacing * sqrt(3) / 2;

    // Horizontal rows of triangles
    for (double y = 0; y < h + isoHeight; y += isoHeight) {
      // Horizontal line
      canvas.drawLine(Offset(0, y), Offset(w, y), paint);
    }
    // Diagonal lines (/)
    for (double x = -h; x < w + spacing; x += spacing) {
      canvas.drawLine(
        Offset(x, h),
        Offset(x + h / tan(pi / 3), 0),
        paint,
      );
    }
    // Diagonal lines (\)
    for (double x = 0; x < w + h; x += spacing) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - h / tan(pi / 3), h),
        paint,
      );
    }
  }

  void _paintMusicBackground(Canvas canvas, double spacing, Paint paint) {
    // Music staff: groups of 5 lines with larger gaps between staves
    final w = pageData.width;
    final h = pageData.height;
    const staffLines = 5;
    final staffGap = spacing * 4; // gap between staves
    double y = 60; // top margin

    while (y + staffLines * spacing < h - 40) {
      // Draw 5 lines (one staff)
      for (int i = 0; i < staffLines; i++) {
        canvas.drawLine(Offset(30, y + i * spacing), Offset(w - 30, y + i * spacing), paint);
      }
      y += staffLines * spacing + staffGap;
    }
  }

  /// Fill a variable-width ribbon along the given interpolated points.
  /// Extracted from the fountain-pen code so the calligraphy branch can
  /// share the same crisp-edge polygon fill.
  void _paintVariableWidthRibbon(
      Canvas canvas, List<_InterpolatedPoint> interp, Color fillColor) {
    final count = interp.length;
    if (count < 2) return;
    final nxArr = List<double>.filled(count, 0.0);
    final nyArr = List<double>.filled(count, 0.0);
    for (int i = 0; i < count; i++) {
      double dx, dy;
      if (i == 0) {
        dx = interp[1].x - interp[0].x;
        dy = interp[1].y - interp[0].y;
      } else if (i == count - 1) {
        dx = interp[i].x - interp[i - 1].x;
        dy = interp[i].y - interp[i - 1].y;
      } else {
        dx = interp[i + 1].x - interp[i - 1].x;
        dy = interp[i + 1].y - interp[i - 1].y;
      }
      final len = sqrt(dx * dx + dy * dy);
      if (len > 0.0001) {
        nxArr[i] = -dy / len;
        nyArr[i] = dx / len;
      } else if (i > 0) {
        nxArr[i] = nxArr[i - 1];
        nyArr[i] = nyArr[i - 1];
      }
    }
    final path = Path();
    final hw0 = (interp[0].w * 0.5).clamp(0.2, 999.0);
    path.moveTo(interp[0].x + nxArr[0] * hw0, interp[0].y + nyArr[0] * hw0);
    for (int i = 1; i < count; i++) {
      final hw = (interp[i].w * 0.5).clamp(0.2, 999.0);
      path.lineTo(interp[i].x + nxArr[i] * hw, interp[i].y + nyArr[i] * hw);
    }
    for (int i = count - 1; i >= 0; i--) {
      final hw = (interp[i].w * 0.5).clamp(0.2, 999.0);
      path.lineTo(interp[i].x - nxArr[i] * hw, interp[i].y - nyArr[i] * hw);
    }
    path.close();
    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
    canvas.drawCircle(Offset(interp.first.x, interp.first.y), hw0, paint);
    final lastHw = (interp.last.w * 0.5).clamp(0.2, 999.0);
    canvas.drawCircle(Offset(interp.last.x, interp.last.y), lastHw, paint);
  }

  void _paintStroke(Canvas canvas, StrokeData stroke) {
    if (stroke.points.isEmpty) return;
    // Single-point stroke = Apple Pencil quick tap. Render as a filled
    // circle proportional to baseWidth so dots actually appear (the old
    // `< 2` early-return silently dropped them).
    if (stroke.points.length == 1) {
      final p = stroke.points.first;
      final color = Color(stroke.color);
      final paint = Paint()
        ..color = color.withValues(
            alpha: stroke.isHighlighter ? 0.35 : stroke.opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      // Match the per-tool width math: pen ~baseWidth, brush 1.5×, etc.
      double radius = stroke.baseWidth * 0.55;
      if (stroke.toolType == 'brush') radius *= 1.4;
      if (stroke.toolType == 'highlighter') radius = stroke.baseWidth * 0.6;
      // Pressure factor (Apple Pencil reports light pressure on quick taps).
      final pf = 0.4 + p.pressure * 0.6;
      canvas.drawCircle(Offset(p.x, p.y), (radius * pf).clamp(0.5, 50.0), paint);
      return;
    }

    final color = Color(stroke.color);

    if (stroke.isHighlighter) {
      // Highlighter: flat width, semi-transparent, multiply blend
      final paint = Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.baseWidth
        ..blendMode = BlendMode.multiply
        ..isAntiAlias = true;
      final path = Path()..moveTo(stroke.points[0].x, stroke.points[0].y);
      for (int i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].x, stroke.points[i].y);
      }
      canvas.drawPath(path, paint);
      return;
    }

    // Ballpoint: simple line-by-line with mild pressure
    if (stroke.toolType == 'ballpoint') {
      final paint = Paint()
        ..color = color.withValues(alpha: stroke.opacity)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final interpolated = _catmullRomInterpolate(stroke.points, zoom);
      for (int i = 0; i < interpolated.length - 1; i++) {
        final p0 = interpolated[i];
        final p1 = interpolated[i + 1];
        final avgP = (p0.pressure + p1.pressure) / 2;
        paint.strokeWidth = stroke.baseWidth * (0.6 + avgP * 0.4);
        canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
      }
      return;
    }

    // Brush: wide, soft edges via multiple overlapping strokes
    if (stroke.toolType == 'brush') {
      final interpolated = _catmullRomInterpolate(stroke.points, zoom);
      for (int layer = 0; layer < 3; layer++) {
        final alpha = (stroke.opacity * (0.3 - layer * 0.08)).clamp(0.05, 1.0);
        final widthMul = 1.0 + layer * 0.6;
        final paint = Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        for (int i = 0; i < interpolated.length - 1; i++) {
          final p0 = interpolated[i];
          final p1 = interpolated[i + 1];
          final avgP = (p0.pressure + p1.pressure) / 2;
          paint.strokeWidth = stroke.baseWidth * widthMul * (0.2 + avgP * 0.8);
          canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
        }
      }
      return;
    }

    // ── Calligraphy brush (variable-width, velocity + angle driven) ──
    // Like a dip-pen nib: thick when moving slowly OR along the nib axis
    // (NE→SW by convention), thin on fast movement orthogonal to the nib.
    // Renders as a filled polygon between the two offset edges (same
    // technique as fountain pen below) so edges stay crisp at any zoom.
    if (stroke.toolType == 'calligraphy') {
      final n = stroke.points.length;
      // Nib angle: 45° (NE-SW), traditional italic calligraphy direction.
      // Strokes moving perpendicular to this axis get the full nib width;
      // strokes moving parallel to it get the thin side.
      const nibAngle = -pi / 4;
      final nibDx = cos(nibAngle);
      final nibDy = sin(nibAngle);

      final velocities = List<double>.filled(n, 0.0);
      final angleFactors = List<double>.filled(n, 1.0);
      for (int i = 1; i < n; i++) {
        final dx = stroke.points[i].x - stroke.points[i - 1].x;
        final dy = stroke.points[i].y - stroke.points[i - 1].y;
        final len = sqrt(dx * dx + dy * dy);
        velocities[i] = len;
        if (len > 0.001) {
          // cos of angle between motion direction and nib axis, 0..1.
          // Parallel (cos = 1) → thin side, perpendicular (cos = 0) → fat side.
          final cosTheta = ((dx * nibDx + dy * nibDy) / len).abs();
          // Smooth falloff: thin at 20% base when parallel, 150% when perp.
          angleFactors[i] = 1.5 - 1.3 * cosTheta;
        }
      }
      if (n > 1) {
        velocities[0] = velocities[1];
        angleFactors[0] = angleFactors[1];
      }

      final calligWidths = List<double>.filled(n, stroke.baseWidth);
      for (int i = 0; i < n; i++) {
        // Velocity scales from 2.2× (stationary) down to 0.25× (very fast).
        // The wide range is what makes calligraphy feel "inked": a slow
        // pause on a letter apex deposits a visible blob.
        final vF = (2.2 - (velocities[i] / 10.0).clamp(0.0, 1.95));
        final pF = 0.4 + stroke.points[i].pressure * 0.6;
        calligWidths[i] = stroke.baseWidth * pF * vF * angleFactors[i];
      }
      // Heavy smoothing (4 passes) because angle changes point-to-point
      // would otherwise create sawtooth edges on the rendered ribbon.
      for (int pass = 0; pass < 4; pass++) {
        for (int i = 1; i < n - 1; i++) {
          calligWidths[i] = (calligWidths[i - 1] + calligWidths[i] * 2 + calligWidths[i + 1]) / 4;
        }
      }

      final interp = _catmullRomAdaptiveWithWidth(stroke.points, calligWidths, zoom);
      if (interp.length < 2) return;
      _paintVariableWidthRibbon(canvas, interp, color.withValues(alpha: stroke.opacity));
      return;
    }

    // ── Fountain pen (default "pen") ──
    // Compute per-original-point width from pressure + velocity, smooth,
    // then interpolate through adaptive Catmull-Rom.
    //
    // Width-modulation curves tuned (0.36.x) to feel closer to GoodNotes:
    //   - pressure: 0.45 → 1.05 (was 0.15 → 1.0). The old lower bound made
    //     the stroke "anorexic" at light touches and especially at the
    //     start/end of a fast scribble where Apple Pencil reports near-zero
    //     pressure. Keeping more body matches the visual weight of a real
    //     fountain pen and the "pen" tool in GoodNotes.
    //   - velocity: clamp thinning at 30% (was 50%). A 50% reduction at
    //     speed turned the middle of fast cursive strokes into hairlines;
    //     30% preserves character without losing all the velocity feedback.
    //   - 3 smoothing passes (was 2). Cheaper than it looks (operates on
    //     N original points, not interpolated) and removes the small
    //     width-step artifacts visible on slow zoomed-in strokes.
    final n = stroke.points.length;

    // Compute velocity from original points (independent of interpolation)
    final velocities = List<double>.filled(n, 0.0);
    for (int i = 1; i < n; i++) {
      final dx = stroke.points[i].x - stroke.points[i - 1].x;
      final dy = stroke.points[i].y - stroke.points[i - 1].y;
      velocities[i] = sqrt(dx * dx + dy * dy);
    }
    if (n > 1) velocities[0] = velocities[1];

    final rawWidths = List<double>.filled(n, stroke.baseWidth);
    for (int i = 0; i < n; i++) {
      final velocityFactor = (1.0 - (velocities[i] / 20.0).clamp(0.0, 0.30));
      final pressureFactor = 0.45 + stroke.points[i].pressure * 0.60;
      rawWidths[i] = stroke.baseWidth * pressureFactor * velocityFactor;
    }
    // Smooth widths on original points (cheap — only N points).
    for (int pass = 0; pass < 3; pass++) {
      for (int i = 1; i < n - 1; i++) {
        rawWidths[i] = (rawWidths[i - 1] + rawWidths[i] * 2 + rawWidths[i + 1]) / 4;
      }
    }

    final interpolated = _catmullRomAdaptiveWithWidth(stroke.points, rawWidths, zoom);
    if (interpolated.length < 2) return;

    // ── Render as overlapping round-capped line segments ──
    //
    // The previous implementation built a filled polygon ribbon with per-
    // point perpendicular normals. At sharp peaks (e.g. the top of a
    // cursive U) the chord between i-1 and i+1 collapsed to nearly zero,
    // the normal vector became degenerate, and the polygon either pinched
    // to zero width — visible as a "detached" gap mid-stroke — or self-
    // intersected into a rectangle-shaped artifact at the peak.
    //
    // Drawing short line segments with strokeCap=round and strokeJoin=round
    // sidesteps both problems: round caps blend consecutive segments
    // smoothly even when the direction reverses, and there's no polygon
    // edge to misalign. The width still varies smoothly because each
    // segment uses its own strokeWidth from the interpolated widths.
    final paint = Paint()
      ..color = color.withValues(alpha: stroke.opacity)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final count = interpolated.length;
    for (int i = 0; i < count - 1; i++) {
      final p0 = interpolated[i];
      final p1 = interpolated[i + 1];
      final w = ((p0.w + p1.w) * 0.5).clamp(0.4, 999.0);
      paint.strokeWidth = w;
      canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
    }
  }

  List<StrokePoint> _catmullRomInterpolate(List<StrokePoint> points, double zoom) {
    if (points.length < 4) return points;
    final result = <StrokePoint>[];

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];

      final dx = p2.x - p1.x;
      final dy = p2.y - p1.y;
      final dist = sqrt(dx * dx + dy * dy);
      // Proportional to screen-space distance: ~1 segment per 3 screen pixels
      final segments = max(2, min(24, (dist * zoom / 3.0).ceil()));

      for (int j = 0; j < segments; j++) {
        final t = j / segments;
        final t2 = t * t;
        final t3 = t2 * t;

        final x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        final y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);
        final pressure = p1.pressure + (p2.pressure - p1.pressure) * t;

        result.add(StrokePoint(x: x, y: y, pressure: pressure));
      }
    }
    result.add(points.last);
    return result;
  }

  /// Adaptive Catmull-Rom interpolation that carries pre-computed stroke width.
  /// Segments proportional to screen-space distance for smooth rendering at any zoom.
  List<_InterpolatedPoint> _catmullRomAdaptiveWithWidth(
      List<StrokePoint> points, List<double> widths, double zoom) {
    if (points.length < 4) {
      return List.generate(points.length, (i) =>
          _InterpolatedPoint(points[i].x, points[i].y, points[i].pressure, widths[i]));
    }
    final result = <_InterpolatedPoint>[];

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];
      final w1 = widths[i];
      final w2 = widths[i + 1];

      final dx = p2.x - p1.x;
      final dy = p2.y - p1.y;
      final dist = sqrt(dx * dx + dy * dy);
      // Proportional to screen-space distance: ~1 segment per 3 screen pixels
      final segments = max(2, min(24, (dist * zoom / 3.0).ceil()));

      for (int j = 0; j < segments; j++) {
        final t = j / segments;
        final t2 = t * t;
        final t3 = t2 * t;

        final x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        final y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);
        final pressure = p1.pressure + (p2.pressure - p1.pressure) * t;
        final w = w1 + (w2 - w1) * t;

        result.add(_InterpolatedPoint(x, y, pressure, w));
      }
    }
    result.add(_InterpolatedPoint(
        points.last.x, points.last.y, points.last.pressure, widths.last));
    return result;
  }

  void _paintText(Canvas canvas, TextData textData) {
    final style = ui.TextStyle(
      color: Color(textData.color),
      fontSize: textData.fontSize,
      fontFamily: textData.fontFamily,
      fontWeight: textData.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: textData.italic ? FontStyle.italic : FontStyle.normal,
    );

    final paragraphStyle = ui.ParagraphStyle(
      textAlign: textData.alignment == 'center' ? TextAlign.center : textData.alignment == 'right' ? TextAlign.right : TextAlign.left,
    );

    final builder = ui.ParagraphBuilder(paragraphStyle)..pushStyle(style)..addText(textData.content);
    final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: textData.width));
    canvas.drawParagraph(paragraph, Offset(textData.x, textData.y));
  }

  void _paintImage(Canvas canvas, ImageData imageData) {
    canvas.save();
    if (imageData.rotation != 0) {
      final cx = imageData.x + imageData.width / 2;
      final cy = imageData.y + imageData.height / 2;
      canvas.translate(cx, cy);
      canvas.rotate(imageData.rotation);
      canvas.translate(-cx, -cy);
    }
    // Horizontal mirror around the image's vertical centerline.
    if (imageData.flipHorizontal) {
      final cx = imageData.x + imageData.width / 2;
      final cy = imageData.y + imageData.height / 2;
      canvas.translate(cx, cy);
      canvas.scale(-1, 1);
      canvas.translate(-cx, -cy);
    }

    final rect = Rect.fromLTWH(imageData.x, imageData.y, imageData.width, imageData.height);

    // Try to render from cache
    final cachedImage = imageCache[imageData.assetPath];
    if (cachedImage != null) {
      final srcRect = Rect.fromLTWH(0, 0, cachedImage.width.toDouble(), cachedImage.height.toDouble());
      // Use medium quality (bilinear with mipmaps) so that imported raster
      // content — especially old handwritten notes exported from OneNote —
      // degrades gracefully when zoomed in. `low` (nearest-neighbour) made
      // small strokes look blocky at high zoom.
      final imgPaint = Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true
        ..color = Colors.white.withValues(alpha: imageData.opacity);
      canvas.drawImageRect(cachedImage, srcRect, rect, imgPaint);
    } else {
      // Placeholder
      final placeholderPaint = Paint()..color = Colors.grey.shade200..style = PaintingStyle.fill;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), placeholderPaint);

      final borderPaint = Paint()
        ..color = Colors.grey.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), borderPaint);

      // Image icon in center
      final iconSize = min(imageData.width, imageData.height) * 0.3;
      final iconPaint = Paint()..color = Colors.grey.shade500..style = PaintingStyle.stroke..strokeWidth = 2;
      final center = rect.center;
      canvas.drawCircle(center, iconSize * 0.3, iconPaint);
      // Mountain icon
      final path = Path()
        ..moveTo(center.dx - iconSize * 0.4, center.dy + iconSize * 0.3)
        ..lineTo(center.dx - iconSize * 0.1, center.dy - iconSize * 0.1)
        ..lineTo(center.dx + iconSize * 0.1, center.dy + iconSize * 0.15)
        ..lineTo(center.dx + iconSize * 0.3, center.dy - iconSize * 0.2)
        ..lineTo(center.dx + iconSize * 0.5, center.dy + iconSize * 0.3);
      canvas.drawPath(path, iconPaint);

      // File name text
      final nameStyle = ui.TextStyle(color: const Color(0xFF757575), fontSize: 10);
      final nameBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: TextAlign.center))
        ..pushStyle(nameStyle)
        ..addText(imageData.assetPath.length > 20 ? '${imageData.assetPath.substring(0, 17)}...' : imageData.assetPath);
      final nameParagraph = nameBuilder.build()..layout(ui.ParagraphConstraints(width: imageData.width - 8));
      canvas.drawParagraph(nameParagraph, Offset(imageData.x + 4, imageData.y + imageData.height - 16));
    }

    canvas.restore();
  }

  void _paintShape(Canvas canvas, ShapeData shape) {
    final strokePaint = Paint()
      ..color = Color(shape.strokeColor)
      ..style = PaintingStyle.stroke
      ..strokeWidth = shape.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    Paint? fillPaint;
    if (shape.fillColor != null) {
      fillPaint = Paint()..color = Color(shape.fillColor!)..style = PaintingStyle.fill;
    }

    canvas.save();
    if (shape.rotation != 0) {
      final cx = (shape.x1 + shape.x2) / 2;
      final cy = (shape.y1 + shape.y2) / 2;
      canvas.translate(cx, cy);
      canvas.rotate(shape.rotation);
      canvas.translate(-cx, -cy);
    }

    switch (shape.shapeType) {
      case 'rectangle':
        final rect = Rect.fromPoints(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2));
        if (fillPaint != null) canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, strokePaint);
        break;
      case 'circle':
        final center = Offset((shape.x1 + shape.x2) / 2, (shape.y1 + shape.y2) / 2);
        final radius = (shape.x2 - shape.x1).abs() / 2;
        if (fillPaint != null) canvas.drawCircle(center, radius, fillPaint);
        canvas.drawCircle(center, radius, strokePaint);
        break;
      case 'line':
        canvas.drawLine(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2), strokePaint);
        break;
      case 'arrow':
        canvas.drawLine(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2), strokePaint);
        _paintArrowHead(canvas, shape, strokePaint);
        break;
      case 'triangle':
        final tLeft = min(shape.x1, shape.x2);
        final tRight = max(shape.x1, shape.x2);
        final tTop = min(shape.y1, shape.y2);
        final tBottom = max(shape.y1, shape.y2);
        final tPath = Path()
          ..moveTo((tLeft + tRight) / 2, tTop)
          ..lineTo(tLeft, tBottom)
          ..lineTo(tRight, tBottom)
          ..close();
        if (fillPaint != null) canvas.drawPath(tPath, fillPaint);
        canvas.drawPath(tPath, strokePaint);
        break;
      case 'rhombus':
        final rLeft = min(shape.x1, shape.x2);
        final rRight = max(shape.x1, shape.x2);
        final rTop = min(shape.y1, shape.y2);
        final rBottom = max(shape.y1, shape.y2);
        final rCx = (rLeft + rRight) / 2;
        final rCy = (rTop + rBottom) / 2;
        final rPath = Path()
          ..moveTo(rCx, rTop)       // top
          ..lineTo(rRight, rCy)     // right
          ..lineTo(rCx, rBottom)    // bottom
          ..lineTo(rLeft, rCy)      // left
          ..close();
        if (fillPaint != null) canvas.drawPath(rPath, fillPaint);
        canvas.drawPath(rPath, strokePaint);
        break;
      case 'xy_plane':
        // XY plane: two arrows from an origin, with optional grid lines
        final ox = shape.x1;
        final oy = shape.y2; // origin at bottom-left
        final ex = shape.x2;
        final ey = shape.y1;
        final w = ex - ox;
        final h = oy - ey;
        final arrowSz = (min(w, h) * 0.06).clamp(6.0, 16.0);
        // X axis
        canvas.drawLine(Offset(ox, oy), Offset(ex, oy), strokePaint);
        _paintArrowHeadPoints(canvas, Offset(ex - arrowSz * 2, oy), Offset(ex, oy), arrowSz, strokePaint);
        // Y axis
        canvas.drawLine(Offset(ox, oy), Offset(ox, ey), strokePaint);
        _paintArrowHeadPoints(canvas, Offset(ox, ey + arrowSz * 2), Offset(ox, ey), arrowSz, strokePaint);
        // Labels using canvas.drawParagraph is complex; draw small tick marks
        final tickPaint = Paint()
          ..color = Color(shape.strokeColor).withValues(alpha: 0.4)
          ..strokeWidth = 0.8
          ..style = PaintingStyle.stroke;
        const numTicks = 5;
        for (int i = 1; i <= numTicks; i++) {
          final tx = ox + i * w / (numTicks + 1);
          canvas.drawLine(Offset(tx, oy - 4), Offset(tx, oy + 4), tickPaint);
          final ty = oy - i * h / (numTicks + 1);
          canvas.drawLine(Offset(ox - 4, ty), Offset(ox + 4, ty), tickPaint);
        }
        break;
    }
    canvas.restore();
  }

  void _paintArrowHead(Canvas canvas, ShapeData shape, Paint paint) {
    final angle = atan2(shape.y2 - shape.y1, shape.x2 - shape.x1);
    const arrowLen = 15.0;
    const arrowAngle = 0.5;
    final path = Path()
      ..moveTo(shape.x2, shape.y2)
      ..lineTo(shape.x2 - arrowLen * cos(angle - arrowAngle), shape.y2 - arrowLen * sin(angle - arrowAngle))
      ..moveTo(shape.x2, shape.y2)
      ..lineTo(shape.x2 - arrowLen * cos(angle + arrowAngle), shape.y2 - arrowLen * sin(angle + arrowAngle));
    canvas.drawPath(path, paint);
  }

  void _paintArrowHeadPoints(Canvas canvas, Offset from, Offset to, double size, Paint paint) {
    final angle = atan2(to.dy - from.dy, to.dx - from.dx);
    const spread = 0.5;
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - size * cos(angle - spread), to.dy - size * sin(angle - spread))
      ..moveTo(to.dx, to.dy)
      ..lineTo(to.dx - size * cos(angle + spread), to.dy - size * sin(angle + spread));
    canvas.drawPath(path, paint);
  }

  void _paintShapePreview(Canvas canvas, (Offset, Offset, String) preview) {
    final (start, end, shapeType) = preview;
    final previewPaint = Paint()
      ..color = const Color(0xFF2196F3).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..isAntiAlias = true;

    switch (shapeType) {
      case 'rectangle':
        canvas.drawRect(Rect.fromPoints(start, end), previewPaint);
        break;
      case 'circle':
        final center = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
        final radius = (end - start).distance / 2;
        canvas.drawCircle(center, radius, previewPaint);
        break;
      case 'line':
        canvas.drawLine(start, end, previewPaint);
        break;
      case 'arrow':
        canvas.drawLine(start, end, previewPaint);
        break;
      case 'triangle':
        final tLeft = min(start.dx, end.dx);
        final tRight = max(start.dx, end.dx);
        final tTop = min(start.dy, end.dy);
        final tBottom = max(start.dy, end.dy);
        final tPath = Path()
          ..moveTo((tLeft + tRight) / 2, tTop)
          ..lineTo(tLeft, tBottom)
          ..lineTo(tRight, tBottom)
          ..close();
        canvas.drawPath(tPath, previewPaint);
        break;
      case 'rhombus':
        final rLeft = min(start.dx, end.dx);
        final rRight = max(start.dx, end.dx);
        final rTop = min(start.dy, end.dy);
        final rBottom = max(start.dy, end.dy);
        final rCx = (rLeft + rRight) / 2;
        final rCy = (rTop + rBottom) / 2;
        final rPath = Path()
          ..moveTo(rCx, rTop)
          ..lineTo(rRight, rCy)
          ..lineTo(rCx, rBottom)
          ..lineTo(rLeft, rCy)
          ..close();
        canvas.drawPath(rPath, previewPaint);
        break;
      case 'xy_plane':
        canvas.drawLine(Offset(start.dx, end.dy), Offset(end.dx, end.dy), previewPaint);
        canvas.drawLine(Offset(start.dx, end.dy), Offset(start.dx, start.dy), previewPaint);
        break;
    }
  }

  void _paintRecognizedShapePreview(Canvas canvas, ShapeData shape) {
    // Render the shape itself
    _paintShape(canvas, shape);

    // Subtle glow border to indicate it's a recognized shape
    final glowPaint = Paint()
      ..color = const Color(0xFF4CAF50).withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = shape.strokeWidth + 4
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    switch (shape.shapeType) {
      case 'line':
        canvas.drawLine(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2), glowPaint);
        break;
      case 'circle':
        final rect = Rect.fromPoints(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2));
        canvas.drawOval(rect, glowPaint);
        break;
      default:
        final rect = Rect.fromPoints(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2));
        canvas.drawRect(rect, glowPaint);
    }
  }

  void _paintLassoPathFromPoints(Canvas canvas, List<Offset> points) {
    // Build the full closed path
    final fullPath = Path()..moveTo(points[0].dx, points[0].dy);
    for (int i = 1; i < points.length; i++) {
      fullPath.lineTo(points[i].dx, points[i].dy);
    }
    fullPath.close(); // Always close back to start

    // Fill inside lasso path with translucent blue
    final fillPaint = Paint()
      ..color = const Color(0xFF90CAF9).withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawPath(fullPath, fillPaint);

    // Dashed grey stroke outline (marching ants style)
    final dashPaint = Paint()
      ..color = const Color(0xFF616161)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..isAntiAlias = true;

    // Compute total path length and draw dashes
    final allPoints = [...points, points[0]]; // include closing segment
    const dashLen = 6.0;
    const gapLen = 4.0;
    double accumulator = 0;
    bool drawing = true;

    for (int i = 0; i < allPoints.length - 1; i++) {
      final p0 = allPoints[i];
      final p1 = allPoints[i + 1];
      final dx = p1.dx - p0.dx;
      final dy = p1.dy - p0.dy;
      final segLen = sqrt(dx * dx + dy * dy);
      if (segLen == 0) continue;
      final ux = dx / segLen;
      final uy = dy / segLen;
      double traveled = 0;

      while (traveled < segLen) {
        final needed = drawing ? dashLen - accumulator : gapLen - accumulator;
        final available = segLen - traveled;
        final step = min(needed, available);

        if (drawing) {
          final startX = p0.dx + ux * traveled;
          final startY = p0.dy + uy * traveled;
          final endX = p0.dx + ux * (traveled + step);
          final endY = p0.dy + uy * (traveled + step);
          canvas.drawLine(Offset(startX, startY), Offset(endX, endY), dashPaint);
        }

        accumulator += step;
        traveled += step;
        if (accumulator >= (drawing ? dashLen : gapLen)) {
          drawing = !drawing;
          accumulator = 0;
        }
      }
    }
  }

  void _paintSelectionBounds(Canvas canvas) {
    final sel = lassoSelection!;
    final center = sel.bounds.center;
    // Apply scale around center, then translate by dragOffset
    final scaledBounds = Rect.fromCenter(
      center: center,
      width: sel.bounds.width * sel.scale,
      height: sel.bounds.height * sel.scale,
    ).translate(sel.dragOffset.dx, sel.dragOffset.dy);
    final selRect = scaledBounds.inflate(4);

    canvas.save();
    if (sel.rotation != 0.0) {
      final transformCenter = scaledBounds.center;
      canvas.translate(transformCenter.dx, transformCenter.dy);
      canvas.rotate(sel.rotation);
      canvas.translate(-transformCenter.dx, -transformCenter.dy);
    }

    // Dashed border
    _paintDashedRect(canvas, selRect, const Color(0xFF2196F3), 1.0);
    
    canvas.restore();
  }

  void _paintDashedRect(Canvas canvas, Rect rect, Color color, double strokeWidth) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    const double dashLen = 5.0;
    const double gapLen = 3.0;
    for (final edge in [
      [rect.topLeft, rect.topRight],
      [rect.topRight, rect.bottomRight],
      [rect.bottomRight, rect.bottomLeft],
      [rect.bottomLeft, rect.topLeft],
    ]) {
      final start = edge[0];
      final end = edge[1];
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      final length = (Offset(dx, dy)).distance;
      if (length == 0) continue;
      final ux = dx / length;
      final uy = dy / length;
      double d = 0;
      while (d < length) {
        final segEnd = (d + dashLen).clamp(0.0, length);
        canvas.drawLine(
          Offset(start.dx + ux * d, start.dy + uy * d),
          Offset(start.dx + ux * segEnd, start.dy + uy * segEnd),
          paint,
        );
        d += dashLen + gapLen;
      }
    }
  }

  // Cached sort to avoid O(n log n) per paint frame
  static List<ContentElement>? _cachedSortedContent;
  static List<ContentElement>? _cachedSourceContent;

  static List<ContentElement> _getSortedContent(List<ContentElement> content) {
    if (identical(content, _cachedSourceContent) && _cachedSortedContent != null) {
      return _cachedSortedContent!;
    }
    _cachedSourceContent = content;
    _cachedSortedContent = List<ContentElement>.from(content)
      ..sort((a, b) {
        final aZ = a.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        final bZ = b.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        return aZ.compareTo(bZ);
      });
    return _cachedSortedContent!;
  }

  @override
  bool shouldRepaint(covariant CanvasRenderEngine oldDelegate) {
    // Repaint when data changes; the repaintNotifier handles active stroke changes
    return pageData != oldDelegate.pageData ||
        activeStroke != oldDelegate.activeStroke ||
        lassoSelection != oldDelegate.lassoSelection ||
        lassoPath != oldDelegate.lassoPath ||
        shapePreview != oldDelegate.shapePreview ||
        recognizedShapePreview != oldDelegate.recognizedShapePreview ||
        zoom != oldDelegate.zoom ||
        panOffset != oldDelegate.panOffset ||
        imageCache != oldDelegate.imageCache;
  }
}

/// Lightweight struct for Catmull-Rom interpolated points with pre-computed width.
class _InterpolatedPoint {
  final double x, y, pressure, w;
  const _InterpolatedPoint(this.x, this.y, this.pressure, this.w);
}
