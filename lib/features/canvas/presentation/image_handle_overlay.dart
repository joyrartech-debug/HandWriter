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
  /// Called once when any drag/rotate/resize gesture ends or is cancelled.
  /// Lets the host commit a locally-tracked transform back to Riverpod
  /// in a single state update instead of one per pointer-move event.
  final VoidCallback? onDragEnd;
  final VoidCallback? onCrop;
  final VoidCallback? onBringToFront;
  final VoidCallback? onSendToBack;
  final VoidCallback? onToggleLock;
  final VoidCallback? onEditComment;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onFlipHorizontal;
  final bool isLocked;
  final bool hasComment;
  final bool isFlipped;

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
    this.onDragEnd,
    this.onCrop,
    this.onBringToFront,
    this.onSendToBack,
    this.onToggleLock,
    this.onEditComment,
    this.onCopy,
    this.onCut,
    this.onFlipHorizontal,
    this.isLocked = false,
    this.hasComment = false,
    this.isFlipped = false,
  });

  @override
  State<ImageHandleOverlay> createState() => _ImageHandleOverlayState();
}

class _ImageHandleOverlayState extends State<ImageHandleOverlay> {
  Offset _dragStart = Offset.zero;
  Offset _rotationCenter = Offset.zero;
  double _lastRotationAngle = 0;

  static const _handleSize = 12.0;
  static const _rotateHandleDistance = 30.0;

