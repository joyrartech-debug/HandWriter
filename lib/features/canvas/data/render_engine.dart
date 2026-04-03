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

    // 3. Content elements
    final sortedContent = List<ContentElement>.from(pageData.layers.content)
      ..sort((a, b) {
        final aZ = a.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        final bZ = b.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
        return aZ.compareTo(bZ);
      });

    final selectedIds = lassoSelection?.selectedIds ?? [];
    final selDragOffset = lassoSelection?.dragOffset ?? Offset.zero;
    final selRotation = lassoSelection?.rotation ?? 0.0;
    final selCenter = lassoSelection != null
        ? (lassoSelection!.bounds.center + selDragOffset)
        : Offset.zero;

    for (final element in sortedContent) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      final isSelected = selectedIds.contains(id);

      // If this element is being moved/rotated via lasso, apply transform
      if (isSelected && (selDragOffset != Offset.zero || selRotation != 0.0)) {
        canvas.save();
        canvas.translate(selDragOffset.dx, selDragOffset.dy);
        if (selRotation != 0.0) {
          canvas.translate(selCenter.dx - selDragOffset.dx, selCenter.dy - selDragOffset.dy);
          canvas.rotate(selRotation);
          canvas.translate(-(selCenter.dx - selDragOffset.dx), -(selCenter.dy - selDragOffset.dy));
        }
      }

      element.map(
        stroke: (e) => _paintStroke(canvas, e.data),
        text: (e) => _paintText(canvas, e.data),
        image: (e) => _paintImage(canvas, e.data),
        shape: (e) => _paintShape(canvas, e.data),
      );

      if (isSelected) {
        _paintSelectionHighlight(canvas, element);
        if (selDragOffset != Offset.zero || selRotation != 0.0) canvas.restore();
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
    }
  }

  void _paintLinedBackground(Canvas canvas, double spacing, Paint paint, {required bool showMargin}) {
    if (showMargin) {
      final marginPaint = Paint()
        ..color = const Color(0xFFE8B4B8)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      canvas.drawLine(Offset(60, 0), Offset(60, pageData.height), marginPaint);
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

  void _paintStroke(Canvas canvas, StrokeData stroke) {
    if (stroke.points.length < 2) return;

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
      final interpolated = _catmullRomInterpolate(stroke.points);
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
      final interpolated = _catmullRomInterpolate(stroke.points);
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

    // ── Fountain pen (default "pen") ──
    // Use per-segment variable-width strokes to avoid polygon seam artifacts
    // that can appear as dashed/gray lines at large pen widths.
    final interpolated = _catmullRomInterpolate(stroke.points);
    if (interpolated.length < 2) return;

    final paint = Paint()
      ..color = color.withValues(alpha: stroke.opacity)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    final widths = List<double>.filled(interpolated.length, stroke.baseWidth);
    for (int i = 0; i < interpolated.length; i++) {
      final p = interpolated[i];
      double velocity = 0;
      if (i > 0) {
        final prev = interpolated[i - 1];
        velocity = sqrt(pow(p.x - prev.x, 2) + pow(p.y - prev.y, 2));
      }
      final velocityFactor = (1.0 - (velocity / 25.0).clamp(0.0, 0.55));
      final pressureFactor = 0.15 + p.pressure * 0.85;
      widths[i] = stroke.baseWidth * pressureFactor * velocityFactor;
    }

    for (int pass = 0; pass < 2; pass++) {
      for (int i = 1; i < widths.length - 1; i++) {
        widths[i] = (widths[i - 1] + widths[i] * 2 + widths[i + 1]) / 4;
      }
    }

    for (int i = 0; i < interpolated.length - 1; i++) {
      final p0 = interpolated[i];
      final p1 = interpolated[i + 1];
      paint.strokeWidth = ((widths[i] + widths[i + 1]) * 0.5).clamp(0.4, 999.0);
      canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
    }

    canvas.drawCircle(
      Offset(interpolated.first.x, interpolated.first.y),
      (widths.first * 0.5).clamp(0.2, 999.0),
      Paint()
        ..color = color.withValues(alpha: stroke.opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
    canvas.drawCircle(
      Offset(interpolated.last.x, interpolated.last.y),
      (widths.last * 0.5).clamp(0.2, 999.0),
      Paint()
        ..color = color.withValues(alpha: stroke.opacity)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }

  List<StrokePoint> _catmullRomInterpolate(List<StrokePoint> points) {
    if (points.length < 4) return points;
    final result = <StrokePoint>[];
    // Smooth Catmull-Rom interpolation — 5 segments per span
    const segments = 5;

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i > 0 ? points[i - 1] : points[i];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];

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

    final rect = Rect.fromLTWH(imageData.x, imageData.y, imageData.width, imageData.height);

    // Try to render from cache
    final cachedImage = imageCache[imageData.assetPath];
    if (cachedImage != null) {
      final srcRect = Rect.fromLTWH(0, 0, cachedImage.width.toDouble(), cachedImage.height.toDouble());
      final imgPaint = Paint()
        ..filterQuality = FilterQuality.low
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
        final radius = Offset(shape.x2 - shape.x1, shape.y2 - shape.y1).distance / 2;
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
        final path = Path()
          ..moveTo((shape.x1 + shape.x2) / 2, shape.y1)
          ..lineTo(shape.x1, shape.y2)
          ..lineTo(shape.x2, shape.y2)
          ..close();
        if (fillPaint != null) canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, strokePaint);
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
        final path = Path()
          ..moveTo((start.dx + end.dx) / 2, start.dy)
          ..lineTo(start.dx, end.dy)
          ..lineTo(end.dx, end.dy)
          ..close();
        canvas.drawPath(path, previewPaint);
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
        final rect = Rect.fromLTRB(shape.x1, shape.y1, shape.x2, shape.y2);
        canvas.drawOval(rect, glowPaint);
        break;
      default:
        final rect = Rect.fromLTRB(shape.x1, shape.y1, shape.x2, shape.y2);
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
    final bounds = sel.bounds.translate(sel.dragOffset.dx, sel.dragOffset.dy);

    final borderPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawRect(bounds.inflate(4), borderPaint);

    // Corner dots
    final dotPaint = Paint()..color = const Color(0xFF2196F3)..style = PaintingStyle.fill;
    for (final corner in [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]) {
      canvas.drawCircle(corner, 4, dotPaint);
    }
  }

  void _paintSelectionHighlight(Canvas canvas, ContentElement element) {
    final bounds = _getElementBounds(element);
    if (bounds == null) return;

    // Stronger blue fill
    final highlightPaint = Paint()
      ..color = const Color(0xFF2196F3).withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawRect(bounds.inflate(5), highlightPaint);

    // Visible blue border
    final borderPaint = Paint()
      ..color = const Color(0xFF2196F3).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(bounds.inflate(5), borderPaint);

    // Corner dots
    final dotPaint = Paint()..color = const Color(0xFF1976D2)..style = PaintingStyle.fill;
    for (final corner in [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]) {
      canvas.drawCircle(corner, 3.5, dotPaint);
    }
  }

  Rect? _getElementBounds(ContentElement element) {
    return element.map(
      stroke: (e) {
        if (e.data.points.isEmpty) return null;
        final xs = e.data.points.map((p) => p.x);
        final ys = e.data.points.map((p) => p.y);
        return Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
      },
      text: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      image: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      shape: (e) => Rect.fromPoints(Offset(e.data.x1, e.data.y1), Offset(e.data.x2, e.data.y2)),
    );
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
