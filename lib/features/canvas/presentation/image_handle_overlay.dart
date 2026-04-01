import 'dart:math';
import 'package:flutter/material.dart';

/// Overlay widget that shows move/resize/rotate/delete handles around a selected element.
class ImageHandleOverlay extends StatefulWidget {
  final Rect bounds;
  final double rotation;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Rect> onResize;
  final ValueChanged<double> onRotate;
  final VoidCallback onDelete;
  final VoidCallback onDeselect;
  final VoidCallback? onDragStart;

  const ImageHandleOverlay({
    super.key,
    required this.bounds,
    required this.rotation,
    required this.onMove,
    required this.onResize,
    required this.onRotate,
    required this.onDelete,
    required this.onDeselect,
    this.onDragStart,
  });

  @override
  State<ImageHandleOverlay> createState() => _ImageHandleOverlayState();
}

class _ImageHandleOverlayState extends State<ImageHandleOverlay> {
  String? _activeHandle;
  Offset _dragStart = Offset.zero;
  Rect _initialBounds = Rect.zero;
  double _initialRotation = 0;

  static const _handleSize = 12.0;
  static const _rotateHandleDistance = 30.0;

  @override
  Widget build(BuildContext context) {
    final bounds = widget.bounds;
    if (bounds.width < 1 || bounds.height < 1) return const SizedBox.shrink();

    // Wrap all handles in a Transform.rotate around the element center
    // so the selection rect visually follows the rotated element.
    final center = bounds.center;

    Widget handleStack = Stack(
      children: [
        // Selection border (dashed)
        Positioned(
          left: bounds.left - 1,
          top: bounds.top - 1,
          width: bounds.width + 2,
          height: bounds.height + 2,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _DashedBorderPainter(),
            ),
          ),
        ),

        // Move handle (center) — drag anywhere inside to move
        Positioned(
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (d) {
              _activeHandle = 'move';
              _dragStart = d.globalPosition;
              widget.onDragStart?.call();
            },
            onPanUpdate: (d) {
              final delta = d.globalPosition - _dragStart;
              _dragStart = d.globalPosition;
              widget.onMove(delta);
            },
            onPanEnd: (_) => _activeHandle = null,
          ),
        ),

        // Corner resize handles
        _buildCornerHandle(bounds.topLeft, 'tl'),
        _buildCornerHandle(bounds.topRight, 'tr'),
        _buildCornerHandle(bounds.bottomLeft, 'bl'),
        _buildCornerHandle(bounds.bottomRight, 'br'),

        // Edge midpoint resize handles
        _buildEdgeHandle(Offset(bounds.center.dx, bounds.top), 'tm'),
        _buildEdgeHandle(Offset(bounds.center.dx, bounds.bottom), 'bm'),
        _buildEdgeHandle(Offset(bounds.left, bounds.center.dy), 'ml'),
        _buildEdgeHandle(Offset(bounds.right, bounds.center.dy), 'mr'),

        // Rotate handle (above top center)
        _buildRotateHandle(bounds),