  @override
  Widget build(BuildContext context) {
    final bounds = widget.bounds;
    if (bounds.width < 1 || bounds.height < 1) return const SizedBox.shrink();

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
            onPanStart: widget.isLocked ? null : (d) {
              _dragStart = d.globalPosition;
              widget.onDragStart?.call();
            },
            onPanUpdate: widget.isLocked ? null : (d) {
              final delta = d.globalPosition - _dragStart;
              _dragStart = d.globalPosition;
              widget.onMove(delta);
            },
            onPanEnd: widget.isLocked ? null : (_) => widget.onDragEnd?.call(),
            onPanCancel: widget.isLocked ? null : () => widget.onDragEnd?.call(),
          ),
        ),

        // Corner/edge/rotate handles (hidden when locked)
        if (!widget.isLocked) ...[
          // Corner resize handles (aspect-ratio preserving)
          _buildCornerHandle(bounds.topLeft, 'tl'),
          _buildCornerHandle(bounds.topRight, 'tr'),
          _buildCornerHandle(bounds.bottomLeft, 'bl'),
          _buildCornerHandle(bounds.bottomRight, 'br'),

          // Edge midpoint resize handles (free deform)
          _buildEdgeHandle(Offset(bounds.center.dx, bounds.top), 'tm'),
          _buildEdgeHandle(Offset(bounds.center.dx, bounds.bottom), 'bm'),
          _buildEdgeHandle(Offset(bounds.left, bounds.center.dy), 'ml'),
          _buildEdgeHandle(Offset(bounds.right, bounds.center.dy), 'mr'),

          // Rotate handle (above top center)
          _buildRotateHandle(bounds),
        ],

        // Action buttons bar (above the rotate handle)
        Positioned(
          left: bounds.left,
          top: bounds.top - _rotateHandleDistance - 24 - 38,
          child: _buildActionBar(),
        ),
      ],
    );

    // Apply rotation around the element center if rotated
    if (widget.rotation != 0) {
      handleStack = Transform.rotate(
        angle: widget.rotation,
        alignment: Alignment.topLeft,
        origin: bounds.center,
        child: handleStack,
      );
    }

    // Wrap in a non-rotated widget so _outerKey gives us global coords
    // unaffected by the internal Transform.rotate.
    return handleStack;
  }

  Widget _buildCornerHandle(Offset position, String handleId) {
    return Positioned(
      left: position.dx - _handleSize / 2,
      top: position.dy - _handleSize / 2,
      child: GestureDetector(
        onPanStart: (d) {
          _dragStart = d.globalPosition;
          widget.onDragStart?.call();
        },
        onPanUpdate: (d) {
          final delta = d.globalPosition - _dragStart;
          _dragStart = d.globalPosition;
          _handleCornerResize(handleId, delta);
        },
        onPanEnd: (_) => widget.onDragEnd?.call(),
        onPanCancel: () => widget.onDragEnd?.call(),
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
          _dragStart = d.globalPosition;
          widget.onDragStart?.call();
        },
        onPanUpdate: (d) {
          final delta = d.globalPosition - _dragStart;
          _dragStart = d.globalPosition;
          _handleEdgeResize(handleId, delta);
        },
        onPanEnd: (_) => widget.onDragEnd?.call(),
        onPanCancel: () => widget.onDragEnd?.call(),
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
              // Compute element center in global coords from the handle position.
              // The handle is above the element center by a known distance
              // (half the element height + the handle gap). After rotation,
              // this vector is rotated, so we undo it to find the center.
              final dist = widget.bounds.height / 2 + _rotateHandleDistance;
              _rotationCenter = d.globalPosition + Offset(
                -dist * sin(widget.rotation),
                dist * cos(widget.rotation),
              );
              _lastRotationAngle = atan2(
                d.globalPosition.dy - _rotationCenter.dy,
                d.globalPosition.dx - _rotationCenter.dx,
              );
              widget.onDragStart?.call();
            },
            onPanUpdate: (d) {
              final currentAngle = atan2(
                d.globalPosition.dy - _rotationCenter.dy,
                d.globalPosition.dx - _rotationCenter.dx,
              );
              // Incremental delta, normalized to handle atan2 wrapping at ±π
              var delta = currentAngle - _lastRotationAngle;
              if (delta > pi) delta -= 2 * pi;
              if (delta < -pi) delta += 2 * pi;
              _lastRotationAngle = currentAngle;
              widget.onRotate(delta);
            },
            onPanEnd: (_) => widget.onDragEnd?.call(),
            onPanCancel: () => widget.onDragEnd?.call(),
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
    return Builder(builder: (context) {
      final surface = Theme.of(context).colorScheme.surface;
      final shadow = Theme.of(context).colorScheme.shadow;
      final inactiveIcon = Theme.of(context).colorScheme.onSurfaceVariant;
      return Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [BoxShadow(color: shadow.withValues(alpha: 0.15), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onCrop != null && !widget.isLocked) ...[
              _actionBtn(Icons.crop_rounded, Colors.blueGrey, widget.onCrop!, 'Ritaglia'),
              _divider(),
            ],
            if (widget.onBringToFront != null) ...[
              _actionBtn(Icons.flip_to_front_rounded, Colors.indigo, widget.onBringToFront!, 'In primo piano'),
              _divider(),
            ],
            if (widget.onSendToBack != null) ...[
              _actionBtn(Icons.flip_to_back_rounded, Colors.indigo, widget.onSendToBack!, 'Dietro a tutto'),
              _divider(),
            ],
            if (widget.onToggleLock != null) ...[
              _actionBtn(
                widget.isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                widget.isLocked ? Colors.orange : inactiveIcon,
                widget.onToggleLock!,
                widget.isLocked ? 'Sblocca' : 'Blocca',
              ),
              _divider(),
            ],
            if (!widget.isLocked) ...[
              _actionBtn(Icons.delete_outline_rounded, Colors.red, widget.onDelete, 'Elimina'),
              _divider(),
            ],
            // Overflow menu for less-used actions (comment, reflect, copy, cut)
            if (_hasOverflowActions()) ...[
              _buildOverflowMenu(),
              _divider(),
            ],
            _actionBtn(Icons.close_rounded, inactiveIcon, widget.onDeselect, 'Deseleziona'),
          ],
        ),
      );
    });
  }

  Widget _divider() => Builder(builder: (context) {
    return Container(width: 1, height: 24, color: Theme.of(context).colorScheme.outlineVariant);
  });

  bool _hasOverflowActions() {
    return widget.onEditComment != null ||
        (widget.onFlipHorizontal != null && !widget.isLocked) ||
        widget.onCopy != null ||
        (widget.onCut != null && !widget.isLocked);
  }

  Widget _buildOverflowMenu() {
    return Builder(builder: (context) {
      final inactiveIcon = Theme.of(context).colorScheme.onSurfaceVariant;
      return Tooltip(
        message: 'Altre azioni',
        child: PopupMenuButton<String>(
          tooltip: '',
          padding: EdgeInsets.zero,
          icon: Icon(Icons.more_vert_rounded, size: 18, color: inactiveIcon),
          onSelected: (value) {
            switch (value) {
              case 'comment':
                widget.onEditComment?.call();
                break;
              case 'flip':
                widget.onFlipHorizontal?.call();
                break;
              case 'copy':
                widget.onCopy?.call();
                break;
              case 'cut':
                widget.onCut?.call();
                break;
            }
          },
          itemBuilder: (ctx) => [
            if (widget.onEditComment != null)
              PopupMenuItem<String>(
                value: 'comment',
                child: Row(children: [
                  Icon(
                    widget.hasComment ? Icons.comment_rounded : Icons.comment_outlined,
                    size: 18,
                    color: widget.hasComment ? Colors.green : inactiveIcon,
                  ),
                  const SizedBox(width: 10),
                  const Text('Commento'),
                ]),
              ),
            if (widget.onFlipHorizontal != null && !widget.isLocked)
              PopupMenuItem<String>(
                value: 'flip',
                child: Row(children: [
                  Icon(
                    Icons.flip_rounded,
                    size: 18,
                    color: widget.isFlipped ? Colors.blue : inactiveIcon,
                  ),
                  const SizedBox(width: 10),
                  Text(widget.isFlipped ? 'Rifletti H ✓' : 'Rifletti H'),
                ]),
              ),
            if (widget.onCopy != null)
              const PopupMenuItem<String>(
                value: 'copy',
                child: Row(children: [
                  Icon(Icons.copy_rounded, size: 18, color: Colors.blueGrey),
                  SizedBox(width: 10),
                  Text('Copia'),
                ]),
              ),
            if (widget.onCut != null && !widget.isLocked)
              const PopupMenuItem<String>(
                value: 'cut',
                child: Row(children: [
                  Icon(Icons.content_cut_rounded, size: 18, color: Colors.blueGrey),
                  SizedBox(width: 10),
                  Text('Taglia'),
                ]),
              ),
          ],
        ),
      );
    });
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
    if (b.width <= 0 || b.height <= 0) return;

    // Project the dragged-corner displacement onto the diagonal direction
    // anchor→corner. This gives a smooth, monotonic scale factor: small
    // wobbles produce small scale changes (no flicker), pure-axis drags
    // grow at full speed (no 50% sluggishness), and opposite-direction
    // jitter never cancels to zero (the previous diag-sum bug). Aspect
    // ratio is preserved by definition because we scale along the
    // diagonal of the current bounds.
    late Offset anchor;
    late Offset corner;
    switch (handle) {
      case 'tl': anchor = b.bottomRight; corner = b.topLeft;     break;
      case 'tr': anchor = b.bottomLeft;  corner = b.topRight;    break;
      case 'bl': anchor = b.topRight;    corner = b.bottomLeft;  break;
      case 'br': anchor = b.topLeft;     corner = b.bottomRight; break;
      default: return;
    }
    final diag = corner - anchor;          // original diagonal vector
    final diagLenSq = diag.dx * diag.dx + diag.dy * diag.dy;
    if (diagLenSq <= 0) return;

    // Where the corner would be after this tick's delta.
    final newCorner = corner + delta;
    final newVec = newCorner - anchor;
    // Projection of new vector onto the original diagonal, expressed as
    // a fraction of the original length: scale = (new·diag) / |diag|².
    final scale = (newVec.dx * diag.dx + newVec.dy * diag.dy) / diagLenSq;
    if (scale <= 0) return;  // would invert the rect

    final newW = b.width * scale;
    final newH = b.height * scale;
    Rect newBounds;
    switch (handle) {
      case 'tl': newBounds = Rect.fromLTWH(anchor.dx - newW, anchor.dy - newH, newW, newH); break;
      case 'tr': newBounds = Rect.fromLTWH(anchor.dx,        anchor.dy - newH, newW, newH); break;
      case 'bl': newBounds = Rect.fromLTWH(anchor.dx - newW, anchor.dy,        newW, newH); break;
      case 'br': newBounds = Rect.fromLTWH(anchor.dx,        anchor.dy,        newW, newH); break;
      default: return;
    }
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
