import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/features/canvas/presentation/canvas_toolbar.dart';
import 'package:handwriter/features/canvas/presentation/image_handle_overlay.dart';
import 'package:handwriter/features/canvas/presentation/symbol_library_panel.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:super_clipboard/super_clipboard.dart';

class CanvasScreen extends ConsumerStatefulWidget {
  const CanvasScreen({super.key});

  @override
  ConsumerState<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends ConsumerState<CanvasScreen> {
  bool _isSaving = false;
  late bool _stylusOnlyDrawing;
  bool _isTouchPanning = false;

  // Pinch-to-zoom state
  int _activePointers = 0;
  double _baseZoom = 1.0;
  Offset _lastFocalPoint = Offset.zero;

  // Lasso drag
  bool _isDraggingSelection = false;
  Offset _lastLassoDragPos = Offset.zero;

  // Hold-to-recognize shape (GoodNotes style)
  Timer? _holdRecognizeTimer;
  bool _shapeRecognizedDuringHold = false;
  Offset _lastHoldCheckPos = Offset.zero;

  // Drag-left to create new page / drag-right to go to previous page
  bool _showNewPageHint = false;
  bool _showPrevPageHint = false;
  bool _showNextPageHint = false;

  // Stylus barrel button temporary eraser
  bool _barrelButtonErasing = false;
  CanvasTool? _barrelButtonPreviousTool;

  // Long-press context menu for touch
  Timer? _longPressTimer;
  Offset _longPressGlobalPos = Offset.zero;
  Offset _longPressLocalPos = Offset.zero;
  bool _longPressFired = false;

  // Track last stroke activity to suppress long-press menu while drawing
  DateTime _lastStrokeActivity = DateTime(0);

  // Double-tap detection for element selection
  DateTime _lastTapTime = DateTime(0);
  Offset _lastTapPos = Offset.zero;

  // Cached canvas size for pointer-up page-drag commit
  Size _lastCanvasSize = Size.zero;

  // ── High-performance active stroke notifier ──
  final _activeStrokeNotifier = _ActiveStrokeNotifier();
  // ── High-performance lasso path notifier (avoids Riverpod rebuild per point) ──
  final _lassoPathNotifier = _LassoPathNotifier();

  // ── Auto-save timer ──
  Timer? _autoSaveTimer;
  static const _autoSaveInterval = Duration(seconds: 30);

  // Key for the canvas Stack to convert coordinates properly
  final _canvasStackKey = GlobalKey();

  // ── Keyboard shortcuts ──
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _stylusOnlyDrawing = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
         defaultTargetPlatform == TargetPlatform.android);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startAutoSave();
  }

  @override
  void dispose() {
    _activeStrokeNotifier.dispose();
    _lassoPathNotifier.dispose();
    _autoSaveTimer?.cancel();
    _holdRecognizeTimer?.cancel();
    _longPressTimer?.cancel();
    _focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _startAutoSave() {
    _autoSaveTimer = Timer.periodic(_autoSaveInterval, (_) {
      final state = ref.read(canvasProvider);
      if (state != null && state.isDirty && !_isSaving) {
        _save(silent: true);
      }
    });
  }

  Future<void> _save({bool silent = false}) async {
    if (_isSaving) return;
    _isSaving = true;
    if (!silent && mounted) setState(() {});
    try {
      await ref.read(canvasProvider.notifier).save();
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Salvato!'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
      }
    } finally {
      _isSaving = false;
      if (!silent && mounted) setState(() {});
    }
  }

  // ── Keyboard shortcut handler ──

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (ctrl) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyZ:
          if (shift) {
            ref.read(canvasProvider.notifier).redo();
          } else {
            ref.read(canvasProvider.notifier).undo();
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyY:
          ref.read(canvasProvider.notifier).redo();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyS:
          _save();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyC:
          ref.read(canvasProvider.notifier).copySelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyX:
          ref.read(canvasProvider.notifier).cutSelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyV:
          _pasteFromClipboard();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyD:
          ref.read(canvasProvider.notifier).duplicateSelection();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyA:
          ref.read(canvasProvider.notifier).selectAll();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.digit0:
          ref.read(canvasProvider.notifier).resetZoom();
          return KeyEventResult.handled;
        default:
          break;
      }
    }

    // Delete / Backspace
    if (event.logicalKey == LogicalKeyboardKey.delete || event.logicalKey == LogicalKeyboardKey.backspace) {
      final state = ref.read(canvasProvider);
      if (state?.selectedElementId != null) {
        ref.read(canvasProvider.notifier).deleteElement(state!.selectedElementId!);
        return KeyEventResult.handled;
      }
      if (state?.lassoSelection != null) {
        ref.read(canvasProvider.notifier).deleteSelection();
        return KeyEventResult.handled;
      }
    }

    // Escape — deselect / cancel pending symbol / cancel pending paste
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      final state = ref.read(canvasProvider);
      if (state?.pendingSymbol != null) {
        ref.read(canvasProvider.notifier).clearPendingSymbol();
        return KeyEventResult.handled;
      }
      if (state?.pendingPaste == true) {
        ref.read(canvasProvider.notifier).cancelPendingPaste();
        return KeyEventResult.handled;
      }
      ref.read(canvasProvider.notifier).clearSelection();
      ref.read(canvasProvider.notifier).deselectElement();
      return KeyEventResult.handled;
    }

    // P — pen tool
    if (event.logicalKey == LogicalKeyboardKey.keyP && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.pen);
      return KeyEventResult.handled;
    }
    // E — eraser
    if (event.logicalKey == LogicalKeyboardKey.keyE && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.eraserStroke);
      return KeyEventResult.handled;
    }
    // L — lasso select
    if (event.logicalKey == LogicalKeyboardKey.keyL && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.lasso);
      return KeyEventResult.handled;
    }
    // H — hand/pan tool
    if (event.logicalKey == LogicalKeyboardKey.keyH && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.pan);
      return KeyEventResult.handled;
    }
    // T — text tool
    if (event.logicalKey == LogicalKeyboardKey.keyT && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.text);
      return KeyEventResult.handled;
    }
    // B — brush tool
    if (event.logicalKey == LogicalKeyboardKey.keyB && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.brush);
      return KeyEventResult.handled;
    }
    // S (without Ctrl) — shape tool
    if (event.logicalKey == LogicalKeyboardKey.keyS && !ctrl) {
      ref.read(canvasProvider.notifier).setTool(CanvasTool.shape);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<bool> _onWillPop() async {
    final state = ref.read(canvasProvider);
    if (state != null && state.isDirty) {
      final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Modifiche non salvate'),
          content: const Text('Vuoi salvare prima di uscire?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Scarta')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Annulla')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Salva')),
          ],
        ),
      );
      if (result == 'cancel') return false;
      if (result == 'save') await _save();
    }
    ref.read(canvasProvider.notifier).closeNotebook();
    return true;
  }

  // ── Drag-left/right page navigation ──

  void _checkPageDrag(CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    final renderScale = min(canvasSize.width / pageW, canvasSize.height / pageH);
    final scaledW = pageW * renderScale;
    final centerOffsetX = (canvasSize.width - scaledW) / 2;

    // Right edge of the page in screen coords
    final pageRightScreen = (scaledW * state.zoom) + state.panOffset.dx + (centerOffsetX * state.zoom);
    // Left edge of the page in screen coords
    final pageLeftScreen = state.panOffset.dx + (centerOffsetX * state.zoom);

    final filtered = state.filteredPageIndices;
    final pos = filtered.indexOf(state.currentPageIndex);
    final hasNext = pos >= 0 && pos + 1 < filtered.length;
    final hasPrev = pos > 0;
    final isLastPage = pos >= 0 && pos == filtered.length - 1;

    // ─ Swipe LEFT: show next page or new page preview ─
    if (pageRightScreen < canvasSize.width * 0.68) {
      if (_showPrevPageHint) setState(() => _showPrevPageHint = false);
      if (isLastPage) {
        if (!_showNewPageHint) setState(() { _showNewPageHint = true; _showNextPageHint = false; });
      } else if (hasNext) {
        if (!_showNextPageHint) setState(() { _showNextPageHint = true; _showNewPageHint = false; });
      }
    }
    // ─ Swipe RIGHT: show previous page preview ─
    else if (pageLeftScreen > canvasSize.width * 0.32 && hasPrev) {
      if (!_showPrevPageHint) setState(() { _showPrevPageHint = true; _showNewPageHint = false; _showNextPageHint = false; });
    } else {
      _clearPageHints();
    }
  }

  /// Commit page navigation on pointer-up if page edge is past the commit
  /// threshold (50% of screen), otherwise just dismiss the preview.
  void _commitOrCancelPageDrag(CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    final renderScale = min(canvasSize.width / pageW, canvasSize.height / pageH);
    final scaledW = pageW * renderScale;
    final centerOffsetX = (canvasSize.width - scaledW) / 2;

    final pageRightScreen = (scaledW * state.zoom) + state.panOffset.dx + (centerOffsetX * state.zoom);
    final pageLeftScreen = state.panOffset.dx + (centerOffsetX * state.zoom);

    final filtered = state.filteredPageIndices;
    final pos = filtered.indexOf(state.currentPageIndex);
    final hasNext = pos >= 0 && pos + 1 < filtered.length;
    final hasPrev = pos > 0;
    final isLastPage = pos >= 0 && pos == filtered.length - 1;

    // Commit threshold: page edge must be past 50% of screen
    if (pageRightScreen < canvasSize.width * 0.50) {
      if (isLastPage) {
        ref.read(canvasProvider.notifier).addPage();
      } else if (hasNext) {
        ref.read(canvasProvider.notifier).nextPage();
      }
    } else if (pageLeftScreen > canvasSize.width * 0.50 && hasPrev) {
      ref.read(canvasProvider.notifier).prevPage();
    }

    _clearPageHints();
  }

  void _clearPageHints() {
    if (_showNewPageHint || _showPrevPageHint || _showNextPageHint) {
      setState(() {
        _showNewPageHint = false;
        _showPrevPageHint = false;
        _showNextPageHint = false;
      });
    }
  }

  void _startLongPressTimer(Offset globalPos, Offset localPos, CanvasState state, Size canvasSize) {
    _cancelLongPressTimer();
    // Suppress context menu if user was drawing recently (palm rest while writing)
    if (DateTime.now().difference(_lastStrokeActivity).inMilliseconds < 1500) return;
    _longPressGlobalPos = globalPos;
    _longPressLocalPos = localPos;
    _longPressFired = false;
    _longPressTimer = Timer(const Duration(milliseconds: 500), () {
      _longPressTimer = null;
      _longPressFired = true;
      final latestState = ref.read(canvasProvider);
      if (latestState != null) {
        _showContextMenu(globalPos, localPos, latestState, canvasSize);
      }
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  // ── Coordinate conversion ──

  Offset _toPageCoords(Offset localPos, CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    final renderScale = min(canvasSize.width / pageW, canvasSize.height / pageH);
    final scaledW = pageW * renderScale;
    final scaledH = pageH * renderScale;
    final centerOffsetX = (canvasSize.width - scaledW) / 2;
    final centerOffsetY = (canvasSize.height - scaledH) / 2;
    final unPanned = localPos - state.panOffset - Offset(centerOffsetX * state.zoom, centerOffsetY * state.zoom);
    final unZoomed = unPanned / state.zoom;
    return Offset(unZoomed.dx / renderScale, unZoomed.dy / renderScale);
  }

  Offset _toScreenCoords(Offset pagePos, CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    final renderScale = min(canvasSize.width / pageW, canvasSize.height / pageH);
    final scaledW = pageW * renderScale;
    final scaledH = pageH * renderScale;
    final centerOffsetX = (canvasSize.width - scaledW) / 2;
    final centerOffsetY = (canvasSize.height - scaledH) / 2;
    final scaled = Offset(pagePos.dx * renderScale, pagePos.dy * renderScale);
    return scaled * state.zoom + state.panOffset + Offset(centerOffsetX * state.zoom, centerOffsetY * state.zoom);
  }

  /// Returns true if this tap is a double-tap (close in position and time to the last tap).
  bool _isDoubleTap(Offset position) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTapTime).inMilliseconds;
    final dist = (position - _lastTapPos).distance;
    _lastTapTime = now;
    _lastTapPos = position;
    return elapsed < 400 && dist < 30;
  }

  double _getRenderScale(CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    return min(canvasSize.width / pageW, canvasSize.height / pageH);
  }

  // ── Pointer handling ──

  bool _isDrawLikeTool(CanvasTool tool) {
    return tool == CanvasTool.pen ||
        tool == CanvasTool.ballpoint ||
        tool == CanvasTool.brush ||
        tool == CanvasTool.highlighter ||
        tool == CanvasTool.eraserStandard ||
        tool == CanvasTool.eraserStroke ||
        tool == CanvasTool.lasso ||
        tool == CanvasTool.shape;
  }

  bool _shouldTouchPan(PointerDeviceKind kind, CanvasTool tool) {
    return _stylusOnlyDrawing && kind == PointerDeviceKind.touch && _isDrawLikeTool(tool);
  }

  void _onPointerDown(PointerDownEvent event, CanvasState state, Size canvasSize) {
    _activePointers++;
    if (_activePointers >= 2) {
      // Cancel any active stroke when multi-touch starts (pinch-to-zoom)
      if (_activeStrokeNotifier.isActive) {
        _activeStrokeNotifier.clear();
        ref.read(canvasProvider.notifier).cancelStroke();
      }
      // Stop touch-panning so the scale handler takes over exclusively
      _isTouchPanning = false;
      // Cancel long-press timer so context menu doesn't fire during pinch
      _cancelLongPressTimer();
      return;
    }

    final tool = state.currentTool;

    // Middle mouse button → always pan
    if (event.kind == PointerDeviceKind.mouse && event.buttons == kMiddleMouseButton) {
      _isTouchPanning = true;
      _lastFocalPoint = event.position;
      return;
    }

    // Stylus barrel button (secondary button on stylus) → cancel or erase
    if (event.kind == PointerDeviceKind.stylus && event.buttons == kSecondaryButton) {
      // If pending symbol, cancel placement
      if (state.pendingSymbol != null) {
        ref.read(canvasProvider.notifier).clearPendingSymbol();
        return;
      }
      // If there's a selection, deselect
      if (state.selectedElementId != null) {
        ref.read(canvasProvider.notifier).deselectElement();
        return;
      }
      if (state.lassoSelection != null) {
        ref.read(canvasProvider.notifier).clearSelection();
        return;
      }
      // Otherwise use barrel button as temporary stroke eraser
      final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
      _barrelButtonErasing = true;
      _barrelButtonPreviousTool = state.currentTool;
      ref.read(canvasProvider.notifier).setTool(CanvasTool.eraserStroke);
      ref.read(canvasProvider.notifier).startStroke(pagePos, 0.5);
      return;
    }

    final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
    final pressure = event.pressure > 0 ? event.pressure : 0.5;

    // Touch pan: only if no selected image is under the finger
    if (_shouldTouchPan(event.kind, tool)) {
      // If there's a selected element and we're touching it, let the overlay handle it
      if (state.selectedElementId != null) {
        final selBounds = _getSelectedElementBounds(state);
        // Expand bounds to include the action bar and handles above the element.
        // The action bar sits ~92px above in screen coords; convert to page coords.
        final scale = state.zoom * _getRenderScale(state, canvasSize);
        final topPadding = 100.0 / scale; // action bar + rotation handle
        final sidePadding = 20.0 / scale; // resize handles
        final extendedBounds = selBounds == null ? null : Rect.fromLTRB(
          selBounds.left - sidePadding,
          selBounds.top - topPadding,
          selBounds.right + sidePadding,
          selBounds.bottom + sidePadding,
        );
        if (extendedBounds != null && extendedBounds.contains(pagePos)) {
          // Fall through to selected element handling below
        } else {
          // Double-tap on an image to select it (single tap just pans)
          if (_isDoubleTap(event.localPosition)) {
            final tappedImage = _findImageOrShapeAt(state, pagePos);
            if (tappedImage != null) {
              ref.read(canvasProvider.notifier).selectElement(tappedImage);
              return;
            }
          }
          // Tapped away from selection and no other image → deselect
          ref.read(canvasProvider.notifier).deselectElement();
          _isTouchPanning = true;
          _lastFocalPoint = event.position;
          // Don't show context menu if stylus is actively drawing (palm rest)
          if (!_activeStrokeNotifier.isActive) {
            _startLongPressTimer(event.position, event.localPosition, state, canvasSize);
          }
          return;
        }
      } else {
        // No selection — double-tap an image to select it
        if (_isDoubleTap(event.localPosition)) {
          final tappedImage = _findImageOrShapeAt(state, pagePos);
          if (tappedImage != null) {
            ref.read(canvasProvider.notifier).selectElement(tappedImage);
            return;
          }
        }
        _isTouchPanning = true;
        _lastFocalPoint = event.position;
        // Don't show context menu if stylus is actively drawing (palm rest)
        if (!_activeStrokeNotifier.isActive) {
          _startLongPressTimer(event.position, event.localPosition, state, canvasSize);
        }
        return;
      }
    }

    // Pending symbol placement: tap to place symbol at this position
    if (state.pendingSymbol != null) {
      ref.read(canvasProvider.notifier).insertSymbol(state.pendingSymbol!, pagePos);
      return;
    }

    // Pending paste placement: tap to place duplicated/pasted content here
    if (state.pendingPaste && state.clipboard != null) {
      ref.read(canvasProvider.notifier).paste(at: pagePos);
      ref.read(canvasProvider.notifier).cancelPendingPaste();
      return;
    }

    // If we're in shape adjustment mode, user is adjusting the recognized shape
    if (state.isAdjustingRecognized && state.recognizedShape != null) {
      ref.read(canvasProvider.notifier).startAdjustRecognized(pagePos);
      return;
    }

    if (tool == CanvasTool.image) {
      _pickAndInsertImage(pagePos);
      return;
    }

    if (tool == CanvasTool.pan) {
      _lastFocalPoint = event.position;
      return;
    }

    if (tool == CanvasTool.text) {
      _handleTextTool(event.localPosition, state, canvasSize);
      return;
    }

    // If there's a selected element, handle tap interactions.
    // For draw tools: stylus/tablet pen deselects and draws through; plain mouse can interact.
    // For non-draw tools: all input devices can interact.
    if (state.selectedElementId != null) {
      final isPenLikeDevice = event.kind == PointerDeviceKind.stylus ||
          (event.kind == PointerDeviceKind.mouse && event.pressure > 0);
      if (_isDrawLikeTool(tool) && isPenLikeDevice) {
        // Stylus/tablet pen in draw mode: deselect image and proceed to draw
        ref.read(canvasProvider.notifier).deselectElement();
      } else {
        final isPlainMouseInDrawMode = _isDrawLikeTool(tool) && !isPenLikeDevice;
        if (!_isDrawLikeTool(tool) || isPlainMouseInDrawMode) {
          final selBounds = _getSelectedElementBounds(state);
          // Expand bounds to include action bar/handles above
          final scale = state.zoom * _getRenderScale(state, canvasSize);
          final topPad = 100.0 / scale;
          final sidePad = 20.0 / scale;
          final extended = selBounds == null ? null : Rect.fromLTRB(
            selBounds.left - sidePad,
            selBounds.top - topPad,
            selBounds.right + sidePad,
            selBounds.bottom + sidePad,
          );
          if (extended != null && extended.contains(pagePos)) {
            // Let ImageHandleOverlay or selection tool handle this interaction
            return;
          }
          // Tapped outside selection — deselect
          ref.read(canvasProvider.notifier).deselectElement();
        }
      }
    }

    // Check if tapping an image/shape to select it
    if (tool == CanvasTool.lasso) {
      // Check existing selection drag
      if (state.lassoSelection != null) {
        final sel = state.lassoSelection!;
        final bounds = sel.bounds.translate(sel.dragOffset.dx, sel.dragOffset.dy);
        if (bounds.inflate(10).contains(pagePos)) {
          _isDraggingSelection = true;
          _lastLassoDragPos = pagePos;
          return;
        }
      }
    }

    // Eraser: only erase, don't start a stroke visual
    if (tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke) {
      ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
      return;
    }

    // Shape tool: only set start pos, no visual stroke
    if (tool == CanvasTool.shape) {
      ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
      return;
    }

    // Lasso tool: only track via provider (no visual pen stroke)
    if (tool == CanvasTool.lasso) {
      _lassoPathNotifier.start(pagePos);
      ref.read(canvasProvider.notifier).clearLassoPath(); // reset provider path
      return;
    }

    // Check if double-tapping on an image/shape → select it.
    // For non-draw tools (lasso/pan/text): check images and shapes.
    // For draw tools: only select images (not shapes) if input is a plain mouse
    // (no pressure), so stylus and tablet pens always draw through images.
    {
      final bool shouldCheckImageTap;
      if (tool == CanvasTool.lasso || tool == CanvasTool.pan || tool == CanvasTool.text) {
        shouldCheckImageTap = true;
      } else if (_isDrawLikeTool(tool) &&
                 event.kind == PointerDeviceKind.mouse &&
                 event.pressure <= 0) {
        shouldCheckImageTap = true;
      } else {
        shouldCheckImageTap = false;
      }
      if (shouldCheckImageTap && _isDoubleTap(event.localPosition)) {
        final onlyImages = _isDrawLikeTool(tool);
        final tappedImageOrShape = _findImageOrShapeAt(state, pagePos, imagesOnly: onlyImages);
        if (tappedImageOrShape != null) {
          ref.read(canvasProvider.notifier).selectElement(tappedImageOrShape);
          return;
        }
      }
    }

    ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
    // Also push first point to fast notifier (only for pen/brush/highlighter)
    _activeStrokeNotifier.start(pagePos, pressure);
    _lastStrokeActivity = DateTime.now();
    _lastHoldCheckPos = pagePos;
  }

  void _onPointerMove(PointerMoveEvent event, CanvasState state, Size canvasSize) {
    if (_activePointers >= 2) return;

    if (_isTouchPanning) {
      // Cancel long-press if finger moved significantly
      if (_longPressTimer != null) {
        final moved = (event.position - _longPressGlobalPos).distance;
        if (moved > 10) _cancelLongPressTimer();
      }
      if (_longPressFired) return; // Don't pan after context menu shown
      final delta = event.position - _lastFocalPoint;
      _lastFocalPoint = event.position;
      final latest = ref.read(canvasProvider);
      if (latest != null) {
        ref.read(canvasProvider.notifier).setPanOffset(latest.panOffset + delta);
        _checkPageDrag(latest.copyWith(panOffset: latest.panOffset + delta), canvasSize);
      }
      return;
    }

    final tool = state.currentTool;

    // Shape adjustment mode: drag adjusts the recognized shape
    if (state.isAdjustingRecognized && state.recognizedShape != null) {
      final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
      ref.read(canvasProvider.notifier).adjustRecognizedShape(pagePos);
      return;
    }

    if (tool == CanvasTool.pan) {
      final delta = event.position - _lastFocalPoint;
      _lastFocalPoint = event.position;
      final latest = ref.read(canvasProvider);
      if (latest != null) {
        ref.read(canvasProvider.notifier).setPanOffset(latest.panOffset + delta);
        _checkPageDrag(latest.copyWith(panOffset: latest.panOffset + delta), canvasSize);
      }
      return;
    }

    if (_isDraggingSelection) {
      final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
      final delta = pagePos - _lastLassoDragPos;
      _lastLassoDragPos = pagePos;
      ref.read(canvasProvider.notifier).moveSelection(delta);
      return;
    }

    final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
    final pressure = event.pressure > 0 ? event.pressure : 0.5;

    if (tool == CanvasTool.lasso) {
      _onLassoPointerMove(pagePos);
      return;
    }

    // If a selected element exists and no active stroke, don't draw
    // (If a stroke is in progress, the element was deselected in pointerDown;
    //  allow moves through until the state rebuilds.)
    if (state.selectedElementId != null && !_activeStrokeNotifier.isActive) return;

    // Fast path: during pen/brush drawing, only update the notifier (no Riverpod rebuild).
    // Riverpod is only updated for eraser/lasso/shape tools that need state tracking.
    if (_activeStrokeNotifier.isActive) {
      // Shape recognized during hold:
      // - line: fix start point, drag moves endpoint
      // - circle/rectangle/triangle: fix top-left, drag resizes (bottom-right follows cursor)
      if (_shapeRecognizedDuringHold) {
        final recognizedShape = ref.read(canvasProvider)?.recognizedShape;
        if (recognizedShape != null && recognizedShape.shapeType == 'line') {
          ref.read(canvasProvider.notifier).setRecognizedLineEndpoint(pagePos);
        } else {
          ref.read(canvasProvider.notifier).resizeRecognizedShape(pagePos);
        }
        return;
      }

      _activeStrokeNotifier.addPoint(pagePos, pressure);
      _lastStrokeActivity = DateTime.now();

      // Reset hold-to-recognize timer (GoodNotes-style: recognize when user pauses)
      // Tolerate micro-jitter from stylus: only reset timer if movement > 3px
      final holdDx = pagePos.dx - _lastHoldCheckPos.dx;
      final holdDy = pagePos.dy - _lastHoldCheckPos.dy;
      final holdDistSq = holdDx * holdDx + holdDy * holdDy;
      const holdThresholdSq = 3.0 * 3.0; // 3px tolerance for stylus jitter

      if (holdDistSq > holdThresholdSq) {
        _lastHoldCheckPos = pagePos;
        _holdRecognizeTimer?.cancel();
        final currentState = ref.read(canvasProvider);
        if (currentState != null && currentState.toolSettings.shapeRecognition) {
          _holdRecognizeTimer = Timer(const Duration(milliseconds: 200), () {
            _tryRecognizeHeldStroke();
          });
        }
      }
      return;
    }
    ref.read(canvasProvider.notifier).continueStroke(pagePos, pressure);
  }

  void _onLassoPointerMove(Offset pagePos) {
    if (!_lassoPathNotifier.isActive) return;
    _lassoPathNotifier.addPoint(pagePos);
  }

  /// Try to recognize a shape when user holds still during drawing.
  void _tryRecognizeHeldStroke() {
    if (!_activeStrokeNotifier.isActive) return;
    final points = _activeStrokeNotifier.points;
    if (points.length < 5) return;

    final state = ref.read(canvasProvider);
    if (state == null || !state.toolSettings.shapeRecognition) return;

    // Ask provider to try recognition
    ref.read(canvasProvider.notifier).recognizeHeldStroke(List.of(points));

    // Check if it was recognized
    final newState = ref.read(canvasProvider);
    if (newState?.recognizedShape != null) {
      _shapeRecognizedDuringHold = true;
      _activeStrokeNotifier.clearPoints(); // Hide stroke, keep active flag
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final wasMultiTouch = _activePointers >= 2;
    _activePointers = max(0, _activePointers - 1);

    // Don't commit anything if this was a multi-touch gesture (pinch-to-zoom)
    if (wasMultiTouch || _activePointers >= 1) return;

    // Barrel button erase: restore previous tool on lift
    if (_barrelButtonErasing) {
      _barrelButtonErasing = false;
      ref.read(canvasProvider.notifier).endStroke();
      if (_barrelButtonPreviousTool != null) {
        ref.read(canvasProvider.notifier).setTool(_barrelButtonPreviousTool!);
        _barrelButtonPreviousTool = null;
      }
      return;
    }

    if (_isTouchPanning) {
      _isTouchPanning = false;
      _cancelLongPressTimer();
      _longPressFired = false;
      final latest = ref.read(canvasProvider);
      if (latest != null) {
        _commitOrCancelPageDrag(latest, _lastCanvasSize);
      } else {
        _clearPageHints();
      }
      return;
    }

    _holdRecognizeTimer?.cancel();

    if (_isDraggingSelection) {
      _isDraggingSelection = false;
      // Removed immediate applySelectionTransform to allow cumulative transforms
      // It will be baked into the canvas when the user clicks away or changes tools.
      return;
    }

    final state = ref.read(canvasProvider);
    if (state == null) return;

    // Shape recognized during hold → commit immediately
    if (_shapeRecognizedDuringHold && state.recognizedShape != null) {
      _shapeRecognizedDuringHold = false;
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).commitRecognizedShape();
      return;
    }
    _shapeRecognizedDuringHold = false;

    // Shape adjustment mode: commit the adjusted shape
    if (state.isAdjustingRecognized && state.recognizedShape != null) {
      ref.read(canvasProvider.notifier).commitRecognizedShape();
      return;
    }

    if (state.currentTool == CanvasTool.pan) {
      _commitOrCancelPageDrag(state, _lastCanvasSize);
      return;
    }
    if (state.currentTool == CanvasTool.image) return;

    // Lasso: commit the locally-tracked path to Riverpod and trigger selection
    if (state.currentTool == CanvasTool.lasso && _lassoPathNotifier.isActive) {
      final pts = List<Offset>.from(_lassoPathNotifier.points); // copy before clear
      _lassoPathNotifier.clear();
      ref.read(canvasProvider.notifier).commitLassoPath(pts);
      return;
    }

    // Commit fast notifier points and finalize in one go to avoid
    // an intermediate render frame showing the raw points (line stretching).
    if (_activeStrokeNotifier.isActive && _activeStrokeNotifier.points.isNotEmpty) {
      final points = List<StrokePoint>.from(_activeStrokeNotifier.points);
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).commitAndEndStroke(points);
    } else {
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).endStroke();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers = max(0, _activePointers - 1);
    _isTouchPanning = false;
    _isDraggingSelection = false;
    _holdRecognizeTimer?.cancel();
    _shapeRecognizedDuringHold = false;
    // Cancel any in-progress stroke or lasso
    if (_activeStrokeNotifier.isActive) {
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).cancelStroke();
    }
    if (_lassoPathNotifier.isActive) {
      _lassoPathNotifier.clear();
    }
    // Restore barrel button state
    if (_barrelButtonErasing) {
      _barrelButtonErasing = false;
      if (_barrelButtonPreviousTool != null) {
        ref.read(canvasProvider.notifier).setTool(_barrelButtonPreviousTool!);
        _barrelButtonPreviousTool = null;
      }
    }
  }

  String? _findElementAt(CanvasState state, Offset pagePos) {
    final page = state.currentPage;
    if (page == null) return null;

    // Search in reverse order (top elements first)
    for (int i = page.layers.content.length - 1; i >= 0; i--) {
      final element = page.layers.content[i];
      Rect? bounds;
      String? id;
      element.map(
        stroke: (s) {
          id = s.id;
          if (s.data.points.isNotEmpty) {
            final xs = s.data.points.map((p) => p.x);
            final ys = s.data.points.map((p) => p.y);
            bounds = Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
          }
        },
        text: (t) {
          id = t.id;
          bounds = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height);
        },
        image: (img) {
          id = img.id;
          bounds = Rect.fromLTWH(img.data.x, img.data.y, img.data.width, img.data.height);
        },
        shape: (s) {
          id = s.id;
          bounds = Rect.fromPoints(Offset(s.data.x1, s.data.y1), Offset(s.data.x2, s.data.y2));
        },
      );
      if (bounds != null && bounds!.inflate(5).contains(pagePos) && id != null) {
        return id;
      }
    }
    return null;
  }

  /// Find an image or shape element at the given page position (ignoring strokes/text).
  String? _findImageOrShapeAt(CanvasState state, Offset pagePos, {bool imagesOnly = false}) {
    final page = state.currentPage;
    if (page == null) return null;
    for (int i = page.layers.content.length - 1; i >= 0; i--) {
      final element = page.layers.content[i];
      Rect? bounds;
      String? id;
      element.map(
        stroke: (_) {},
        text: (_) {},
        image: (img) {
          id = img.id;
          bounds = Rect.fromLTWH(img.data.x, img.data.y, img.data.width, img.data.height);
        },
        shape: (s) {
          if (!imagesOnly) {
            id = s.id;
            bounds = Rect.fromPoints(Offset(s.data.x1, s.data.y1), Offset(s.data.x2, s.data.y2));
          }
        },
      );
      if (bounds != null && bounds!.inflate(5).contains(pagePos) && id != null) {
        return id;
      }
    }
    return null;
  }

  Rect? _getSelectedElementBounds(CanvasState state) {
    if (state.selectedElementId == null) return null;
    final page = state.currentPage;
    if (page == null) return null;
    for (final element in page.layers.content) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != state.selectedElementId) continue;
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
    return null;
  }

  // ── Pinch-to-zoom ──

  void _onScaleStart(ScaleStartDetails details) {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    _baseZoom = state.zoom;
    _lastFocalPoint = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Accept scale gesture if either: 2+ pointers (multi-touch), or scale != 1 (trackpad pinch)
    if (details.pointerCount < 2 && (details.scale - 1).abs() < 0.001) return;
    
    final notifier = ref.read(canvasProvider.notifier);
    final state = ref.read(canvasProvider);
    if (state == null) return;

    final newZoom = (_baseZoom * details.scale).clamp(0.3, 5.0);

    // Use the CURRENT zoom (not _baseZoom) for pan calculation so the
    // focal-point anchor stays stable across incremental updates.
    final oldZoom = state.zoom;
    final focalPoint = details.localFocalPoint;
    final newPan = state.panOffset + (focalPoint - state.panOffset) * (1 - (newZoom / oldZoom));

    notifier.setZoomAndPan(newZoom, newPan);
    _lastFocalPoint = details.focalPoint;
  }

  // ── Text insertion ──

  void _handleTextTool(Offset localPos, CanvasState state, Size canvasSize) async {
    final pagePos = _toPageCoords(localPos, state, canvasSize);
    final controller = TextEditingController();

    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inserisci testo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            hintText: 'Scrivi qui...',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Inserisci')),
        ],
      ),
    );

    controller.dispose();
    if (text != null && text.isNotEmpty) {
      ref.read(canvasProvider.notifier).addTextElement(pagePos, text);
    }
  }

  // ── Clipboard paste (system image or internal) ──

  Future<void> _pasteFromClipboard() async {
    // If the internal clipboard has content, prefer it
    final cs = ref.read(canvasProvider);
    if (cs != null && cs.clipboard != null) {
      ref.read(canvasProvider.notifier).paste();
      return;
    }

    // Try to read an image from the system clipboard (works on iOS, macOS, Windows, Linux, Android)
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        ref.read(canvasProvider.notifier).paste();
        return;
      }
      final reader = await clipboard.read();
      // Check for PNG first, then JPEG, then any image format
      Uint8List? imageBytes;
      String fileName = 'clipboard_image.png';

      if (reader.canProvide(Formats.png)) {
        final data = await reader.readValue(Formats.png);
        if (data != null) imageBytes = data;
      } else if (reader.canProvide(Formats.jpeg)) {
        final data = await reader.readValue(Formats.jpeg);
        if (data != null) {
          imageBytes = data;
          fileName = 'clipboard_image.jpg';
        }
      }

      if (imageBytes != null && imageBytes.isNotEmpty) {
        final s = ref.read(canvasProvider);
        if (s == null) return;
        final viewSize = (context.findRenderObject() as RenderBox?)?.size ?? const Size(400, 600);
        final center = Offset(
          (-s.panOffset.dx + viewSize.width / 2) / s.zoom,
          (-s.panOffset.dy + viewSize.height / 2) / s.zoom,
        );
        _insertImage(imageBytes, fileName, center);
        return;
      }
    } catch (_) {
      // Clipboard read failed — fall through
    }

    // Final fallback: try internal paste anyway (handles pendingPaste, etc.)
    ref.read(canvasProvider.notifier).paste();
  }

  // ── Image / PDF insertion ──

  Future<void> _pickAndInsertImage(Offset pagePos) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;

    final ext = file.name.split('.').last.toLowerCase();
    if (ext == 'pdf') {
      await _insertPdf(bytes, file.name, pagePos);
    } else {
      _insertImage(bytes, file.name, pagePos);
    }
  }

  void _insertImage(Uint8List bytes, String name, Offset pagePos) {
    final dims = _decodeImageDimensions(bytes);
    double w = dims?.width.toDouble() ?? 300;
    double h = dims?.height.toDouble() ?? 200;
    // Scale to max 300px wide on page
    if (w > 300) {
      final s = 300 / w;
      w *= s;
      h *= s;
    }
    ref.read(canvasProvider.notifier).addImageElement(pagePos, name, bytes, w, h);
  }

  /// Estimate the number of pages in a PDF from its raw bytes.
  /// Searches for /Type /Page (not /Pages) entries in the byte stream.
  int _countPdfPages(Uint8List bytes) {
    try {
      final str = latin1.decode(bytes, allowInvalid: true);
      return RegExp(r'/Type\s*/Page[^s]').allMatches(str).length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _insertPdf(Uint8List bytes, String name, Offset pagePos) async {
    if (!mounted) return;

    // Estimate page count for pre-confirmation
    final estimated = _countPdfPages(bytes);
    const kPageConfirmThreshold = 5;

    if (estimated > kPageConfirmThreshold) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('PDF con molte pagine'),
          content: Text(
            'Questo PDF ha circa $estimated pagine.\n'
            'Verranno create $estimated nuove pagine nel notebook.\n\n'
            'Continuare?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Importa $estimated pagine'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rasterizzazione PDF in corso…'), duration: Duration(seconds: 30)),
    );

    try {
      final rasters = <PdfRaster>[];
      await for (final r in Printing.raster(bytes, dpi: 150)) {
        rasters.add(r);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();

      if (rasters.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossibile leggere il PDF: nessuna pagina trovata')),
        );
        return;
      }

      final notifier = ref.read(canvasProvider.notifier);
      for (int i = 0; i < rasters.length; i++) {
        final png = await rasters[i].toPng();
        if (!mounted) return;

        if (i > 0) notifier.addPage();

        final st = ref.read(canvasProvider);
        final pageW = st?.currentPage?.width ?? 595.0;
        final pageH = st?.currentPage?.height ?? 842.0;
        // Fit the rasterized PDF page to the A4 page, preserving aspect ratio
        final raster = rasters[i];
        double imgW = raster.width.toDouble();
        double imgH = raster.height.toDouble();
        final scaleToFit = min(pageW / imgW, pageH / imgH);
        imgW *= scaleToFit;
        imgH *= scaleToFit;
        // Center on the page
        final insertPos = Offset((pageW - imgW) / 2, (pageH - imgH) / 2);
        notifier.addImageElement(insertPos, '${name}_p${i + 1}.png', png, imgW, imgH);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF importato: ${rasters.length} ${rasters.length == 1 ? 'pagina' : 'pagine'}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore importazione PDF: $e')),
        );
      }
    }
  }

  _Dims? _decodeImageDimensions(Uint8List b) {
    if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return _Dims(w, h);
    }
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      int off = 2;
      while (off < b.length - 9) {
        if (b[off] != 0xFF) break;
        final m = b[off + 1];
        if (m == 0xC0 || m == 0xC2) {
          return _Dims((b[off + 7] << 8) | b[off + 8], (b[off + 5] << 8) | b[off + 6]);
        }
        off += 2 + ((b[off + 2] << 8) | b[off + 3]);
      }
    }
    return null;
  }

  // ── BUILD ──

  @override
  Widget build(BuildContext context) {
    final canvasState = ref.watch(canvasProvider);
    if (canvasState == null) {
      return const Scaffold(body: Center(child: Text('Nessun notebook aperto')));
    }
    final currentPage = canvasState.currentPage;
    if (currentPage == null) {
      return const Scaffold(body: Center(child: Text('Nessuna pagina')));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) Navigator.of(context).pop();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: const Color(0xFFE8E8E8),
          body: Column(
            children: [
              _buildTopBar(canvasState),
              CanvasToolbar(
                currentTool: canvasState.currentTool,
                toolSettings: canvasState.toolSettings,
                canUndo: ref.read(canvasProvider.notifier).canUndo,
                canRedo: ref.read(canvasProvider.notifier).canRedo,
                showToolOptions: canvasState.showToolOptions,
                currentPaperType: canvasState.currentPaperType,
                lassoSelection: canvasState.lassoSelection,
                onToolChanged: (tool) => ref.read(canvasProvider.notifier).setTool(tool),
                onSettingsChanged: (s) => ref.read(canvasProvider.notifier).setToolSettings(s),
                onUndo: () => ref.read(canvasProvider.notifier).undo(),
                onRedo: () => ref.read(canvasProvider.notifier).redo(),
                onToggleOptions: () => ref.read(canvasProvider.notifier).toggleToolOptions(),
                onPaperTypeChanged: (t) => ref.read(canvasProvider.notifier).setPaperType(t),
                onDeleteSelection: () => ref.read(canvasProvider.notifier).deleteSelection(),
                onClearSelection: () => ref.read(canvasProvider.notifier).clearSelection(),
                onInsertImage: () => _pickAndInsertImage(const Offset(100, 100)),
                onCopySelection: () => ref.read(canvasProvider.notifier).copySelection(),
                onCutSelection: () => ref.read(canvasProvider.notifier).cutSelection(),
                onPasteSelection: canvasState.clipboard != null ? () => ref.read(canvasProvider.notifier).paste() : null,
                onDuplicateSelection: () => ref.read(canvasProvider.notifier).duplicateSelection(),
                onChangeSelectionColor: (color) => ref.read(canvasProvider.notifier).changeSelectionColor(color),
                onOpenSymbols: () {
                  // Insert at page center (visible area)
                  final pageW = canvasState.currentPage?.width ?? 595;
                  final pageH = canvasState.currentPage?.height ?? 842;
                  final visibleCenter = _toPageCoords(
                    Offset(MediaQuery.of(context).size.width / 2, MediaQuery.of(context).size.height / 2),
                    canvasState,
                    MediaQuery.of(context).size,
                  );
                  // Clamp to page bounds
                  final insertPos = Offset(
                    visibleCenter.dx.clamp(50, pageW - 50),
                    visibleCenter.dy.clamp(50, pageH - 50),
                  );
                  _showSymbolsDialog(insertPos);
                },
                onCreateSymbol: canvasState.lassoSelection != null ? () => _promptCreateSymbolFromSelection() : null,
                symbolCount: canvasState.symbolLibraries.fold(0, (sum, l) => sum + l.symbols.length),
              ),
              Expanded(child: _buildCanvas(canvasState, currentPage)),
              _buildPageNav(canvasState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(CanvasState canvasState) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: Colors.grey.shade800, size: 18),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && mounted) Navigator.of(context).pop();
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              canvasState.metadata.title,
              style: TextStyle(color: Colors.grey.shade900, fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canvasState.isDirty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Text('Non salvato', style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
            ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
            child: Text(
              '${(canvasState.zoom * 100).round()}%',
              style: TextStyle(color: Colors.grey.shade700, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            tooltip: 'Disegna solo con penna',
            icon: Icon(
              _stylusOnlyDrawing ? Icons.create_rounded : Icons.touch_app_rounded,
              color: _stylusOnlyDrawing ? Colors.blue : Colors.grey.shade600,
              size: 20,
            ),
            onPressed: () {
              setState(() => _stylusOnlyDrawing = !_stylusOnlyDrawing);
            },
          ),
          const SizedBox(width: 4),
          // Auto-save indicator
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            icon: Icon(Icons.save_rounded, color: canvasState.isDirty ? Colors.blue : Colors.grey.shade400, size: 20),
            onPressed: canvasState.isDirty && !_isSaving ? _save : null,
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas(CanvasState canvasState, PageData currentPage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);
        _lastCanvasSize = canvasSize;
        ref.read(canvasProvider.notifier).setViewportSize(canvasSize);

        MouseCursor cursor = SystemMouseCursors.precise;
        if (canvasState.currentTool == CanvasTool.pan) cursor = SystemMouseCursors.grab;
        if (canvasState.currentTool == CanvasTool.image) cursor = SystemMouseCursors.click;

        return MouseRegion(
          cursor: cursor,
          child: Stack(
            key: _canvasStackKey,
            children: [
              // Canvas painter
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    // Right-click → cancel pending symbol or show context menu
                    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
                      if (canvasState.pendingSymbol != null) {
                        ref.read(canvasProvider.notifier).clearPendingSymbol();
                        return;
                      }
                      _showContextMenu(e.position, e.localPosition, canvasState, canvasSize);
                      return;
                    }
                    _onPointerDown(e, canvasState, canvasSize);
                  },
                  onPointerMove: (e) => _onPointerMove(e, canvasState, canvasSize),
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final oldZoom = canvasState.zoom;
                      final zoomDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                      final newZoom = (oldZoom * zoomDelta).clamp(0.3, 5.0);
                      final cursorPos = event.localPosition;
                      final newPan = canvasState.panOffset + (cursorPos - canvasState.panOffset) * (1 - (newZoom / oldZoom));
                      ref.read(canvasProvider.notifier).setZoomAndPan(newZoom, newPan);
                    } else if (event is PointerScaleEvent) {
                      // Trackpad pinch-to-zoom (may not fire on all platforms)
                      final oldZoom = canvasState.zoom;
                      final newZoom = (oldZoom * event.scale).clamp(0.3, 5.0);
                      final cursorPos = event.localPosition;
                      final newPan = canvasState.panOffset + (cursorPos - canvasState.panOffset) * (1 - (newZoom / oldZoom));
                      ref.read(canvasProvider.notifier).setZoomAndPan(newZoom, newPan);
                    }
                  },
                  child: GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    child: ClipRect(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: CanvasRenderEngine(
                            pageData: currentPage,
                            activeStroke: _activeStrokeNotifier.points.isNotEmpty
                                ? _activeStrokeNotifier.points
                                : (canvasState.activeStroke.isNotEmpty ? canvasState.activeStroke : null),
                            activeToolType: _toolTypeString(canvasState.currentTool),
                            activeColor: canvasState.toolSettings.color,
                            activeWidth: canvasState.toolSettings.strokeWidth,
                            lassoSelection: canvasState.lassoSelection,
                            lassoPath: _lassoPathNotifier.isActive && _lassoPathNotifier.points.isNotEmpty
                                ? _lassoPathNotifier.points.toList()
                                : (canvasState.lassoPath.isNotEmpty ? canvasState.lassoPath : null),
                            lassoPathGetter: _lassoPathNotifier.isActive
                                ? () => List<Offset>.from(_lassoPathNotifier.points)
                                : null,
                            shapePreview: (canvasState.shapeStartPos != null && canvasState.shapeEndPos != null)
                                ? (canvasState.shapeStartPos!, canvasState.shapeEndPos!, canvasState.toolSettings.shapeType)
                                : null,
                            recognizedShapePreview: canvasState.recognizedShape,
                            zoom: canvasState.zoom,
                            panOffset: canvasState.panOffset,
                            imageCache: canvasState.imageCache,
                            repaintNotifier: Listenable.merge([_activeStrokeNotifier, _lassoPathNotifier]),
                          ),
                          isComplex: true,
                          willChange: true,
                          size: canvasSize,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Eraser cursor
              if (_isEraserTool(canvasState.currentTool) && canvasState.eraserCursorPos != null)
                _buildEraserCursor(canvasState, canvasSize),

              // Transform handles for selected elements
              ..._buildTransformHandles(canvasState, canvasSize),

              // Lasso selection handles (resize corners + rotation)
              ..._buildLassoHandles(canvasState, canvasSize),

              // Floating context actions near lasso selection
              if (canvasState.lassoSelection != null)
                _buildFloatingSelectionActions(canvasState, canvasSize),

              // Recognized shape adjustment indicator (only for shape tool adjustment mode)
              if (canvasState.isAdjustingRecognized && canvasState.recognizedShape != null)
                Positioned(
                  bottom: 16,
                  left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.shade700,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8)],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_fix_high, color: Colors.white, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            'Forma: ${_shapeTypeLabel(canvasState.recognizedShape!.shapeType)}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () => ref.read(canvasProvider.notifier).commitRecognizedShape(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text('Conferma', style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => ref.read(canvasProvider.notifier).dismissRecognizedShape(),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text('Annulla', style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Pending symbol placement hint
              if (canvasState.pendingSymbol != null)
                Positioned(
                  top: 16,
                  left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade700,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.place, color: Colors.white, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            'Tocca per posizionare: ${canvasState.pendingSymbol!.name}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => ref.read(canvasProvider.notifier).clearPendingSymbol(),
                            child: const Icon(Icons.close, color: Colors.white70, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Pending paste placement hint (duplicate / paste)
              if (canvasState.pendingPaste && canvasState.clipboard != null)
                Positioned(
                  top: 16,
                  left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade700,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.place, color: Colors.white, size: 16),
                          const SizedBox(width: 8),
                          const Text(
                            'Tocca per posizionare la copia',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () => ref.read(canvasProvider.notifier).cancelPendingPaste(),
                            child: const Icon(Icons.close, color: Colors.white70, size: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // New page drag-left hint
              if (_showNewPageHint)
                Positioned(
                  right: 0,
                  top: 0, bottom: 0,
                  width: 120,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerRight,
                        end: Alignment.centerLeft,
                        colors: [Colors.green.shade700.withValues(alpha: 0.85), Colors.green.shade700.withValues(alpha: 0.0)],
                      ),
                    ),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_circle_outline, color: Colors.white, size: 36),
                          SizedBox(height: 4),
                          Text('Nuova pagina', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                ),

              // Next page drag-left hint (when not last page)
              if (_showNextPageHint)
                Builder(builder: (ctx) {
                  final filtered = canvasState.filteredPageIndices;
                  final curIdx = filtered.indexOf(canvasState.currentPageIndex);
                  PageData? nextPage;
                  if (curIdx >= 0 && curIdx + 1 < filtered.length) {
                    final nextDocIdx = filtered[curIdx + 1];
                    final nextEntry = canvasState.document.pages[nextDocIdx];
                    nextPage = canvasState.pages[nextEntry.fileName];
                  }
                  return Positioned(
                    right: 0,
                    top: 0, bottom: 0,
                    width: MediaQuery.of(context).size.width * 0.35,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        border: Border(left: BorderSide(color: Colors.grey.shade400, width: 1)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(-4, 0))],
                      ),
                      child: nextPage != null
                          ? CustomPaint(
                              painter: CanvasRenderEngine(
                                pageData: nextPage,
                                zoom: 1.0,
                                panOffset: Offset.zero,
                                imageCache: canvasState.imageCache,
                              ),
                              size: Size.infinite,
                            )
                          : Center(child: Icon(Icons.arrow_forward_rounded, color: Colors.grey.shade400, size: 40)),
                    ),
                  );
                }),

              // Previous page drag-right hint
              if (_showPrevPageHint)
                Builder(builder: (ctx) {
                  final filtered = canvasState.filteredPageIndices;
                  final curIdx = filtered.indexOf(canvasState.currentPageIndex);
                  PageData? prevPage;
                  if (curIdx > 0) {
                    final prevDocIdx = filtered[curIdx - 1];
                    final prevEntry = canvasState.document.pages[prevDocIdx];
                    prevPage = canvasState.pages[prevEntry.fileName];
                  }
                  return Positioned(
                    left: 0,
                    top: 0, bottom: 0,
                    width: MediaQuery.of(context).size.width * 0.35,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        border: Border(right: BorderSide(color: Colors.grey.shade400, width: 1)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(4, 0))],
                      ),
                      child: prevPage != null
                          ? CustomPaint(
                              painter: CanvasRenderEngine(
                                pageData: prevPage,
                                zoom: 1.0,
                                panOffset: Offset.zero,
                                imageCache: canvasState.imageCache,
                              ),
                              size: Size.infinite,
                            )
                          : Center(child: Icon(Icons.arrow_back_rounded, color: Colors.grey.shade400, size: 40)),
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  bool _isEraserTool(CanvasTool tool) =>
      tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke;

  Widget _buildEraserCursor(CanvasState state, Size canvasSize) {
    final pos = _toScreenCoords(state.eraserCursorPos!, state, canvasSize);
    final r = eraserSizeToRadius(state.toolSettings.eraserSize) * state.zoom;
    return Positioned(
      left: pos.dx - r, top: pos.dy - r,
      child: IgnorePointer(
        child: Container(
          width: r * 2, height: r * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey.shade600, width: 1.5),
            color: Colors.white.withValues(alpha: 0.3),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTransformHandles(CanvasState state, Size canvasSize) {
    if (state.selectedElementId == null) return [];
    final page = state.currentPage;
    if (page == null) return [];

    final element = page.layers.content.where((e) {
      final id = e.map(stroke: (s) => s.id, text: (t) => t.id, image: (i) => i.id, shape: (s) => s.id);
      return id == state.selectedElementId;
    }).firstOrNull;
    if (element == null) return [];

    Rect? pageBounds;
    double rotation = 0;
    element.map(
      stroke: (_) {},
      text: (t) => pageBounds = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height),
      image: (i) {
        pageBounds = Rect.fromLTWH(i.data.x, i.data.y, i.data.width, i.data.height);
        rotation = i.data.rotation;
      },
      shape: (s) {
        pageBounds = Rect.fromPoints(Offset(s.data.x1, s.data.y1), Offset(s.data.x2, s.data.y2));
        rotation = s.data.rotation;
      },
    );
    if (pageBounds == null) return [];

    final screenTL = _toScreenCoords(pageBounds!.topLeft, state, canvasSize);
    final screenBR = _toScreenCoords(pageBounds!.bottomRight, state, canvasSize);
    final screenRect = Rect.fromPoints(screenTL, screenBR);

    // Determine if the selected element is an image (to show crop button)
    final isImage = element.map(
      stroke: (_) => false,
      text: (_) => false,
      image: (_) => true,
      shape: (_) => false,
    );

    final isLocked = element.map(
      stroke: (_) => false,
      text: (_) => false,
      image: (e) => e.data.locked,
      shape: (_) => false,
    );

    final hasComment = element.map(
      stroke: (_) => false,
      text: (_) => false,
      image: (e) => e.data.comment != null && e.data.comment!.isNotEmpty,
      shape: (_) => false,
    );

    final elementId = state.selectedElementId!;

    return [
      ImageHandleOverlay(
        bounds: screenRect,
        rotation: rotation,
        isLocked: isLocked,
        hasComment: hasComment,
        onDragStart: () {
          ref.read(canvasProvider.notifier).startDragElement(elementId);
        },
        onMove: (delta) {
          final pageDelta = delta / (state.zoom * _getRenderScale(state, canvasSize));
          ref.read(canvasProvider.notifier).moveElement(elementId, pageDelta);
        },
        onResize: (newBounds) {
          final pageTL = _toPageCoords(newBounds.topLeft, state, canvasSize);
          final pageBR = _toPageCoords(newBounds.bottomRight, state, canvasSize);
          ref.read(canvasProvider.notifier).resizeElement(elementId, Rect.fromPoints(pageTL, pageBR));
        },
        onRotate: (angle) {
          ref.read(canvasProvider.notifier).rotateElement(elementId, angle);
        },
        onDelete: () {
          ref.read(canvasProvider.notifier).deleteElement(elementId);
        },
        onDeselect: () {
          ref.read(canvasProvider.notifier).deselectElement();
        },
        onCrop: isImage ? () => _showCropDialog(elementId) : null,
        onBringToFront: () {
          ref.read(canvasProvider.notifier).bringToFront(elementId);
        },
        onSendToBack: () {
          ref.read(canvasProvider.notifier).sendToBack(elementId);
        },
        onToggleLock: isImage ? () {
          ref.read(canvasProvider.notifier).toggleImageLock(elementId);
        } : null,
        onEditComment: isImage ? () {
          _showCommentDialog(elementId);
        } : null,
      ),
    ];
  }

  Future<void> _showCommentDialog(String elementId) async {
    // Find current comment
    final st = ref.read(canvasProvider);
    if (st == null) return;
    String? currentComment;
    final pg = st.currentPage;
    if (pg != null) {
      for (final el in pg.layers.content) {
        final id = el.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
        if (id == elementId) {
          el.map(
            stroke: (_) {},
            text: (_) {},
            image: (e) => currentComment = e.data.comment,
            shape: (_) {},
          );
          break;
        }
      }
    }

    final controller = TextEditingController(text: currentComment ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Commento immagine'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Aggiungi un commento...'),
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Annulla'),
          ),
          if (currentComment != null && currentComment!.isNotEmpty)
            TextButton(
              onPressed: () {
                ref.read(canvasProvider.notifier).setImageComment(elementId, null);
                Navigator.of(ctx).pop(null);
              },
              child: const Text('Rimuovi', style: TextStyle(color: Colors.red)),
            ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) {
      ref.read(canvasProvider.notifier).setImageComment(elementId, result.isEmpty ? null : result);
    }
  }

  // ── Crop dialog ──

  void _showCropDialog(String elementId) {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final page = state.currentPage;
    if (page == null) return;

    final element = page.layers.content.where((e) {
      return e.map(stroke: (s) => s.id, text: (t) => t.id, image: (i) => i.id, shape: (s) => s.id) == elementId;
    }).firstOrNull;
    if (element == null) return;

    ImageData? imageData;
    element.map(stroke: (_) {}, text: (_) {}, image: (i) => imageData = i.data, shape: (_) {});
    if (imageData == null) return;
    final imgData = imageData!;

    final cachedImage = state.imageCache[imgData.assetPath];
    if (cachedImage == null) return;

    // Show a dialog with crop handles
    showDialog(
      context: context,
      builder: (ctx) => _CropDialog(
        image: cachedImage,
        imageData: imgData,
        onCrop: (cropRect) {
          // cropRect is in normalized 0..1 coordinates
          ref.read(canvasProvider.notifier).cropImageElement(elementId, cropRect);
        },
      ),
    );
  }

  // ── Lasso selection rotation handle ──

  Widget _buildFloatingSelectionActions(CanvasState state, Size canvasSize) {
    final sel = state.lassoSelection!;
    final center = sel.bounds.center;
    final scaledBounds = Rect.fromCenter(
      center: center,
      width: sel.bounds.width * sel.scale,
      height: sel.bounds.height * sel.scale,
    ).translate(sel.dragOffset.dx, sel.dragOffset.dy);

    // Position below the selection
    final screenBottom = _toScreenCoords(scaledBounds.bottomCenter, state, canvasSize);
    final screenCenter = _toScreenCoords(scaledBounds.center, state, canvasSize);

    // Clamp to stay within view
    final top = (screenBottom.dy + 12).clamp(0.0, canvasSize.height - 50);

    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FloatingActionBtn(Icons.copy_rounded, 'Copia', () {
                ref.read(canvasProvider.notifier).copySelection();
              }),
              _FloatingActionBtn(Icons.content_cut_rounded, 'Taglia', () {
                ref.read(canvasProvider.notifier).cutSelection();
              }),
              _FloatingActionBtn(Icons.copy_all_rounded, 'Duplica', () {
                ref.read(canvasProvider.notifier).duplicateSelection();
              }),
              if (state.clipboard != null)
                _FloatingActionBtn(Icons.paste_rounded, 'Incolla', () {
                  ref.read(canvasProvider.notifier).paste();
                }),
              _FloatingActionBtn(Icons.delete_outline, 'Elimina', () {
                ref.read(canvasProvider.notifier).deleteSelection();
              }, color: Colors.red),
              _FloatingActionBtn(Icons.close, null, () {
                ref.read(canvasProvider.notifier).clearSelection();
              }),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLassoHandles(CanvasState state, Size canvasSize) {
    final sel = state.lassoSelection;
    if (sel == null) return [];

    final center = sel.bounds.center;
    final scaledBounds = Rect.fromCenter(
      center: center,
      width: sel.bounds.width * sel.scale,
      height: sel.bounds.height * sel.scale,
    ).translate(sel.dragOffset.dx, sel.dragOffset.dy);

    final screenTL = _toScreenCoords(scaledBounds.topLeft, state, canvasSize);
    final screenBR = _toScreenCoords(scaledBounds.bottomRight, state, canvasSize);
    final screenRect = Rect.fromPoints(screenTL, screenBR);
    final selRotation = sel.rotation;

    Offset rotateScreenPoint(Offset point) {
      if (selRotation == 0.0) return point;
      final dx = point.dx - screenRect.center.dx;
      final dy = point.dy - screenRect.center.dy;
      final cosA = cos(selRotation);
      final sinA = sin(selRotation);
      return Offset(
        screenRect.center.dx + dx * cosA - dy * sinA,
        screenRect.center.dy + dx * sinA + dy * cosA,
      );
    }

    final unrotatedCenterTop = Offset(screenRect.center.dx, screenRect.top - 40);
    final centerTop = rotateScreenPoint(unrotatedCenterTop);

    Widget buildCornerHandle(Offset unrotatedPos, MouseCursor cursor) {
      final screenPos = rotateScreenPoint(unrotatedPos);
      return Positioned(
        left: screenPos.dx - 7,
        top: screenPos.dy - 7,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            onPanStart: (d) {
              _resizeDragStart = d.globalPosition;
              _resizeInitialScale = sel.scale;
            },
            onPanUpdate: (d) {
              // Convert screenRect.center to global coordinates via the canvas Stack
              final stackBox = _canvasStackKey.currentContext?.findRenderObject() as RenderBox?;
              final centerGlobal = stackBox != null
                  ? stackBox.localToGlobal(screenRect.center)
                  : screenRect.center;
              final startDist = (_resizeDragStart - centerGlobal).distance;
              final currentDist = (d.globalPosition - centerGlobal).distance;
              if (startDist > 5) {
                final newScale = _resizeInitialScale * (currentDist / startDist);
                ref.read(canvasProvider.notifier).scaleSelectionPreview(newScale.clamp(0.1, 10.0));
              }
            },
            child: Container(
              width: 14, height: 14,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.blue, width: 1.5),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2)],
              ),
            ),
          ),
        ),
      );
    }

    return [
      // Corner resize handles
      buildCornerHandle(screenRect.topLeft, SystemMouseCursors.resizeUpLeft),
      buildCornerHandle(screenRect.topRight, SystemMouseCursors.resizeUpRight),
      buildCornerHandle(screenRect.bottomLeft, SystemMouseCursors.resizeDownLeft),
      buildCornerHandle(screenRect.bottomRight, SystemMouseCursors.resizeDownRight),

      // Rotation handle
      Positioned(
        left: centerTop.dx - 14,
        top: centerTop.dy - 14,
        child: Transform.rotate(
          angle: selRotation,
          origin: const Offset(0, -13), // Shift origin from the center of the 54px col (y=27) pointing to circle (y=14)
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onPanUpdate: (d) {
                  // Use the canvas Stack's RenderBox for proper coordinate conversion
                  final stackBox = _canvasStackKey.currentContext?.findRenderObject() as RenderBox?;
                  final centerGlobal = stackBox != null
                      ? stackBox.localToGlobal(screenRect.center)
                      : screenRect.center;
                  final prev = d.globalPosition - d.delta;
                  final startAngle = atan2(prev.dy - centerGlobal.dy, prev.dx - centerGlobal.dx);
                  final currentAngle = atan2(d.globalPosition.dy - centerGlobal.dy, d.globalPosition.dx - centerGlobal.dx);
                  var deltaAngle = currentAngle - startAngle;
                  if (deltaAngle > pi) deltaAngle -= 2 * pi;
                  if (deltaAngle < -pi) deltaAngle += 2 * pi;
                  ref.read(canvasProvider.notifier).rotateSelection(deltaAngle);
                },
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle,
                    border: Border.all(color: Colors.blue, width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 3)],
                  ),
                  child: const Icon(Icons.rotate_right_rounded, size: 16, color: Colors.blue),
                ),
              ),
              IgnorePointer(
                child: Container(width: 1.5, height: 26, color: Colors.blue.withValues(alpha: 0.5)),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // Fields for resize drag tracking
  Offset _resizeDragStart = Offset.zero;
  double _resizeInitialScale = 1.0;

  // ── Context menu (right-click) ──

  void _showContextMenu(Offset globalPos, Offset localPos, CanvasState state, Size canvasSize) {
    final pagePos = _toPageCoords(localPos, state, canvasSize);
    final tappedElement = _findElementAt(state, pagePos);
    final hasLassoSelection = state.lassoSelection != null;
    final hasClipboard = state.clipboard != null;
    final hasSymbols = state.symbols.isNotEmpty;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        // Selection operations
        if (hasLassoSelection) ...[
          const PopupMenuItem(value: 'copy', child: _MenuRow(Icons.copy_rounded, 'Copia', 'Ctrl+C')),
          const PopupMenuItem(value: 'cut', child: _MenuRow(Icons.content_cut_rounded, 'Taglia', 'Ctrl+X')),
          const PopupMenuItem(value: 'duplicate_sel', child: _MenuRow(Icons.copy_all_rounded, 'Duplica', 'Ctrl+D')),
          const PopupMenuItem(value: 'delete_sel', child: _MenuRow(Icons.delete_outline_rounded, 'Elimina', 'Canc')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'create_symbol', child: _MenuRow(Icons.star_outline_rounded, 'Crea simbolo', null)),
          const PopupMenuDivider(),
        ],
        // Single element operations
        if (tappedElement != null && !hasLassoSelection) ...[
          const PopupMenuItem(value: 'select_element', child: _MenuRow(Icons.touch_app_outlined, 'Seleziona', null)),
          const PopupMenuItem(value: 'duplicate_element', child: _MenuRow(Icons.copy_all_rounded, 'Duplica', null)),
          const PopupMenuItem(value: 'delete_element', child: _MenuRow(Icons.delete_outline_rounded, 'Elimina', null)),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'create_symbol_element', child: _MenuRow(Icons.star_outline_rounded, 'Crea simbolo', null)),
          const PopupMenuDivider(),
        ],
        // Paste
        if (hasClipboard)
          const PopupMenuItem(value: 'paste', child: _MenuRow(Icons.paste_rounded, 'Incolla', 'Ctrl+V')),
        // Paste image from system clipboard
        const PopupMenuItem(value: 'paste_clipboard_image', child: _MenuRow(Icons.content_paste_rounded, 'Incolla immagine', null)),
        // Insert
        const PopupMenuItem(value: 'insert_image', child: _MenuRow(Icons.image_rounded, 'Inserisci immagine', null)),
        const PopupMenuItem(value: 'insert_text', child: _MenuRow(Icons.text_fields_rounded, 'Inserisci testo', null)),
        // Symbols
        if (hasSymbols)
          PopupMenuItem(
            value: 'symbols',
            child: _MenuRow(Icons.star_rounded, 'Inserisci simbolo (${state.symbols.length})', null),
          ),
        const PopupMenuDivider(),
        // Page operations
        const PopupMenuItem(value: 'select_all', child: _MenuRow(Icons.select_all_rounded, 'Seleziona tutto', 'Ctrl+A')),
        const PopupMenuItem(value: 'clear_page', child: _MenuRow(Icons.cleaning_services_rounded, 'Cancella pagina', null)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'export_png', child: _MenuRow(Icons.image_outlined, 'Esporta PNG', null)),
        const PopupMenuItem(value: 'export_pdf', child: _MenuRow(Icons.picture_as_pdf_rounded, 'Esporta PDF', null)),
      ],
    ).then((value) {
      if (value == null) return;
      final notifier = ref.read(canvasProvider.notifier);
      switch (value) {
        case 'copy': notifier.copySelection(); break;
        case 'cut': notifier.cutSelection(); break;
        case 'duplicate_sel': notifier.duplicateSelection(); break;
        case 'delete_sel': notifier.deleteSelection(); break;
        case 'paste': notifier.paste(at: pagePos); break;
        case 'paste_clipboard_image': _pasteFromClipboard(); break;
        case 'select_all': notifier.selectAll(); break;
        case 'clear_page': _confirmClearPage(); break;
        case 'insert_image': _pickAndInsertImage(pagePos); break;
        case 'insert_text': _handleTextTool(localPos, state, canvasSize); break;
        case 'select_element':
          if (tappedElement != null) notifier.selectElement(tappedElement);
          break;
        case 'duplicate_element':
          if (tappedElement != null) notifier.duplicateElement(tappedElement);
          break;
        case 'delete_element':
          if (tappedElement != null) notifier.deleteElement(tappedElement);
          break;
        case 'create_symbol': _promptCreateSymbolFromSelection(); break;
        case 'create_symbol_element':
          if (tappedElement != null) _promptCreateSymbolFromElement(tappedElement);
          break;
        case 'symbols': _showSymbolsDialog(pagePos); break;
        case 'export_png': _exportAsPng(); break;
        case 'export_pdf': _exportAsPdf(); break;
      }
    });
  }

  void _confirmClearPage() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancella pagina'),
        content: const Text('Tutti gli elementi di questa pagina saranno eliminati. Continuare?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancella'),
          ),
        ],
      ),
    );
    if (confirm == true) ref.read(canvasProvider.notifier).clearPage();
  }

  void _promptCreateSymbolFromSelection() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final libs = state.symbolLibraries;

    final controller = TextEditingController();
    String? selectedLibId = libs.isNotEmpty ? libs.first.id : null;

    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Crea simbolo riutilizzabile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nome simbolo', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              if (libs.isNotEmpty) ...[
                const Text('Libreria:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: selectedLibId,
                  isExpanded: true,
                  items: libs.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                  onChanged: (v) => setS(() => selectedLibId = v),
                ),
              ] else
                Text('Nessuna libreria esistente. Verrà creata una libreria "Simboli".',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (controller.text, selectedLibId)),
              child: const Text('Crea'),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.$1.isNotEmpty) {
      ref.read(canvasProvider.notifier).createSymbolFromSelection(result.$1, targetLibId: result.$2);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Simbolo "${result.$1}" creato!'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _promptCreateSymbolFromElement(String elementId) async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final libs = state.symbolLibraries;
    final controller = TextEditingController();
    String? selectedLibId = libs.isNotEmpty ? libs.first.id : null;

    final result = await showDialog<(String, String?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Crea simbolo riutilizzabile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nome simbolo', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              if (libs.isNotEmpty) ...[
                const Text('Libreria:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: selectedLibId,
                  isExpanded: true,
                  items: libs.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(),
                  onChanged: (v) => setS(() => selectedLibId = v),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (controller.text, selectedLibId)),
              child: const Text('Crea'),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.$1.isNotEmpty) {
      ref.read(canvasProvider.notifier).createSymbolFromElement(elementId, result.$1);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Simbolo "${result.$1}" creato!'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _showSymbolsDialog(Offset insertPos) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: SymbolLibraryPanel(
          insertPos: insertPos,
          onClose: () => Navigator.pop(ctx),
        ),
      ),
    );
  }

  // ── Export ──

  Future<void> _exportAsPng() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final page = state.currentPage;
    if (page == null) return;

    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, page.width, page.height));

      // Draw white background
      canvas.drawRect(
        Rect.fromLTWH(0, 0, page.width, page.height),
        Paint()..color = Colors.white,
      );

      // Use the render engine to paint the page content
      final engine = CanvasRenderEngine(
        pageData: page,
        zoom: 1.0,
        panOffset: Offset.zero,
        imageCache: state.imageCache,
      );
      engine.paintPage(canvas, Size(page.width, page.height), 1.0, Offset.zero);

      final picture = recorder.endRecording();
      final img = await picture.toImage(page.width.toInt(), page.height.toInt());
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Salva come PNG',
        fileName: '${state.metadata.title}_p${state.currentPageIndex + 1}.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );

      if (savePath != null) {
        final file = await _writeFile(savePath, byteData.buffer.asUint8List());
        if (mounted && file) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PNG esportato!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore export: $e')));
      }
    }
  }

  Future<void> _exportAsPdf() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;

    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Salva come PDF',
        fileName: '${state.metadata.title}.pdf',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (savePath == null) return;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Generazione PDF in corso...')),
        );
      }

      // Render each page at 2x resolution for sharpness
      const scale = 2.0;
      final doc = pw.Document();

      for (final entry in state.document.pages) {
        final page = state.pages[entry.fileName];
        if (page == null) continue;

        final width = page.width;
        final height = page.height;
        final renderW = (width * scale).toInt();
        final renderH = (height * scale).toInt();

        // Render the page to a bitmap at 2x scale
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width * scale, height * scale));
        canvas.scale(scale);
        canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = Colors.white);

        final engine = CanvasRenderEngine(
          pageData: page,
          zoom: 1.0,
          panOffset: Offset.zero,
          imageCache: state.imageCache,
        );
        engine.paintPage(canvas, Size(width, height), 1.0, Offset.zero);

        final picture = recorder.endRecording();
        final img = await picture.toImage(renderW, renderH);
        final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        if (byteData == null) continue;

        final pngBytes = byteData.buffer.asUint8List();
        final pdfImage = pw.MemoryImage(pngBytes);

        doc.addPage(
          pw.Page(
            pageFormat: pw_pdf.PdfPageFormat(width * pw_pdf.PdfPageFormat.point, height * pw_pdf.PdfPageFormat.point),
            margin: pw.EdgeInsets.zero,
            build: (ctx) => pw.Image(pdfImage, fit: pw.BoxFit.fill),
          ),
        );
      }

      final pdfBytes = await doc.save();
      await _writeFile(savePath, Uint8List.fromList(pdfBytes));

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF esportato: ${state.document.pages.length} ${state.document.pages.length == 1 ? 'pagina' : 'pagine'}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore export PDF: $e')));
      }
    }
  }

  Future<bool> _writeFile(String path, Uint8List data) async {
    try {
      await io.File(path).writeAsBytes(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  Widget _buildPageNav(CanvasState canvasState) {
    final filteredPos = canvasState.currentFilteredIndex;
    final filteredCount = canvasState.filteredPageCount;
    final hasChapters = canvasState.metadata.chapters.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Chapter tabs (only if chapters exist) ──
        if (hasChapters)
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(top: BorderSide(color: Colors.grey.shade300, width: 0.5)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                ...canvasState.metadata.chapters.asMap().entries.map((entry) {
                  final chapIdx = entry.key;
                  final chapter = entry.value;
                  final isActive = canvasState.activeChapterId == chapter.id;
                  final chip = ChoiceChip(
                    label: Text(chapter.title, style: const TextStyle(fontSize: 12)),
                    selected: isActive,
                    onSelected: (_) => ref.read(canvasProvider.notifier).setActiveChapter(
                      isActive ? null : chapter.id,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                  return DragTarget<int>(
                    onWillAcceptWithDetails: (d) => d.data != chapIdx,
                    onAcceptWithDetails: (d) => ref.read(canvasProvider.notifier).reorderChapters(d.data, chapIdx),
                    builder: (ctx, accepted, _) => LongPressDraggable<int>(
                      data: chapIdx,
                      axis: Axis.horizontal,
                      delay: const Duration(milliseconds: 200),
                      feedback: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          child: Text(chapter.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, decoration: TextDecoration.none, color: Colors.blue)),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.3,
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4), child: chip),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                        child: accepted.isNotEmpty
                            ? Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.blue, width: 2),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: chip,
                              )
                            : chip,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        // ── Page navigation bar ──
        Container(
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Colors.grey.shade300, width: 0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.view_carousel_outlined, color: Colors.grey.shade700, size: 20),
                onPressed: () => _showPageManager(canvasState),
                tooltip: 'Gestione pagine',
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.chevron_left_rounded, color: Colors.grey.shade800, size: 22),
                onPressed: filteredPos > 0
                    ? () => ref.read(canvasProvider.notifier).prevPage()
                    : null,
                splashRadius: 18,
              ),
              GestureDetector(
                onTap: () => _showPageManager(canvasState),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    filteredCount > 0 && filteredPos >= 0
                        ? '${filteredPos + 1} / $filteredCount'
                        : '— / $filteredCount',
                    style: TextStyle(color: Colors.grey.shade800, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right_rounded, color: Colors.grey.shade800, size: 22),
                onPressed: filteredPos >= 0 && filteredPos < filteredCount - 1
                    ? () => ref.read(canvasProvider.notifier).nextPage()
                    : null,
                splashRadius: 18,
              ),
              const Spacer(),
              // Zoom indicator — tap to reset to 200%
              GestureDetector(
                onTap: () {
                  ref.read(canvasProvider.notifier).resetZoom();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: canvasState.zoom != 2.0 ? Colors.blue.shade50 : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${(canvasState.zoom * 100).round()}%',
                    style: TextStyle(
                      color: canvasState.zoom != 2.0 ? Colors.blue.shade700 : Colors.grey.shade600,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'v${AppConfig.appVersion}',
                style: TextStyle(
                  color: Colors.grey.shade400,
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.add_rounded, color: Colors.blue.shade600, size: 20),
                onPressed: () => ref.read(canvasProvider.notifier).addPage(),
                splashRadius: 18,
                tooltip: 'Aggiungi pagina',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<String?> _promptForText(BuildContext context, String title, String hintText, {String? initial}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hintText),
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Annulla')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text), child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _showChapterPicker(BuildContext context, CanvasState canvasState, int pageIndex) async {
    if (canvasState.metadata.chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crea prima almeno un capitolo.')),
      );
      return;
    }

    // Use a sentinel value to distinguish "remove chapter" from "dismissed"
    const removeChapter = '__remove__';

    final selectedId = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('Assegna capitolo')),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Nessuno'),
              onTap: () => Navigator.of(ctx).pop(removeChapter),
            ),
            ...canvasState.metadata.chapters.map((chapter) {
              return ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(chapter.title),
                selected: canvasState.document.pages[pageIndex].chapterId == chapter.id,
                onTap: () => Navigator.of(ctx).pop(chapter.id),
              );
            }).toList(),
          ],
        );
      },
    );

    if (selectedId == removeChapter) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, null);
    } else if (selectedId != null) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, selectedId);
    }
  }

  void _showPageManager(CanvasState canvasState) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final liveState = ref.watch(canvasProvider) ?? canvasState;
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              maxChildSize: 0.9,
              minChildSize: 0.3,
              expand: false,
              builder: (ctx, scrollController) {
                final visibleIndices = liveState.filteredPageIndices;
                return Column(
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        margin: const EdgeInsets.only(top: 8, bottom: 4),
                        decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('Pagine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.add_rounded, color: Colors.blue),
                                onPressed: () {
                                  ref.read(canvasProvider.notifier).addPage();
                                },
                                tooltip: 'Aggiungi pagina',
                              ),
                              IconButton(
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () => Navigator.pop(ctx),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // Chapter filter chips — drag to reorder
                          if (liveState.metadata.chapters.isNotEmpty)
                            SizedBox(
                              height: 38,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  ...liveState.metadata.chapters.asMap().entries.map((entry) {
                                    final chapIdx = entry.key;
                                    final chapter = entry.value;
                                    final isActive = liveState.activeChapterId == chapter.id;
                                    final chip = ChoiceChip(
                                      label: Text(chapter.title),
                                      selected: isActive,
                                      onSelected: (_) => ref.read(canvasProvider.notifier).setActiveChapter(
                                        isActive ? null : chapter.id,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                    );
                                    return DragTarget<int>(
                                      onWillAcceptWithDetails: (details) => details.data != chapIdx,
                                      onAcceptWithDetails: (details) {
                                        ref.read(canvasProvider.notifier).reorderChapters(details.data, chapIdx);
                                      },
                                      builder: (ctx, accepted, rejected) {
                                        return LongPressDraggable<int>(
                                          data: chapIdx,
                                          axis: Axis.horizontal,
                                          delay: const Duration(milliseconds: 200),
                                          feedback: Material(
                                            elevation: 4,
                                            borderRadius: BorderRadius.circular(20),
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                              child: Text(chapter.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, decoration: TextDecoration.none, color: Colors.blue)),
                                            ),
                                          ),
                                          childWhenDragging: Opacity(
                                            opacity: 0.3,
                                            child: Padding(padding: const EdgeInsets.only(right: 6), child: chip),
                                          ),
                                          onDragCompleted: () {},
                                          child: Padding(
                                            padding: const EdgeInsets.only(right: 6),
                                            child: GestureDetector(
                                              onSecondaryTap: () => _showChapterEditMenu(ctx, ref, chapter),
                                              child: accepted.isNotEmpty
                                                  ? Container(
                                                      decoration: BoxDecoration(
                                                        border: Border.all(color: Colors.blue, width: 2),
                                                        borderRadius: BorderRadius.circular(20),
                                                      ),
                                                      child: chip,
                                                    )
                                                  : chip,
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  }),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ActionChip(
                                      label: const Icon(Icons.add, size: 16),
                                      onPressed: () async {
                                        final title = await _promptForText(ctx, 'Nuovo capitolo', 'Nome capitolo');
                                        if (title != null && title.trim().isNotEmpty) {
                                          ref.read(canvasProvider.notifier).addChapter(title.trim());
                                        }
                                      },
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // Page grid with thumbnails — drag to reorder
                    Expanded(
                      child: _PageGridReorderable(
                        scrollController: scrollController,
                        liveState: liveState,
                        visibleIndices: visibleIndices,
                        onReorder: (oldVisIdx, newVisIdx) {
                          if (oldVisIdx == newVisIdx) return;
                          final oldDocIdx = visibleIndices[oldVisIdx];
                          // Compute new doc index: where it should be inserted after removal
                          final newDocIdx = newVisIdx < visibleIndices.length
                              ? visibleIndices[newVisIdx]
                              : visibleIndices.last + 1;
                          final adjustedNew = newDocIdx > oldDocIdx ? newDocIdx - 1 : newDocIdx;
                          ref.read(canvasProvider.notifier).reorderPage(oldDocIdx, adjustedNew);
                        },
                        onTapPage: (index) {
                          ref.read(canvasProvider.notifier).goToPage(index);
                          Navigator.pop(ctx);
                        },
                        onPageAction: (docIndex, visIdx, action) {
                          switch (action) {
                            case 'goto':
                              ref.read(canvasProvider.notifier).goToPage(docIndex);
                              Navigator.pop(ctx);
                              break;
                            case 'insert_before':
                              ref.read(canvasProvider.notifier).insertPageAt(docIndex);
                              break;
                            case 'insert_after':
                              ref.read(canvasProvider.notifier).insertPageAt(docIndex + 1);
                              break;
                            case 'duplicate':
                              ref.read(canvasProvider.notifier).duplicatePage(docIndex);
                              break;
                            case 'chapter':
                              _showChapterPicker(ctx, liveState, docIndex);
                              break;
                            case 'delete':
                              ref.read(canvasProvider.notifier).deletePage(docIndex);
                              break;
                          }
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _showChapterEditMenu(BuildContext ctx, WidgetRef ref, Chapter chapter) async {
    final action = await showModalBottomSheet<String>(
      context: ctx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rinomina'),
              onTap: () => Navigator.pop(sheetCtx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title: const Text('Elimina', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(sheetCtx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') {
      final newTitle = await _promptForText(ctx, 'Rinomina capitolo', 'Nome', initial: chapter.title);
      if (newTitle != null && newTitle.trim().isNotEmpty) {
        ref.read(canvasProvider.notifier).renameChapter(chapter.id, newTitle.trim());
      }
    } else if (action == 'delete') {
      ref.read(canvasProvider.notifier).deleteChapter(chapter.id);
    }
  }

  void _showPageContextMenu(BuildContext ctx, WidgetRef ref, CanvasState state, int pageIndex, int visIdx, String? chapterName) {
    showModalBottomSheet(
      context: ctx,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: Text('Vai a pagina ${visIdx + 1}'),
              onTap: () {
                Navigator.pop(sheetCtx);
                ref.read(canvasProvider.notifier).goToPage(pageIndex);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_rounded),
              title: const Text('Duplica'),
              onTap: () {
                Navigator.pop(sheetCtx);
                ref.read(canvasProvider.notifier).duplicatePage(pageIndex);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_rounded),
              title: const Text('Sposta in capitolo'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showChapterPicker(ctx, state, pageIndex);
              },
            ),
            if (chapterName != null)
              ListTile(
                leading: const Icon(Icons.folder_off_rounded),
                title: const Text('Rimuovi da capitolo'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, null);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Inserisci pagina dopo'),
              onTap: () {
                Navigator.pop(sheetCtx);
                ref.read(canvasProvider.notifier).insertPageAt(pageIndex + 1);
              },
            ),
            if (state.pageCount > 1)
              ListTile(
                leading: const Icon(Icons.delete_rounded, color: Colors.red),
                title: const Text('Elimina', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ref.read(canvasProvider.notifier).deletePage(pageIndex);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _toolTypeString(CanvasTool tool) {
    switch (tool) {
      case CanvasTool.pen: return 'pen';
      case CanvasTool.ballpoint: return 'ballpoint';
      case CanvasTool.brush: return 'brush';
      case CanvasTool.highlighter: return 'highlighter';
      default: return 'pen';
    }
  }

  String _shapeTypeLabel(String shapeType) {
    switch (shapeType) {
      case 'line': return 'Linea';
      case 'circle': return 'Cerchio';
      case 'rectangle': return 'Rettangolo';
      case 'triangle': return 'Triangolo';
      case 'arrow': return 'Freccia';
      default: return shapeType;
    }
  }
}

class _Dims {
  final int width, height;
  _Dims(this.width, this.height);
}

/// Context menu row with icon, label, and optional shortcut
class _FloatingActionBtn extends StatelessWidget {
  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  final Color? color;

  const _FloatingActionBtn(this.icon, this.label, this.onTap, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.grey.shade800;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: c),
              if (label != null)
                Text(label!, style: TextStyle(fontSize: 9, color: c)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? shortcut;

  const _MenuRow(this.icon, this.label, this.shortcut);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        if (shortcut != null)
          Text(shortcut!, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }
}

/// Lightweight ChangeNotifier for active stroke – triggers repaint
/// without going through Riverpod state management.
class _ActiveStrokeNotifier extends ChangeNotifier {
  final List<StrokePoint> _points = [];
  bool _active = false;

  List<StrokePoint> get points => _points;
  bool get isActive => _active;

  void start(Offset pos, double pressure) {
    _points.clear();
    _active = true;
    _points.add(StrokePoint(x: pos.dx, y: pos.dy, pressure: pressure,
        timestamp: DateTime.now().millisecondsSinceEpoch));
    notifyListeners();
  }

  void addPoint(Offset pos, double pressure) {
    // Real-time smoothing: weighted moving average with last 3 points for smoother curves
    double sx = pos.dx, sy = pos.dy, sp = pressure;
    if (_points.length >= 3) {
      final p2 = _points[_points.length - 1];
      final p1 = _points[_points.length - 2];
      final p0 = _points[_points.length - 3];
      sx = (p0.x + p1.x * 2 + p2.x * 4 + pos.dx * 8) / 15;
      sy = (p0.y + p1.y * 2 + p2.y * 4 + pos.dy * 8) / 15;
      sp = (p0.pressure + p1.pressure * 2 + p2.pressure * 4 + pressure * 8) / 15;
    } else if (_points.length >= 2) {
      final p1 = _points[_points.length - 1];
      final p0 = _points[_points.length - 2];
      sx = (p0.x + p1.x * 2 + pos.dx * 4) / 7;
      sy = (p0.y + p1.y * 2 + pos.dy * 4) / 7;
      sp = (p0.pressure + p1.pressure * 2 + pressure * 4) / 7;
    } else if (_points.length == 1) {
      final p1 = _points.last;
      sx = (p1.x + pos.dx * 2) / 3;
      sy = (p1.y + pos.dy * 2) / 3;
      sp = (p1.pressure + pressure * 2) / 3;
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
class _LassoPathNotifier extends ChangeNotifier {
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

/// Image crop dialog with draggable crop rectangle.
class _CropDialog extends StatefulWidget {
  final ui.Image image;
  final ImageData imageData;
  final ValueChanged<Rect> onCrop;

  const _CropDialog({required this.image, required this.imageData, required this.onCrop});

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  // Crop rect in normalized 0..1 coords
  double _left = 0, _top = 0, _right = 1, _bottom = 1;
  static const _minCrop = 0.05;

  @override
  Widget build(BuildContext context) {
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();
    // Fit image in dialog (max 500x500)
    const maxSize = 500.0;
    final scale = min(maxSize / imgW, maxSize / imgH);
    final displayW = imgW * scale;
    final displayH = imgH * scale;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: displayW + 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Ritaglia immagine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            SizedBox(
              width: displayW,
              height: displayH,
              child: GestureDetector(
                onPanUpdate: (d) {
                  setState(() {
                    final dx = d.delta.dx / displayW;
                    final dy = d.delta.dy / displayH;
                    _left = (_left + dx).clamp(0.0, _right - _minCrop);
                    _top = (_top + dy).clamp(0.0, _bottom - _minCrop);
                    _right = (_right + dx).clamp(_left + _minCrop, 1.0);
                    _bottom = (_bottom + dy).clamp(_top + _minCrop, 1.0);
                  });
                },
                child: CustomPaint(
                  painter: _CropPainter(
                    image: widget.image,
                    cropLeft: _left,
                    cropTop: _top,
                    cropRight: _right,
                    cropBottom: _bottom,
                  ),
                  size: Size(displayW, displayH),
                  child: Stack(
                    children: [
                      _cropHandle(displayW, displayH, 'tl'),
                      _cropHandle(displayW, displayH, 'tr'),
                      _cropHandle(displayW, displayH, 'bl'),
                      _cropHandle(displayW, displayH, 'br'),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annulla'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    widget.onCrop(Rect.fromLTRB(_left, _top, _right, _bottom));
                    Navigator.pop(context);
                  },
                  child: const Text('Ritaglia'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cropHandle(double displayW, double displayH, String corner) {
    double left, top;
    switch (corner) {
      case 'tl': left = _left * displayW - 8; top = _top * displayH - 8;
      case 'tr': left = _right * displayW - 8; top = _top * displayH - 8;
      case 'bl': left = _left * displayW - 8; top = _bottom * displayH - 8;
      case 'br': left = _right * displayW - 8; top = _bottom * displayH - 8;
      default: return const SizedBox.shrink();
    }

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: (d) {
          setState(() {
            final dx = d.delta.dx / displayW;
            final dy = d.delta.dy / displayH;
            switch (corner) {
              case 'tl':
                _left = (_left + dx).clamp(0.0, _right - _minCrop);
                _top = (_top + dy).clamp(0.0, _bottom - _minCrop);
              case 'tr':
                _right = (_right + dx).clamp(_left + _minCrop, 1.0);
                _top = (_top + dy).clamp(0.0, _bottom - _minCrop);
              case 'bl':
                _left = (_left + dx).clamp(0.0, _right - _minCrop);
                _bottom = (_bottom + dy).clamp(_top + _minCrop, 1.0);
              case 'br':
                _right = (_right + dx).clamp(_left + _minCrop, 1.0);
                _bottom = (_bottom + dy).clamp(_top + _minCrop, 1.0);
            }
          });
        },
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.blue, width: 2),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final double cropLeft, cropTop, cropRight, cropBottom;

  _CropPainter({
    required this.image,
    required this.cropLeft,
    required this.cropTop,
    required this.cropRight,
    required this.cropBottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final srcRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dstRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, srcRect, dstRect, Paint()..filterQuality = FilterQuality.low);

    // Dim outside crop area
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: 0.5);
    final cropRect = Rect.fromLTRB(
      cropLeft * size.width,
      cropTop * size.height,
      cropRight * size.width,
      cropBottom * size.height,
    );
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, cropRect.top), dimPaint);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.bottom, size.width, size.height), dimPaint);
    canvas.drawRect(Rect.fromLTRB(0, cropRect.top, cropRect.left, cropRect.bottom), dimPaint);
    canvas.drawRect(Rect.fromLTRB(cropRect.right, cropRect.top, size.width, cropRect.bottom), dimPaint);

    final borderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(cropRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      cropLeft != old.cropLeft || cropTop != old.cropTop ||
      cropRight != old.cropRight || cropBottom != old.cropBottom;
}

/// Reorderable grid of page thumbnails with drag-and-drop support.
class _PageGridReorderable extends StatefulWidget {
  final ScrollController scrollController;
  final CanvasState liveState;
  final List<int> visibleIndices;
  final void Function(int oldVisIdx, int newVisIdx) onReorder;
  final void Function(int docIndex) onTapPage;
  final void Function(int docIndex, int visIdx, String action) onPageAction;

  const _PageGridReorderable({
    required this.scrollController,
    required this.liveState,
    required this.visibleIndices,
    required this.onReorder,
    required this.onTapPage,
    required this.onPageAction,
  });

  @override
  State<_PageGridReorderable> createState() => _PageGridReorderableState();
}

class _PageGridReorderableState extends State<_PageGridReorderable> {
  int? _dragFromVisIdx;
  int? _dragOverVisIdx;

  String? _chapterNameForPage(int docIdx) {
    final entry = widget.liveState.document.pages[docIdx];
    for (final c in widget.liveState.metadata.chapters) {
      if (c.id == entry.chapterId) return c.title;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.60,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: widget.visibleIndices.length,
      itemBuilder: (ctx, visIdx) {
        final index = widget.visibleIndices[visIdx];
        final isCurrentPage = index == widget.liveState.currentPageIndex;
        final entry = widget.liveState.document.pages[index];
        final page = widget.liveState.pages[entry.fileName];
        final chapterName = _chapterNameForPage(index);
        final isDragOver = _dragOverVisIdx == visIdx && _dragFromVisIdx != visIdx;

        return DragTarget<int>(
          onWillAcceptWithDetails: (details) {
            if (details.data != visIdx) {
              setState(() => _dragOverVisIdx = visIdx);
            }
            return true;
          },
          onLeave: (_) {
            if (_dragOverVisIdx == visIdx) setState(() => _dragOverVisIdx = null);
          },
          onAcceptWithDetails: (details) {
            setState(() => _dragOverVisIdx = null);
            widget.onReorder(details.data, visIdx);
          },
          builder: (ctx, accepted, rejected) {
            final tile = _buildTile(
              ctx, visIdx, index, isCurrentPage, entry, page, chapterName, isDragOver,
            );
            return LongPressDraggable<int>(
              data: visIdx,
              delay: const Duration(milliseconds: 150),
              hapticFeedbackOnStart: true,
              onDragStarted: () => setState(() => _dragFromVisIdx = visIdx),
              onDragEnd: (_) => setState(() { _dragFromVisIdx = null; _dragOverVisIdx = null; }),
              feedback: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: Opacity(
                  opacity: 0.85,
                  child: SizedBox(
                    width: 110, height: 150,
                    child: _buildThumbnail(index, isCurrentPage, page, widget.liveState),
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.2, child: tile),
              child: tile,
            );
          },
        );
      },
    );
  }

  Widget _buildTile(
    BuildContext ctx, int visIdx, int index, bool isCurrentPage,
    PageEntry entry, PageData? page, String? chapterName, bool isDragOver,
  ) {
    return GestureDetector(
      onTap: () => widget.onTapPage(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: isDragOver
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue, width: 2),
              )
            : null,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _buildThumbnail(index, isCurrentPage, page, widget.liveState),
                  ),
                  // 3-dot menu button
                  Positioned(
                    top: 2, right: 2,
                    child: PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, size: 18, color: Colors.grey.shade600),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'goto', child: ListTile(dense: true, leading: Icon(Icons.open_in_new_rounded, size: 18), title: Text('Vai a pagina', style: TextStyle(fontSize: 13)))),
                        const PopupMenuItem(value: 'insert_before', child: ListTile(dense: true, leading: Icon(Icons.add_rounded, size: 18), title: Text('Inserisci prima', style: TextStyle(fontSize: 13)))),
                        const PopupMenuItem(value: 'insert_after', child: ListTile(dense: true, leading: Icon(Icons.add_rounded, size: 18), title: Text('Inserisci dopo', style: TextStyle(fontSize: 13)))),
                        const PopupMenuItem(value: 'duplicate', child: ListTile(dense: true, leading: Icon(Icons.copy_all_rounded, size: 18), title: Text('Duplica', style: TextStyle(fontSize: 13)))),
                        const PopupMenuItem(value: 'chapter', child: ListTile(dense: true, leading: Icon(Icons.folder_rounded, size: 18), title: Text('Capitolo...', style: TextStyle(fontSize: 13)))),
                        if (widget.liveState.pageCount > 1)
                          const PopupMenuItem(value: 'delete', child: ListTile(dense: true, leading: Icon(Icons.delete_rounded, size: 18, color: Colors.red), title: Text('Elimina', style: TextStyle(fontSize: 13, color: Colors.red)))),
                      ],
                      onSelected: (action) => widget.onPageAction(index, visIdx, action),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              chapterName != null ? '${visIdx + 1} • $chapterName' : '${visIdx + 1}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: isCurrentPage ? FontWeight.bold : FontWeight.normal,
                color: isCurrentPage ? Colors.blue : Colors.grey.shade700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(int docIndex, bool isCurrentPage, PageData? page, CanvasState state) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: isCurrentPage ? Colors.blue : Colors.grey.shade300,
          width: isCurrentPage ? 2.5 : 1,
        ),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: page != null
            ? CustomPaint(
                painter: CanvasRenderEngine(
                  pageData: page,
                  zoom: 1.0,
                  panOffset: Offset.zero,
                  imageCache: state.imageCache,
                ),
                size: Size.infinite,
              )
            : const Center(child: Icon(Icons.description_outlined, color: Colors.grey)),
      ),
    );
  }
}