        // Action buttons bar (above the element)
        Positioned(
          left: bounds.left,
          top: bounds.top - 40,
          child: _buildActionBar(),
        ),
      ],
    );

    // Apply rotation around the element center if rotated
    if (widget.rotation != 0) {
      handleStack = Transform.rotate(
        angle: widget.rotation,
        alignment: Alignment.center,
        origin: Offset(center.dx - MediaQuery.of(context).size.width / 2,
                        center.dy - MediaQuery.of(context).size.height / 2),
        child: handleStack,
      );
    }

    return handleStack;
  }

  Widget _buildCornerHandle(Offset position, String handleId) {
    return Positioned(
      left: position.dx - _handleSize / 2,
      top: position.dy - _handleSize / 2,
      child: GestureDetector(
        onPanStart: (d) {
          _activeHandle = handleId;
          _dragStart = d.globalPosition;
          _initialBounds = widget.bounds;
        },
        onPanUpdate: (d) {
          final delta = d.globalPosition - _dragStart;
          _dragStart = d.globalPosition;
          _handleCornerResize(handleId, delta);
        },
        onPanEnd: (_) => _activeHandle = null,
        child: Container(
          width: _handleSize,
          height: _handleSize,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.blue, width: 2),
            borderRadius: BorderRadius.circular(2),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 2)],
          ),
        ),
      ),
    );
  }

  Widget _buildEdgeHandle(Offset position, String handleId) {
    final isHorizontal = handleId == 'tm' || handleId == 'bm';
    return Positioned(
      left: position.dx - (isHorizontal ? 10 : 4),
      top: position.dy - (isHorizontal ? 4 : 10),
      child: GestureDetector(
        onPanStart: (d) {
          _activeHandle = handleId;
          _dragStart = d.globalPosition;
          _initialBounds = widget.bounds;
        },
        onPanUpdate: (d) {
          final delta = d.globalPosition - _dragStart;
          _dragStart = d.globalPosition;
          _handleEdgeResize(handleId, delta);
        },
        onPanEnd: (_) => _activeHandle = null,
        child: Container(
          width: isHorizontal ? 20 : 8,
          height: isHorizontal ? 8 : 20,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.blue, width: 1.5),
            borderRadius: BorderRadius.circular(3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2)],
          ),
        ),
      ),
    );
  }

  Widget _buildRotateHandle(Rect bounds) {
    final centerTop = Offset(bounds.center.dx, bounds.top - _rotateHandleDistance);
    return Positioned(
      left: centerTop.dx - 12,
      top: centerTop.dy - 12,
      child: Column(
        children: [
          GestureDetector(
            onPanStart: (d) {
              _activeHandle = 'rotate';
              _dragStart = d.globalPosition;
              _initialRotation = widget.rotation;
            },
            onPanUpdate: (d) {
              final center = widget.bounds.center;
              final startAngle = atan2(_dragStart.dy - center.dy, _dragStart.dx - center.dx);
              final currentAngle = atan2(d.globalPosition.dy - center.dy, d.globalPosition.dx - center.dx);
              final deltaAngle = currentAngle - startAngle;
              _dragStart = d.globalPosition;
              widget.onRotate(deltaAngle);
            },
            onPanEnd: (_) => _activeHandle = null,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blue, width: 2),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 3)],
              ),
              child: const Icon(Icons.rotate_right_rounded, size: 14, color: Colors.blue),
            ),
          ),
          // Line connecting rotate handle to element
          IgnorePointer(
            child: Container(
              width: 1.5,
              height: _rotateHandleDistance - 12,
              color: Colors.blue.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _actionBtn(Icons.delete_outline_rounded, Colors.red, widget.onDelete, 'Elimina'),
          Container(width: 1, height: 24, color: Colors.grey.shade200),
          _actionBtn(Icons.close_rounded, Colors.grey.shade700, widget.onDeselect, 'Deseleziona'),
        ],
      ),
    );
  }

  Widget _actionBtn(IconData icon, Color color, VoidCallback onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  void _handleCornerResize(String handle, Offset delta) {
    final b = widget.bounds;
    Rect newBounds;
    switch (handle) {
      case 'tl':
        newBounds = Rect.fromLTRB(b.left + delta.dx, b.top + delta.dy, b.right, b.bottom);
        break;
      case 'tr':
        newBounds = Rect.fromLTRB(b.left, b.top + delta.dy, b.right + delta.dx, b.bottom);
        break;
      case 'bl':
        newBounds = Rect.fromLTRB(b.left + delta.dx, b.top, b.right, b.bottom + delta.dy);
        break;
      case 'br':
        newBounds = Rect.fromLTRB(b.left, b.top, b.right + delta.dx, b.bottom + delta.dy);
        break;
      default:
        return;
    }
    // Enforce minimum size
    if (newBounds.width > 20 && newBounds.height > 20) {
      widget.onResize(newBounds);
    }
  }

  void _handleEdgeResize(String handle, Offset delta) {
    final b = widget.bounds;
    Rect newBounds;
    switch (handle) {
      case 'tm':
        newBounds = Rect.fromLTRB(b.left, b.top + delta.dy, b.right, b.bottom);
        break;
      case 'bm':
        newBounds = Rect.fromLTRB(b.left, b.top, b.right, b.bottom + delta.dy);
        break;
      case 'ml':
        newBounds = Rect.fromLTRB(b.left + delta.dx, b.top, b.right, b.bottom);
        break;
      case 'mr':
        newBounds = Rect.fromLTRB(b.left, b.top, b.right + delta.dx, b.bottom);
        break;
      default:
        return;
    }
    if (newBounds.width > 20 && newBounds.height > 20) {
      widget.onResize(newBounds);
    }
  }
}

class _DashedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const dashWidth = 6.0;
    const dashSpace = 4.0;

    // Top
    _drawDashedLine(canvas, Offset.zero, Offset(size.width, 0), paint, dashWidth, dashSpace);
    // Right
    _drawDashedLine(canvas, Offset(size.width, 0), Offset(size.width, size.height), paint, dashWidth, dashSpace);
    // Bottom
    _drawDashedLine(canvas, Offset(0, size.height), Offset(size.width, size.height), paint, dashWidth, dashSpace);
    // Left
    _drawDashedLine(canvas, Offset.zero, Offset(0, size.height), paint, dashWidth, dashSpace);
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint, double dashWidth, double dashSpace) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = sqrt(dx * dx + dy * dy);
    final unitX = dx / len;
    final unitY = dy / len;

    double drawn = 0;
    bool drawing = true;
    while (drawn < len) {
      final segLen = drawing ? dashWidth : dashSpace;
      final nextDrawn = (drawn + segLen).clamp(0.0, len);
      if (drawing) {
        canvas.drawLine(
          Offset(start.dx + unitX * drawn, start.dy + unitY * drawn),
          Offset(start.dx + unitX * nextDrawn, start.dy + unitY * nextDrawn),
          paint,
        );
      }
      drawn = nextDrawn;
      drawing = !drawing;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
