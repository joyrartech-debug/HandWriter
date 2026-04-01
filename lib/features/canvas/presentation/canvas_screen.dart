import 'dart:async';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/features/canvas/presentation/canvas_toolbar.dart';
import 'package:handwriter/features/canvas/presentation/image_handle_overlay.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

class CanvasScreen extends ConsumerStatefulWidget {
  const CanvasScreen({super.key});

  @override
  ConsumerState<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends ConsumerState<CanvasScreen> {
  bool _isSaving = false;

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
  Offset _lastHoldPos = Offset.zero;

  // ── High-performance active stroke notifier ──
  final _activeStrokeNotifier = _ActiveStrokeNotifier();

  // ── Auto-save timer ──
  Timer? _autoSaveTimer;
  static const _autoSaveInterval = Duration(seconds: 30);

  // ── Keyboard shortcuts ──
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _startAutoSave();
  }

  @override
  void dispose() {
    _activeStrokeNotifier.dispose();
    _autoSaveTimer?.cancel();
    _holdRecognizeTimer?.cancel();
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
    setState(() => _isSaving = true);
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
      if (mounted) setState(() => _isSaving = false);
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
          ref.read(canvasProvider.notifier).paste();
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

    // Escape — deselect
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(canvasProvider.notifier).clearSelection();
      ref.read(canvasProvider.notifier).deselectElement();
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

  double _getRenderScale(CanvasState state, Size canvasSize) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    return min(canvasSize.width / pageW, canvasSize.height / pageH);
  }

  // ── Pointer handling ──

  void _onPointerDown(PointerDownEvent event, CanvasState state, Size canvasSize) {
    _activePointers++;
    if (_activePointers >= 2) {
      // Cancel any active stroke when multi-touch starts (pinch-to-zoom)
      if (_activeStrokeNotifier.isActive) {
        _activeStrokeNotifier.clear();
        ref.read(canvasProvider.notifier).cancelStroke();
      }
      return;
    }

    final tool = state.currentTool;
    final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
    final pressure = event.pressure > 0 ? event.pressure : 0.5;

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

    // If there's a selected element and we're tapping on it, start dragging it
    // regardless of the active tool (don't draw over it).
    if (state.selectedElementId != null) {
      final selBounds = _getSelectedElementBounds(state);
      if (selBounds != null && selBounds.inflate(10).contains(pagePos)) {
        // Let ImageHandleOverlay handle this interaction
        return;
      }
      // Tapped outside selection — deselect
      ref.read(canvasProvider.notifier).deselectElement();
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

      // Check if tapping on an image element — select it
      final tappedElement = _findElementAt(state, pagePos);
      if (tappedElement != null) {
        ref.read(canvasProvider.notifier).selectElement(tappedElement);
        return;
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
      ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
      return;
    }

    ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
    // Also push first point to fast notifier (only for pen/brush/highlighter)
    _activeStrokeNotifier.start(pagePos, pressure);
  }

  void _onPointerMove(PointerMoveEvent event, CanvasState state, Size canvasSize) {
    if (_activePointers >= 2) return;

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
      ref.read(canvasProvider.notifier).setPanOffset(state.panOffset + delta);
      return;
    }

    if (_isDraggingSelection) {
      final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
      final delta = pagePos - _lastLassoDragPos;
      _lastLassoDragPos = pagePos;
      ref.read(canvasProvider.notifier).moveSelection(delta);
      return;
    }

    // If a selected element exists and pointer is within it, don't draw
    if (state.selectedElementId != null) return;

    final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
    final pressure = event.pressure > 0 ? event.pressure : 0.5;

    // Fast path: during pen/brush drawing, only update the notifier (no Riverpod rebuild).
    // Riverpod is only updated for eraser/lasso/shape tools that need state tracking.
    if (_activeStrokeNotifier.isActive) {
      // Shape recognized during hold → drag the shape around
      if (_shapeRecognizedDuringHold) {
        final delta = pagePos - _lastHoldPos;
        _lastHoldPos = pagePos;
        ref.read(canvasProvider.notifier).moveRecognizedShape(delta);
        return;
      }

      _activeStrokeNotifier.addPoint(pagePos, pressure);
      _lastHoldPos = pagePos;

      // Reset hold-to-recognize timer (GoodNotes-style: recognize when user pauses)
      _holdRecognizeTimer?.cancel();
      final currentState = ref.read(canvasProvider);
      if (currentState != null && currentState.toolSettings.shapeRecognition) {
        _holdRecognizeTimer = Timer(const Duration(milliseconds: 400), () {
          _tryRecognizeHeldStroke();
        });
      }
      return;
    }
    ref.read(canvasProvider.notifier).continueStroke(pagePos, pressure);
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

    _holdRecognizeTimer?.cancel();

    if (_isDraggingSelection) {
      _isDraggingSelection = false;
      ref.read(canvasProvider.notifier).applySelectionMove();
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

    if (state.currentTool == CanvasTool.pan) return;
    if (state.currentTool == CanvasTool.image) return;
    // Commit fast notifier points to Riverpod state before finalizing
    if (_activeStrokeNotifier.isActive && _activeStrokeNotifier.points.isNotEmpty) {
      ref.read(canvasProvider.notifier).commitActiveStroke(_activeStrokeNotifier.points);
    }
    _activeStrokeNotifier.clear();
    ref.read(canvasProvider.notifier).endStroke();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers = max(0, _activePointers - 1);
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
    if (details.pointerCount < 2) return;
    final notifier = ref.read(canvasProvider.notifier);
    final state = ref.read(canvasProvider);
    if (state == null) return;

    final newZoom = (_baseZoom * details.scale).clamp(0.3, 5.0);

    // Zoom toward focal point: adjust pan so focal point stays fixed
    final focalPoint = details.localFocalPoint;
    final oldZoom = state.zoom;
    final newPan = focalPoint - (focalPoint - state.panOffset) * (newZoom / oldZoom);

    notifier.setZoom(newZoom);
    notifier.setPanOffset(newPan);
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

    if (text != null && text.isNotEmpty) {
      ref.read(canvasProvider.notifier).addTextElement(pagePos, text);
    }
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
      _insertPdf(bytes, file.name, pagePos);
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

  void _insertPdf(Uint8List bytes, String name, Offset pagePos) {
    ref.read(canvasProvider.notifier).addImageElement(pagePos, name, bytes, 400, 560);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF inserito come elemento')),
      );
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
                symbolCount: canvasState.symbols.length,
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

        MouseCursor cursor = SystemMouseCursors.precise;
        if (canvasState.currentTool == CanvasTool.pan) cursor = SystemMouseCursors.grab;
        if (canvasState.currentTool == CanvasTool.image) cursor = SystemMouseCursors.click;

        return MouseRegion(
          cursor: cursor,
          child: Stack(
            children: [
              // Canvas painter
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    // Right-click → context menu
                    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
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
                      final newPan = cursorPos - (cursorPos - canvasState.panOffset) * (newZoom / oldZoom);
                      ref.read(canvasProvider.notifier).setZoom(newZoom);
                      ref.read(canvasProvider.notifier).setPanOffset(newPan);
                    }
                  },
                  child: GestureDetector(
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onDoubleTap: () => ref.read(canvasProvider.notifier).resetZoom(),
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
                            lassoPath: canvasState.lassoPath.isNotEmpty ? canvasState.lassoPath : null,
                            shapePreview: (canvasState.shapeStartPos != null && canvasState.shapeEndPos != null)
                                ? (canvasState.shapeStartPos!, canvasState.shapeEndPos!, canvasState.toolSettings.shapeType)
                                : null,
                            recognizedShapePreview: canvasState.recognizedShape,
                            zoom: canvasState.zoom,
                            panOffset: canvasState.panOffset,
                            imageCache: canvasState.imageCache,
                            repaintNotifier: _activeStrokeNotifier,
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

    return [
      ImageHandleOverlay(
        bounds: screenRect,
        rotation: rotation,
        onDragStart: () {
          ref.read(canvasProvider.notifier).startDragElement(state.selectedElementId!);
        },
        onMove: (delta) {
          final pageDelta = delta / (state.zoom * _getRenderScale(state, canvasSize));
          ref.read(canvasProvider.notifier).moveElement(state.selectedElementId!, pageDelta);
        },
        onResize: (newBounds) {
          final pageTL = _toPageCoords(newBounds.topLeft, state, canvasSize);
          final pageBR = _toPageCoords(newBounds.bottomRight, state, canvasSize);
          ref.read(canvasProvider.notifier).resizeElement(state.selectedElementId!, Rect.fromPoints(pageTL, pageBR));
        },
        onRotate: (angle) {
          ref.read(canvasProvider.notifier).rotateElement(state.selectedElementId!, angle);
        },
        onDelete: () {
          ref.read(canvasProvider.notifier).deleteElement(state.selectedElementId!);
        },
        onDeselect: () {
          ref.read(canvasProvider.notifier).deselectElement();
        },
      ),
    ];
  }

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
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Crea simbolo riutilizzabile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome del simbolo',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Crea')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(canvasProvider.notifier).createSymbolFromSelection(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Simbolo "$name" creato!'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _promptCreateSymbolFromElement(String elementId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Crea simbolo riutilizzabile'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome del simbolo',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Crea')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(canvasProvider.notifier).createSymbolFromElement(elementId, name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Simbolo "$name" creato!'), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  void _showSymbolsDialog(Offset insertPos) {
    final state = ref.read(canvasProvider);
    if (state == null || state.symbols.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nessun simbolo salvato. Seleziona elementi con il lazo e crea un simbolo.'), duration: Duration(seconds: 2)),
        );
      }
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inserisci simbolo'),
        content: SizedBox(
          width: 300,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: state.symbols.length,
            itemBuilder: (ctx, i) {
              final symbol = state.symbols[i];
              return ListTile(
                leading: const Icon(Icons.star_rounded, color: Colors.amber),
                title: Text(symbol.name),
                subtitle: Text('${symbol.elements.length} elementi'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () {
                    ref.read(canvasProvider.notifier).deleteSymbol(symbol.id);
                    Navigator.pop(ctx);
                  },
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(canvasProvider.notifier).insertSymbol(symbol, insertPos);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Simbolo "${symbol.name}" inserito'), duration: const Duration(seconds: 1)),
                    );
                  }
                },
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Chiudi'))],
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

      // Render all pages to images, then compose a PDF
      final pageImages = <ui.Image>[];
      for (final entry in state.document.pages) {
        final page = state.pages[entry.fileName];
        if (page == null) continue;

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, page.width, page.height));
        canvas.drawRect(Rect.fromLTWH(0, 0, page.width, page.height), Paint()..color = Colors.white);

        final engine = CanvasRenderEngine(
          pageData: page,
          zoom: 1.0,
          panOffset: Offset.zero,
          imageCache: state.imageCache,
        );
        engine.paintPage(canvas, Size(page.width, page.height), 1.0, Offset.zero);

        final picture = recorder.endRecording();
        final img = await picture.toImage(page.width.toInt(), page.height.toInt());
        pageImages.add(img);
      }

      // Convert images to PNG bytes and write as a simple multi-page image export
      // For a proper PDF, we'd use the `printing` package, but for now export each page as PNG
      for (int i = 0; i < pageImages.length; i++) {
        final byteData = await pageImages[i].toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) continue;
        final pagePath = savePath.replaceAll('.pdf', '_p${i + 1}.png');
        await _writeFile(pagePath, byteData.buffer.asUint8List());
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${pageImages.length} pagine esportate come PNG!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore export: $e')));
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
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Page thumbnails button
          IconButton(
            icon: Icon(Icons.view_carousel_outlined, color: Colors.grey.shade700, size: 20),
            onPressed: () => _showPageManager(canvasState),
            tooltip: 'Gestione pagine',
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.chevron_left_rounded, color: Colors.grey.shade800, size: 22),
            onPressed: canvasState.currentPageIndex > 0
                ? () => ref.read(canvasProvider.notifier).prevPage()
                : null,
            splashRadius: 18,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(12)),
            child: Text(
              '${canvasState.currentPageIndex + 1} / ${canvasState.pageCount}',
              style: TextStyle(color: Colors.grey.shade800, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right_rounded, color: Colors.grey.shade800, size: 22),
            onPressed: canvasState.currentPageIndex < canvasState.pageCount - 1
                ? () => ref.read(canvasProvider.notifier).nextPage()
                : null,
            splashRadius: 18,
          ),
          const Spacer(),
          IconButton(
            icon: Icon(Icons.add_rounded, color: Colors.blue.shade600, size: 20),
            onPressed: () => ref.read(canvasProvider.notifier).addPage(),
            splashRadius: 18,
            tooltip: 'Aggiungi pagina',
          ),
        ],
      ),
    );
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
        return DraggableScrollableSheet(
          initialChildSize: 0.4,
          maxChildSize: 0.7,
          minChildSize: 0.25,
          expand: false,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Text('Pagine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.add_rounded, color: Colors.blue),
                        onPressed: () {
                          ref.read(canvasProvider.notifier).addPage();
                          Navigator.pop(ctx);
                        },
                        tooltip: 'Aggiungi pagina',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: scrollController,
                    itemCount: canvasState.pageCount,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex--;
                      ref.read(canvasProvider.notifier).reorderPage(oldIndex, newIndex);
                    },
                    itemBuilder: (ctx, index) {
                      final isCurrentPage = index == canvasState.currentPageIndex;
                      final entry = canvasState.document.pages[index];
                      final page = canvasState.pages[entry.fileName];
                      final elementCount = page?.layers.content.length ?? 0;

                      return ListTile(
                        key: ValueKey(entry.pageId),
                        selected: isCurrentPage,
                        selectedTileColor: const Color(0xFFE3F2FD),
                        leading: Container(
                          width: 36, height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(
                              color: isCurrentPage ? Colors.blue : Colors.grey.shade300,
                              width: isCurrentPage ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isCurrentPage ? FontWeight.bold : FontWeight.normal,
                                color: isCurrentPage ? Colors.blue : Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ),
                        title: Text('Pagina ${index + 1}'),
                        subtitle: Text('$elementCount elementi', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert_rounded, size: 20),
                          onSelected: (action) {
                            switch (action) {
                              case 'goto':
                                ref.read(canvasProvider.notifier).goToPage(index);
                                Navigator.pop(ctx);
                                break;
                              case 'duplicate':
                                ref.read(canvasProvider.notifier).duplicatePage(index);
                                Navigator.pop(ctx);
                                break;
                              case 'delete':
                                if (canvasState.pageCount > 1) {
                                  ref.read(canvasProvider.notifier).deletePage(index);
                                }
                                break;
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'goto', child: Text('Vai a pagina')),
                            const PopupMenuItem(value: 'duplicate', child: Text('Duplica')),
                            if (canvasState.pageCount > 1)
                              const PopupMenuItem(value: 'delete', child: Text('Elimina', style: TextStyle(color: Colors.red))),
                          ],
                        ),
                        onTap: () {
                          ref.read(canvasProvider.notifier).goToPage(index);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
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
    _points.add(StrokePoint(x: pos.dx, y: pos.dy, pressure: pressure,
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
