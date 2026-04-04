import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:uuid/uuid.dart';

// ═══════════════════════════════════════════════════════════════
//  ENUMS & CONSTANTS
// ═══════════════════════════════════════════════════════════════

enum CanvasTool {
  pen,
  ballpoint,
  brush,
  highlighter,
  eraserStandard,
  eraserStroke,
  lasso,
  text,
  shape,
  image,
  pan,
}

enum EraserSize { small, medium, large }

double eraserSizeToRadius(EraserSize size) {
  switch (size) {
    case EraserSize.small: return 4.0;
    case EraserSize.medium: return 8.0;
    case EraserSize.large: return 20.0;
  }
}

enum PaperType { blank, linedNarrow, linedWide, grid, dotted, cornell, isometric, music }

String paperTypeToString(PaperType type) {
  switch (type) {
    case PaperType.blank: return 'blank';
    case PaperType.linedNarrow: return 'lined_narrow';
    case PaperType.linedWide: return 'lined_wide';
    case PaperType.grid: return 'grid';
    case PaperType.dotted: return 'dotted';
    case PaperType.cornell: return 'cornell';
    case PaperType.isometric: return 'isometric';
    case PaperType.music: return 'music';
  }
}

PaperType paperTypeFromString(String s) {
  switch (s) {
    case 'lined_narrow': return PaperType.linedNarrow;
    case 'lined_wide': return PaperType.linedWide;
    case 'lined': return PaperType.linedWide;
    case 'grid': return PaperType.grid;
    case 'dotted': return PaperType.dotted;
    case 'cornell': return PaperType.cornell;
    case 'isometric': return PaperType.isometric;
    case 'music': return PaperType.music;
    default: return PaperType.blank;
  }
}

String paperTypeLabel(PaperType type) {
  switch (type) {
    case PaperType.blank: return 'Bianco';
    case PaperType.linedNarrow: return 'Righe strette';
    case PaperType.linedWide: return 'Righe larghe';
    case PaperType.grid: return 'Quadretti';
    case PaperType.dotted: return 'Puntinato';
    case PaperType.cornell: return 'Cornell';
    case PaperType.isometric: return 'Isometrico';
    case PaperType.music: return 'Pentagramma';
  }
}

double paperTypeLineSpacing(PaperType type) {
  switch (type) {
    case PaperType.blank: return 0;
    case PaperType.linedNarrow: return 20.0;
    case PaperType.linedWide: return 35.0;
    case PaperType.grid: return 25.0;
    case PaperType.dotted: return 25.0;
    case PaperType.cornell: return 25.0;
    case PaperType.isometric: return 30.0;
    case PaperType.music: return 8.0;
  }
}

// ═══════════════════════════════════════════════════════════════
//  TOOL SETTINGS
// ═══════════════════════════════════════════════════════════════

class ToolSettings {
  final int color;
  final double strokeWidth;
  final double opacity;
  final String shapeType;
  final EraserSize eraserSize;
  final bool shapeRecognition;

  const ToolSettings({
    this.color = 0xFF000000,
    this.strokeWidth = 2.0,
    this.opacity = 1.0,
    this.shapeType = 'rectangle',
    this.eraserSize = EraserSize.medium,
    this.shapeRecognition = true,
  });

  ToolSettings copyWith({
    int? color,
    double? strokeWidth,
    double? opacity,
    String? shapeType,
    EraserSize? eraserSize,
    bool? shapeRecognition,
  }) =>
      ToolSettings(
        color: color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        opacity: opacity ?? this.opacity,
        shapeType: shapeType ?? this.shapeType,
        eraserSize: eraserSize ?? this.eraserSize,
        shapeRecognition: shapeRecognition ?? this.shapeRecognition,
      );
}

// ═══════════════════════════════════════════════════════════════
//  LASSO SELECTION
// ═══════════════════════════════════════════════════════════════

class LassoSelection {
  final List<String> selectedIds;
  final Rect bounds;
  final Offset dragOffset;
  final double rotation;
  final double scale;

  const LassoSelection({
    required this.selectedIds,
    required this.bounds,
    this.dragOffset = Offset.zero,
    this.rotation = 0.0,
    this.scale = 1.0,
  });

  LassoSelection copyWith({
    List<String>? selectedIds,
    Rect? bounds,
    Offset? dragOffset,
    double? rotation,
    double? scale,
  }) => LassoSelection(
    selectedIds: selectedIds ?? this.selectedIds,
    bounds: bounds ?? this.bounds,
    dragOffset: dragOffset ?? this.dragOffset,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
  );
}

// ═══════════════════════════════════════════════════════════════
//  CLIPBOARD & SYMBOLS
// ═══════════════════════════════════════════════════════════════

class CanvasClipboard {
  final List<ContentElement> elements;
  final Rect bounds;
  const CanvasClipboard({required this.elements, required this.bounds});
}

class ReusableSymbol {
  final String id;
  final String name;
  final List<ContentElement> elements;
  final Rect bounds;
  final DateTime createdAt;
  const ReusableSymbol({
    required this.id,
    required this.name,
    required this.elements,
    required this.bounds,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'elements': elements.map((e) => e.toJson()).toList(),
    'bounds': {'left': bounds.left, 'top': bounds.top, 'right': bounds.right, 'bottom': bounds.bottom},
    'createdAt': createdAt.toIso8601String(),
  };

  factory ReusableSymbol.fromJson(Map<String, dynamic> json) => ReusableSymbol(
    id: json['id'] as String,
    name: json['name'] as String,
    elements: (json['elements'] as List).map((e) => ContentElement.fromJson(e as Map<String, dynamic>)).toList(),
    bounds: Rect.fromLTRB(
      (json['bounds']['left'] as num).toDouble(),
      (json['bounds']['top'] as num).toDouble(),
      (json['bounds']['right'] as num).toDouble(),
      (json['bounds']['bottom'] as num).toDouble(),
    ),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

class SymbolLibrary {
  final String id;
  final String name;
  final List<ReusableSymbol> symbols;
  const SymbolLibrary({
    required this.id,
    required this.name,
    this.symbols = const [],
  });
  SymbolLibrary copyWith({String? name, List<ReusableSymbol>? symbols}) =>
      SymbolLibrary(id: id, name: name ?? this.name, symbols: symbols ?? this.symbols);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'symbols': symbols.map((s) => s.toJson()).toList(),
  };

  factory SymbolLibrary.fromJson(Map<String, dynamic> json) => SymbolLibrary(
    id: json['id'] as String,
    name: json['name'] as String,
    symbols: (json['symbols'] as List?)?.map((s) => ReusableSymbol.fromJson(s as Map<String, dynamic>)).toList() ?? [],
  );
}

// ═══════════════════════════════════════════════════════════════
//  CANVAS STATE
// ═══════════════════════════════════════════════════════════════

class CanvasState {
  final NotebookMetadata metadata;
  final DocumentStructure document;
  final Map<String, PageData> pages;
  final int currentPageIndex;
  final CanvasTool currentTool;
  final ToolSettings toolSettings;
  final List<StrokePoint> activeStroke;
  final double zoom;
  final Offset panOffset;
  final List<_UndoEntry> undoStack;
  final List<_UndoEntry> redoStack;
  final bool isDirty;
  final String remotePath;
  final LassoSelection? lassoSelection;
  final List<Offset> lassoPath;
  final Offset? eraserCursorPos;
  final Offset? shapeStartPos;
  final Offset? shapeEndPos;
  final bool showToolOptions;
  final String? selectedElementId;
  final Map<String, ui.Image> imageCache;
  final Map<String, Uint8List> assetBytes;
  final CanvasClipboard? clipboard;
  final List<SymbolLibrary> symbolLibraries;
  // Legacy flat symbols list — computed for backward compatibility
  List<ReusableSymbol> get symbols => symbolLibraries.expand((l) => l.symbols).toList();
  // Interactive shape recognition: holds recognized shape while user adjusts
  final ShapeData? recognizedShape;
  final bool isAdjustingRecognized;
  final ReusableSymbol? pendingSymbol;
  final String? activeChapterId;

  /// Indices of pages visible under the active chapter filter (or all if null).
  List<int> get filteredPageIndices {
    if (activeChapterId == null) {
      return List.generate(document.pages.length, (i) => i);
    }
    return [
      for (int i = 0; i < document.pages.length; i++)
        if (document.pages[i].chapterId == activeChapterId) i,
    ];
  }

  int get filteredPageCount => filteredPageIndices.length;

  /// Position of currentPageIndex within the filtered list (-1 if not found).
  int get currentFilteredIndex => filteredPageIndices.indexOf(currentPageIndex);

  const CanvasState({
    required this.metadata,
    required this.document,
    required this.pages,
    this.currentPageIndex = 0,
    this.currentTool = CanvasTool.pen,
    this.toolSettings = const ToolSettings(),
    this.activeStroke = const [],
    this.zoom = 1.0,
    this.panOffset = Offset.zero,
    this.undoStack = const [],
    this.redoStack = const [],
    this.isDirty = false,
    required this.remotePath,
    this.lassoSelection,
    this.lassoPath = const [],
    this.eraserCursorPos,
    this.shapeStartPos,
    this.shapeEndPos,
    this.showToolOptions = false,
    this.selectedElementId,
    this.imageCache = const {},
    this.assetBytes = const {},
    this.clipboard,
    this.symbolLibraries = const [],
    this.recognizedShape,
    this.isAdjustingRecognized = false,
    this.pendingSymbol,
    this.activeChapterId,
  });

  PageData? get currentPage {
    if (document.pages.isEmpty) return null;
    final entry = document.pages[currentPageIndex];
    return pages[entry.fileName];
  }

  String get currentPageFileName => document.pages[currentPageIndex].fileName;
  int get pageCount => document.pages.length;

  PaperType get currentPaperType {
    final page = currentPage;
    if (page == null) return PaperType.blank;
    return paperTypeFromString(page.layers.background.type);
  }

  CanvasState copyWith({
    NotebookMetadata? metadata,
    DocumentStructure? document,
    Map<String, PageData>? pages,
    int? currentPageIndex,
    CanvasTool? currentTool,
    ToolSettings? toolSettings,
    List<StrokePoint>? activeStroke,
    double? zoom,
    Offset? panOffset,
    List<_UndoEntry>? undoStack,
    List<_UndoEntry>? redoStack,
    bool? isDirty,
    String? remotePath,
    LassoSelection? lassoSelection,
    bool clearLasso = false,
    List<Offset>? lassoPath,
    Offset? eraserCursorPos,
    bool clearEraserCursor = false,
    Offset? shapeStartPos,
    bool clearShapeStart = false,
    Offset? shapeEndPos,
    bool clearShapeEnd = false,
    bool? showToolOptions,
    String? selectedElementId,
    bool clearSelectedElement = false,
    Map<String, ui.Image>? imageCache,
    Map<String, Uint8List>? assetBytes,
    CanvasClipboard? clipboard,
    bool clearClipboard = false,
    List<SymbolLibrary>? symbolLibraries,
    ShapeData? recognizedShape,
    bool clearRecognizedShape = false,
    bool? isAdjustingRecognized,
    ReusableSymbol? pendingSymbol,
    bool clearPendingSymbol = false,
    String? activeChapterId,
    bool clearActiveChapter = false,
  }) =>
      CanvasState(
        metadata: metadata ?? this.metadata,
        document: document ?? this.document,
        pages: pages ?? this.pages,
        currentPageIndex: currentPageIndex ?? this.currentPageIndex,
        currentTool: currentTool ?? this.currentTool,
        toolSettings: toolSettings ?? this.toolSettings,
        activeStroke: activeStroke ?? this.activeStroke,
        zoom: zoom ?? this.zoom,
        panOffset: panOffset ?? this.panOffset,
        undoStack: undoStack ?? this.undoStack,
        redoStack: redoStack ?? this.redoStack,
        isDirty: isDirty ?? this.isDirty,
        remotePath: remotePath ?? this.remotePath,
        lassoSelection: clearLasso ? null : (lassoSelection ?? this.lassoSelection),
        lassoPath: lassoPath ?? this.lassoPath,
        eraserCursorPos: clearEraserCursor ? null : (eraserCursorPos ?? this.eraserCursorPos),
        shapeStartPos: clearShapeStart ? null : (shapeStartPos ?? this.shapeStartPos),
        shapeEndPos: clearShapeEnd ? null : (shapeEndPos ?? this.shapeEndPos),
        showToolOptions: showToolOptions ?? this.showToolOptions,
        selectedElementId: clearSelectedElement ? null : (selectedElementId ?? this.selectedElementId),
        imageCache: imageCache ?? this.imageCache,
        assetBytes: assetBytes ?? this.assetBytes,
        clipboard: clearClipboard ? null : (clipboard ?? this.clipboard),
        symbolLibraries: symbolLibraries ?? this.symbolLibraries,
        recognizedShape: clearRecognizedShape ? null : (recognizedShape ?? this.recognizedShape),
        isAdjustingRecognized: isAdjustingRecognized ?? this.isAdjustingRecognized,
        pendingSymbol: clearPendingSymbol ? null : (pendingSymbol ?? this.pendingSymbol),
        activeChapterId: clearActiveChapter ? null : (activeChapterId ?? this.activeChapterId),
      );
}

class _UndoEntry {
  final String pageFileName;
  final PageData pageData;
  _UndoEntry(this.pageFileName, this.pageData);
}

// ═══════════════════════════════════════════════════════════════
//  CANVAS PROVIDER
// ═══════════════════════════════════════════════════════════════

final canvasProvider =
    StateNotifierProvider<CanvasNotifier, CanvasState?>((ref) {
  return CanvasNotifier(ref);
});

class CanvasNotifier extends StateNotifier<CanvasState?> {
  final Ref _ref;
  // Track whether we've pushed undo for the current eraser/drag gesture
  bool _eraserUndoPushed = false;

  CanvasNotifier(this._ref) : super(null);

  void openNotebook({
    required NotebookMetadata metadata,
    required DocumentStructure document,
    required Map<String, PageData> pages,
    required String remotePath,
    Map<String, Uint8List>? assets,
    List<SymbolLibrary>? symbolLibraries,
  }) {
    state = CanvasState(
      metadata: metadata,
      document: document,
      pages: Map.of(pages),
      remotePath: remotePath,
      assetBytes: assets != null ? Map.of(assets) : const {},
      symbolLibraries: symbolLibraries ?? const [],
    );
    // Decode all asset images into the render cache
    if (assets != null) {
      for (final entry in assets.entries) {
        _decodeAndCacheImage(entry.key, entry.value);
      }
    }
  }

  void closeNotebook() => state = null;

  // ── Tool management ──

  void setTool(CanvasTool tool) {
    if (state == null) return;
    // Auto-set highlighter to yellow, restore black for pens
    ToolSettings? updatedSettings;
    if (tool == CanvasTool.highlighter && state!.toolSettings.color == 0xFF000000) {
      updatedSettings = state!.toolSettings.copyWith(
        color: 0xFFFFEB3B,
        strokeWidth: 12.0,
        opacity: 0.35,
      );
    } else if (state!.currentTool == CanvasTool.highlighter &&
        tool != CanvasTool.highlighter &&
        state!.toolSettings.color == 0xFFFFEB3B) {
      updatedSettings = state!.toolSettings.copyWith(
        color: 0xFF000000,
        strokeWidth: 2.0,
        opacity: 1.0,
      );
    }
    state = state!.copyWith(
      currentTool: tool,
      toolSettings: updatedSettings ?? state!.toolSettings,
      clearLasso: tool != CanvasTool.lasso,
      lassoPath: tool != CanvasTool.lasso ? const [] : state!.lassoPath,
      showToolOptions: false,
      activeStroke: [],
      clearShapeStart: true,
      clearShapeEnd: true,
      clearEraserCursor: true,
      clearRecognizedShape: true,
      isAdjustingRecognized: false,
    );
  }

  void toggleToolOptions() {
    if (state == null) return;
    state = state!.copyWith(showToolOptions: !state!.showToolOptions);
  }

  void setToolSettings(ToolSettings settings) {
    if (state == null) return;
    state = state!.copyWith(toolSettings: settings);
  }

  void setColor(int color) {
    if (state == null) return;
    state = state!.copyWith(
      toolSettings: state!.toolSettings.copyWith(color: color),
    );
  }

  /// Cancel the current stroke without committing (e.g. when pinch-to-zoom starts)
  void cancelStroke() {
    if (state == null) return;
    _eraserUndoPushed = false;
    state = state!.copyWith(
      activeStroke: [],
      clearShapeStart: true,
      clearShapeEnd: true,
      clearEraserCursor: true,
    );
  }

  void setStrokeWidth(double width) {
    if (state == null) return;
    state = state!.copyWith(
      toolSettings: state!.toolSettings.copyWith(strokeWidth: width),
    );
  }

  void setEraserSize(EraserSize size) {
    if (state == null) return;
    state = state!.copyWith(
      toolSettings: state!.toolSettings.copyWith(eraserSize: size),
    );
  }

  void toggleShapeRecognition() {
    if (state == null) return;
    state = state!.copyWith(
      toolSettings: state!.toolSettings.copyWith(
        shapeRecognition: !state!.toolSettings.shapeRecognition,
      ),
    );
  }

  // ── Paper type ──

  void setPaperType(PaperType type) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;

    final fileName = s.currentPageFileName;
    final bgType = paperTypeToString(type);
    final lineSpacing = paperTypeLineSpacing(type);

    final undoStack = _pushUndo(s, fileName, page);

    final updatedPage = PageData(
      pageId: page.pageId,
      pageNumber: page.pageNumber,
      width: page.width,
      height: page.height,
      layers: RenderingLayers(
        background: BackgroundLayer(
          type: bgType,
          color: page.layers.background.color,
          lineSpacing: lineSpacing,
          lineColor: page.layers.background.lineColor,
        ),
        content: page.layers.content,
      ),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt,
      modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
    );
  }

  // ── Drawing ──

  void startStroke(Offset position, double pressure) {
    if (state == null) return;
    final tool = state!.currentTool;

    if (tool == CanvasTool.pan || tool == CanvasTool.text || tool == CanvasTool.image) return;

    if (tool == CanvasTool.lasso) {
      _startLasso(position);
      return;
    }

    if (tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke) {
      _eraserUndoPushed = false; // Reset at start of each eraser gesture
      state = state!.copyWith(eraserCursorPos: position);
      _eraseAt(position);
      return;
    }

    if (tool == CanvasTool.shape) {
      state = state!.copyWith(shapeStartPos: position, shapeEndPos: position);
      return;
    }

    state = state!.copyWith(
      activeStroke: [
        StrokePoint(x: position.dx, y: position.dy, pressure: pressure, timestamp: 0),
      ],
    );
  }

  void continueStroke(Offset position, double pressure) {
    if (state == null) return;
    final tool = state!.currentTool;

    if (tool == CanvasTool.lasso) {
      _continueLasso(position);
      return;
    }

    if (tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke) {
      state = state!.copyWith(eraserCursorPos: position);
      _eraseAt(position);
      return;
    }

    if (tool == CanvasTool.shape) {
      state = state!.copyWith(shapeEndPos: position);
      return;
    }

    // Pen/brush/highlighter: fast notifier handles visual rendering,
    // no need to update Riverpod state on every point (avoids O(n) list copy).
    // Points are committed via commitAndEndStroke on pointer up.
  }

  /// Called from the fast notifier to bulk-set the active stroke before endStroke.
  void commitActiveStroke(List<StrokePoint> points) {
    if (state == null) return;
    state = state!.copyWith(activeStroke: List.of(points));
  }

  /// Commit fast-notifier points and finalize the stroke in a single state update,
  /// avoiding the intermediate frame that causes visible line stretching.
  void commitAndEndStroke(List<StrokePoint> points) {
    if (state == null) return;
    if (points.length < 2) {
      state = state!.copyWith(activeStroke: []);
      return;
    }
    // Set the points, then immediately finalize
    state = state!.copyWith(activeStroke: List.of(points));
    _addStrokeElement(state!);
  }

  void endStroke() {
    if (state == null) return;
    final tool = state!.currentTool;

    if (tool == CanvasTool.lasso) { _endLasso(); return; }
    if (tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke) {
      state = state!.copyWith(clearEraserCursor: true);
      return;
    }
    if (tool == CanvasTool.shape) { _finalizeShape(); return; }

    if (state!.activeStroke.length < 2) {
      state = state!.copyWith(activeStroke: []);
      return;
    }

    final s = state!;
    final page = s.currentPage;
    if (page == null) return;

    _addStrokeElement(s);
  }

  /// Called from the hold-to-recognize timer: tries shape recognition on the
  /// active stroke while the user is still pressing (GoodNotes-style).
  void recognizeHeldStroke(List<StrokePoint> points) {
    if (state == null) return;
    if (!state!.toolSettings.shapeRecognition) return;
    if (points.length < 5) return;

    final recognized = _recognizeShape(points);
    if (recognized != null) {
      state = state!.copyWith(
        activeStroke: [],
        recognizedShape: recognized,
      );
    }
  }

  /// Called when user starts adjusting a recognized shape (pointer down while adjusting).
  void startAdjustRecognized(Offset position) {
    // Nothing to do here — we just mark the gesture started
  }

  /// Called when user drags while adjusting a recognized shape to change its endpoint.
  void adjustRecognizedShape(Offset position) {
    if (state == null || state!.recognizedShape == null) return;
    final shape = state!.recognizedShape!;
    // The user drags to adjust the endpoint / size
    ShapeData updated;
    switch (shape.shapeType) {
      case 'line':
        updated = ShapeData(
          shapeType: 'line',
          x1: shape.x1, y1: shape.y1,
          x2: position.dx, y2: position.dy,
          strokeColor: shape.strokeColor,
          strokeWidth: shape.strokeWidth,
        );
        break;
      case 'circle':
        final cx = (shape.x1 + shape.x2) / 2;
        final cy = (shape.y1 + shape.y2) / 2;
        final radius = sqrt(pow(position.dx - cx, 2) + pow(position.dy - cy, 2));
        updated = ShapeData(
          shapeType: 'circle',
          x1: cx - radius, y1: cy - radius,
          x2: cx + radius, y2: cy + radius,
          strokeColor: shape.strokeColor,
          strokeWidth: shape.strokeWidth,
        );
        break;
      case 'triangle':
      case 'rectangle':
      default:
        // Drag adjusts the bottom-right corner
        updated = ShapeData(
          shapeType: shape.shapeType,
          x1: shape.x1, y1: shape.y1,
          x2: position.dx, y2: position.dy,
          strokeColor: shape.strokeColor,
          strokeWidth: shape.strokeWidth,
          fillColor: shape.fillColor,
          rotation: shape.rotation,
        );
        break;
    }
    state = state!.copyWith(recognizedShape: updated);
  }

  /// For line shapes: keep x1,y1 fixed and move x2,y2 to [position].
  /// This lets the user adjust angle and length after hold-to-recognize.
  void setRecognizedLineEndpoint(Offset position) {
    if (state == null || state!.recognizedShape == null) return;
    final s = state!.recognizedShape!;
    state = state!.copyWith(
      recognizedShape: ShapeData(
        shapeType: s.shapeType,
        x1: s.x1, y1: s.y1,
        x2: position.dx, y2: position.dy,
        strokeColor: s.strokeColor,
        strokeWidth: s.strokeWidth,
        fillColor: s.fillColor,
        rotation: s.rotation,
      ),
    );
  }

  /// Fix top-left corner (x1,y1), resize by dragging bottom-right to [position].
  void resizeRecognizedShape(Offset position) {
    if (state == null || state!.recognizedShape == null) return;
    final s = state!.recognizedShape!;
    // Ensure x2 > x1 and y2 > y1 so the rect/circle is always valid
    final x2 = position.dx > s.x1 + 5 ? position.dx : s.x1 + 5;
    final y2 = position.dy > s.y1 + 5 ? position.dy : s.y1 + 5;
    state = state!.copyWith(
      recognizedShape: ShapeData(
        shapeType: s.shapeType,
        x1: s.x1, y1: s.y1,
        x2: x2, y2: y2,
        strokeColor: s.strokeColor,
        strokeWidth: s.strokeWidth,
        fillColor: s.fillColor,
        rotation: s.rotation,
      ),
    );
  }

  /// Called when user releases while adjusting a recognized shape — commit it.
  void commitRecognizedShape() {
    if (state == null || state!.recognizedShape == null) return;
    _addShapeElement(state!.recognizedShape!);
    state = state!.copyWith(clearRecognizedShape: true, isAdjustingRecognized: false);
  }

  /// Called to dismiss the recognized shape without committing.
  void dismissRecognizedShape() {
    if (state == null) return;
    state = state!.copyWith(clearRecognizedShape: true, isAdjustingRecognized: false);
  }

  void _addStrokeElement(CanvasState s) {
    final page = s.currentPage!;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    String toolType;
    bool isHighlighter = false;
    double opacity = s.toolSettings.opacity;

    switch (s.currentTool) {
      case CanvasTool.pen: toolType = 'pen'; break;
      case CanvasTool.ballpoint: toolType = 'ballpoint'; break;
      case CanvasTool.brush: toolType = 'brush'; break;
      case CanvasTool.highlighter:
        toolType = 'highlighter'; isHighlighter = true; opacity = 0.35; break;
      default: toolType = 'pen';
    }

    // Smooth the raw input points to reduce jitter/wigglyness
    final smoothedPoints = _smoothStrokePoints(s.activeStroke);

    final newElement = ContentElement.stroke(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: StrokeData(
        points: smoothedPoints,
        toolType: toolType,
        color: s.toolSettings.color,
        baseWidth: s.toolSettings.strokeWidth,
        isHighlighter: isHighlighter,
        opacity: opacity,
        timestamp: DateTime.now(),
      ),
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages,
      activeStroke: [],
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
    );
  }

  /// Smooth raw input points using a weighted moving average + point decimation.
  /// Keeps first and last points exact for stroke endpoint accuracy.
  List<StrokePoint> _smoothStrokePoints(List<StrokePoint> raw) {
    if (raw.length < 5) return raw;

    // Adaptive pass count: fewer passes for short strokes
    final passCount = raw.length < 50 ? 1 : 2;
    var points = List<StrokePoint>.from(raw);
    for (int pass = 0; pass < passCount; pass++) {
      final smoothed = List<StrokePoint>.from(points);
      for (int i = 1; i < points.length - 1; i++) {
        final p0 = points[i - 1];
        final p1 = points[i];
        final p2 = points[i + 1];
        smoothed[i] = StrokePoint(
          x: (p0.x + p1.x * 2 + p2.x) / 4,
          y: (p0.y + p1.y * 2 + p2.y) / 4,
          pressure: (p0.pressure + p1.pressure * 2 + p2.pressure) / 4,
          timestamp: p1.timestamp,
        );
      }
      points = smoothed;
    }

    // Decimate points that are too close together
    final decimated = <StrokePoint>[points.first];
    const minDistSq = 1.5 * 1.5;
    for (int i = 1; i < points.length - 1; i++) {
      final last = decimated.last;
      final dx = points[i].x - last.x;
      final dy = points[i].y - last.y;
      if (dx * dx + dy * dy >= minDistSq) {
        decimated.add(points[i]);
      }
    }
    decimated.add(points.last);

    return decimated;
  }

  // ── Shape recognition (improved) ──

  ShapeData? _recognizeShape(List<StrokePoint> points) {
    if (points.length < 5) return null;

    final xs = points.map((p) => p.x).toList();
    final ys = points.map((p) => p.y).toList();
    final minX = xs.reduce(min);
    final maxX = xs.reduce(max);
    final minY = ys.reduce(min);
    final maxY = ys.reduce(max);
    final width = maxX - minX;
    final height = maxY - minY;

    if (width < 10 && height < 10) return null;

    // Total path length
    double pathLen = 0;
    for (int i = 1; i < points.length; i++) {
      pathLen += sqrt(pow(points[i].x - points[i - 1].x, 2) + pow(points[i].y - points[i - 1].y, 2));
    }

    final startEnd = sqrt(
      pow(points.last.x - points.first.x, 2) +
      pow(points.last.y - points.first.y, 2),
    );

    final isClosed = startEnd < max(width, height) * 0.3;

    // ── LINE DETECTION ──
    if (!isClosed && pathLen > 20) {
      final dx = points.last.x - points.first.x;
      final dy = points.last.y - points.first.y;
      final lineLen = sqrt(dx * dx + dy * dy);
      if (lineLen > 20) {
        // Compute max perpendicular deviation from the straight line
        double maxDev = 0;
        for (final p in points) {
          // Distance from point to line (start→end)
          final cross = ((p.x - points.first.x) * dy - (p.y - points.first.y) * dx).abs();
          final dev = cross / lineLen;
          if (dev > maxDev) maxDev = dev;
        }
        // Also check straightness ratio
        final straightness = lineLen / pathLen;
        if (maxDev < lineLen * 0.1 && straightness > 0.85) {
          // Compute average pressure to match the visual pen width
          final avgPressure = points.map((p) => p.pressure).reduce((a, b) => a + b) / points.length;
          final visualWidth = state!.toolSettings.strokeWidth * (0.15 + avgPressure * 0.85);

          // ── ARROW DETECTION ──
          // An arrow is a line where the LAST segment "backtracks" to form a V-tip.
          if (lineLen > 30) {
            final tailCount = max(3, (points.length * 0.2).ceil());
            if (tailCount < points.length - 1) {
              final tailStart = points[points.length - tailCount - 1];
              // Direction of main body vs tail
              final bodyDx = tailStart.x - points.first.x;
              final bodyDy = tailStart.y - points.first.y;
              final tailDx = points.last.x - tailStart.x;
              final tailDy = points.last.y - tailStart.y;
              final bodyLen = sqrt(bodyDx * bodyDx + bodyDy * bodyDy);
              final tailLen = sqrt(tailDx * tailDx + tailDy * tailDy);
              if (bodyLen > 0 && tailLen > 0) {
                final dot = (bodyDx / bodyLen) * (tailDx / tailLen) + (bodyDy / bodyLen) * (tailDy / tailLen);
                // dot < -0.3 means the tail goes backward (arrowhead stroke)
                if (dot < -0.3 && tailLen > lineLen * 0.08 && tailLen < lineLen * 0.5) {
                  return ShapeData(
                    shapeType: 'arrow',
                    x1: points.first.x, y1: points.first.y,
                    x2: tailStart.x, y2: tailStart.y,
                    strokeColor: state!.toolSettings.color,
                    strokeWidth: visualWidth,
                  );
                }
              }
            }
          }

          // Regular straight line
          return ShapeData(
            shapeType: 'line',
            x1: points.first.x, y1: points.first.y,
            x2: points.last.x, y2: points.last.y,
            strokeColor: state!.toolSettings.color,
            strokeWidth: visualWidth,
          );
        }
      }
      return null;
    }

    if (!isClosed) return null;

    // ── CLOSED SHAPE ANALYSIS ──
    // Use centroid (arithmetic mean) for a stable center unaffected by drawing asymmetry
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / points.length;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / points.length;

    // Compute area using shoelace formula
    double area = 0;
    for (int i = 0; i < points.length; i++) {
      final j = (i + 1) % points.length;
      area += points[i].x * points[j].y - points[j].x * points[i].y;
    }
    area = area.abs() / 2;

    // Perimeter
    double perimeter = pathLen + startEnd; // close it

    // Circularity = 4π·area / perimeter²  (1.0 for perfect circle)
    final circularity = (4 * pi * area) / (perimeter * perimeter);

    // Visual width that matches what the fountain pen would draw
    final avgPressureClosed = points.map((p) => p.pressure).reduce((a, b) => a + b) / points.length;
    final shapeVisualWidth = state!.toolSettings.strokeWidth * (0.15 + avgPressureClosed * 0.85);

    // ── CIRCLE / ELLIPSE ──
    if (circularity > 0.65) {
      // Good circle
      final radii = points.map((p) => sqrt(pow(p.x - cx, 2) + pow(p.y - cy, 2))).toList();
      final avgRadius = radii.reduce((a, b) => a + b) / radii.length;
      return ShapeData(
        shapeType: 'circle',
        x1: cx - avgRadius, y1: cy - avgRadius,
        x2: cx + avgRadius, y2: cy + avgRadius,
        strokeColor: state!.toolSettings.color,
        strokeWidth: shapeVisualWidth,
      );
    }

    // ── CORNER DETECTION for triangles and rectangles ──
    final corners = _detectCorners(points, 25.0);

    // ── TRIANGLE ──
    if (corners.length == 3) {
      // Use the 3 corner points for a clean triangle
      final c0 = points[corners[0]];
      final c1 = points[corners[1]];
      final c2 = points[corners[2]];
      // Fit to bounding box of the 3 corners
      final tx = [c0.x, c1.x, c2.x];
      final ty = [c0.y, c1.y, c2.y];
      return ShapeData(
        shapeType: 'triangle',
        x1: tx.reduce(min), y1: ty.reduce(min),
        x2: tx.reduce(max), y2: ty.reduce(max),
        strokeColor: state!.toolSettings.color,
        strokeWidth: shapeVisualWidth,
      );
    }

    // ── RECTANGLE ──
    if (corners.length == 4 || corners.length == 5) {
      // Check how well points hug the bounding box edges
      double rectScore = 0;
      for (final p in points) {
        final distToLeft = (p.x - minX).abs();
        final distToRight = (p.x - maxX).abs();
        final distToTop = (p.y - minY).abs();
        final distToBottom = (p.y - maxY).abs();
        final minDist = [distToLeft, distToRight, distToTop, distToBottom].reduce(min);
        if (minDist < max(width, height) * 0.15) rectScore++;
      }
      if (rectScore / points.length > 0.6) {
        return ShapeData(
          shapeType: 'rectangle',
          x1: minX, y1: minY, x2: maxX, y2: maxY,
          strokeColor: state!.toolSettings.color,
          strokeWidth: shapeVisualWidth,
        );
      }
    }

    // ── FALLBACK: if roughly rectangular shape detected ──
    final aspectRatio = width / height;
    if (aspectRatio > 0.3 && aspectRatio < 3.0 && circularity > 0.45) {
      // Could be a rough rectangle
      double rectScore = 0;
      for (final p in points) {
        final distToLeft = (p.x - minX).abs();
        final distToRight = (p.x - maxX).abs();
        final distToTop = (p.y - minY).abs();
        final distToBottom = (p.y - maxY).abs();
        final minDist = [distToLeft, distToRight, distToTop, distToBottom].reduce(min);
        if (minDist < max(width, height) * 0.15) rectScore++;
      }
      if (rectScore / points.length > 0.65) {
        return ShapeData(
          shapeType: 'rectangle',
          x1: minX, y1: minY, x2: maxX, y2: maxY,
          strokeColor: state!.toolSettings.color,
          strokeWidth: shapeVisualWidth,
        );
      }
    }

    return null;
  }

  List<int> _detectCorners(List<StrokePoint> points, double threshold) {
    final corners = <int>[];
    for (int i = 2; i < points.length - 2; i++) {
      final v1x = points[i].x - points[i - 2].x;
      final v1y = points[i].y - points[i - 2].y;
      final v2x = points[i + 2].x - points[i].x;
      final v2y = points[i + 2].y - points[i].y;
      final dot = v1x * v2x + v1y * v2y;
      final mag1 = sqrt(v1x * v1x + v1y * v1y);
      final mag2 = sqrt(v2x * v2x + v2y * v2y);
      if (mag1 > 0 && mag2 > 0) {
        final cosAngle = dot / (mag1 * mag2);
        final angle = acos(cosAngle.clamp(-1.0, 1.0)) * 180 / pi;
        if (angle > threshold && angle < 170) corners.add(i);
      }
    }
    final merged = <int>[];
    for (final c in corners) {
      if (merged.isEmpty || c - merged.last > points.length / 8) merged.add(c);
    }
    return merged;
  }

  void _addShapeElement(ShapeData shapeData) {
    final s = state!;
    final page = s.currentPage!;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final newElement = ContentElement.shape(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: shapeData,
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages,
      activeStroke: [],
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
    );
  }

  void _finalizeShape() {
    if (state == null) return;
    final s = state!;
    if (s.shapeStartPos == null || s.shapeEndPos == null) {
      state = s.copyWith(clearShapeStart: true, clearShapeEnd: true);
      return;
    }

    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final newElement = ContentElement.shape(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: ShapeData(
        shapeType: s.toolSettings.shapeType,
        x1: s.shapeStartPos!.dx, y1: s.shapeStartPos!.dy,
        x2: s.shapeEndPos!.dx, y2: s.shapeEndPos!.dy,
        strokeColor: s.toolSettings.color,
        strokeWidth: s.toolSettings.strokeWidth,
      ),
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
      clearShapeStart: true,
      clearShapeEnd: true,
    );
  }

  // ── Eraser ──

  void _eraseAt(Offset position) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;

    final eraseRadius = eraserSizeToRadius(s.toolSettings.eraserSize);
    final fileName = s.currentPageFileName;
    final isStrokeEraser = s.currentTool == CanvasTool.eraserStroke;

    final newContent = <ContentElement>[];
    bool changed = false;

    for (final element in page.layers.content) {
      bool shouldRemoveWhole = false;

      if (isStrokeEraser) {
        // Stroke eraser: remove entire element if any point is within radius
        element.map(
          stroke: (stroke) {
            for (final point in stroke.data.points) {
              final dx = point.x - position.dx;
              final dy = point.y - position.dy;
              if (dx * dx + dy * dy < eraseRadius * eraseRadius) {
                shouldRemoveWhole = true;
                break;
              }
            }
          },
          text: (t) {
            final rect = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height);
            if (rect.contains(position)) shouldRemoveWhole = true;
          },
          image: (img) {
            // Allow erasing symbols (placed via symbol library) but not imported images/PDFs
            if (img.data.assetPath.startsWith('symbol_')) {
              final rect = Rect.fromLTWH(img.data.x, img.data.y, img.data.width, img.data.height);
              if (rect.inflate(eraseRadius).contains(position)) shouldRemoveWhole = true;
            }
          },
          shape: (sh) {
            final rect = Rect.fromPoints(
              Offset(sh.data.x1, sh.data.y1),
              Offset(sh.data.x2, sh.data.y2),
            );
            if (rect.inflate(eraseRadius).contains(position)) shouldRemoveWhole = true;
          },
        );

        if (shouldRemoveWhole) {
          changed = true;
          continue; // skip this element
        }
        newContent.add(element);
      } else {
        // Standard eraser: for strokes, remove only points within radius and split
        element.map(
          stroke: (stroke) {
            // Split stroke: keep segments that are outside the eraser circle
            final segments = <List<StrokePoint>>[];
            var currentSegment = <StrokePoint>[];

            for (final point in stroke.data.points) {
              final dx = point.x - position.dx;
              final dy = point.y - position.dy;
              if (dx * dx + dy * dy < eraseRadius * eraseRadius) {
                // Point is within eraser — end current segment
                if (currentSegment.length >= 2) {
                  segments.add(currentSegment);
                }
                currentSegment = [];
                changed = true;
              } else {
                currentSegment.add(point);
              }
            }
            if (currentSegment.length >= 2) {
              segments.add(currentSegment);
            }

            if (segments.isEmpty) {
              changed = true;
              return; // entire stroke erased
            }

            if (segments.length == 1 && segments[0].length == stroke.data.points.length) {
              newContent.add(element); // unchanged
              return;
            }

            // Create new stroke elements for each remaining segment
            for (final seg in segments) {
              newContent.add(ContentElement.stroke(
                id: const Uuid().v4(),
                zIndex: stroke.zIndex,
                data: StrokeData(
                  points: seg,
                  toolType: stroke.data.toolType,
                  color: stroke.data.color,
                  baseWidth: stroke.data.baseWidth,
                  isHighlighter: stroke.data.isHighlighter,
                  opacity: stroke.data.opacity,
                  timestamp: stroke.data.timestamp,
                ),
              ));
            }
          },
          text: (t) {
            final rect = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height);
            if (rect.contains(position)) { changed = true; } else { newContent.add(element); }
          },
          image: (img) {
            // Allow erasing symbols but not imported images/PDFs
            if (img.data.assetPath.startsWith('symbol_')) {
              final rect = Rect.fromLTWH(img.data.x, img.data.y, img.data.width, img.data.height);
              if (rect.contains(position)) { changed = true; } else { newContent.add(element); }
            } else {
              newContent.add(element);
            }
          },
          shape: (sh) {
            final rect = Rect.fromPoints(Offset(sh.data.x1, sh.data.y1), Offset(sh.data.x2, sh.data.y2));
            if (rect.inflate(eraseRadius).contains(position)) { changed = true; } else { newContent.add(element); }
          },
        );
      }
    }

    if (!changed) return;

    // Only push undo once per eraser gesture
    List<_UndoEntry> undoStack;
    if (!_eraserUndoPushed) {
      undoStack = _pushUndo(s, fileName, page);
      _eraserUndoPushed = true;
    } else {
      undoStack = s.undoStack;
    }

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: newContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
    );
  }

  // ── Lasso ──

  void _startLasso(Offset position) {
    if (state!.lassoSelection != null) {
      final sel = state!.lassoSelection!;
      final dragBounds = sel.bounds.translate(sel.dragOffset.dx, sel.dragOffset.dy);
      if (dragBounds.contains(position)) return;
      state = state!.copyWith(clearLasso: true, lassoPath: []);
    }
    state = state!.copyWith(lassoPath: [position]);
  }

  void clearLassoPath() {
    if (state == null) return;
    state = state!.copyWith(clearLasso: true, lassoPath: []);
  }

  /// Accept a locally-collected lasso path (from _LassoPathNotifier in the UI)
  /// and run selection — bypasses per-point Riverpod updates entirely.
  void commitLassoPath(List<Offset> path) {
    if (state == null) return;
    final s = state!;
    if (path.length < 3) {
      state = s.copyWith(lassoPath: [], clearLasso: true);
      return;
    }
    // Reuse _endLasso logic by temporarily setting the path
    state = s.copyWith(lassoPath: path);
    _endLasso();
  }

  void _continueLasso(Offset position) {
    if (state!.lassoPath.isEmpty) return;
    state = state!.copyWith(lassoPath: [...state!.lassoPath, position]);
  }

  void _endLasso() {
    if (state == null) return;
    final s = state!;
    if (s.lassoPath.length < 3) {
      state = s.copyWith(lassoPath: [], clearLasso: true);
      return;
    }

    final page = s.currentPage;
    if (page == null) return;

    // Build the lasso polygon for point-in-polygon testing
    final lassoPolygon = s.lassoPath;

    final selectedIds = <String>[];
    Rect? selectionBounds;

    for (final element in page.layers.content) {
      final elementBounds = _getElementBounds(element);
      if (elementBounds == null) continue;

      bool isSelected = false;

      // Check if any part of the element intersects the lasso polygon:
      // 1. Element center inside lasso
      if (_pointInPolygon(elementBounds.center, lassoPolygon)) {
        isSelected = true;
      }
      // 2. Any corner of element inside lasso
      if (!isSelected) {
        final corners = [elementBounds.topLeft, elementBounds.topRight, elementBounds.bottomLeft, elementBounds.bottomRight];
        for (final corner in corners) {
          if (_pointInPolygon(corner, lassoPolygon)) {
            isSelected = true;
            break;
          }
        }
      }
      // 3. For strokes, check if any stroke point is inside the lasso
      if (!isSelected) {
        element.map(
          stroke: (e) {
            for (final p in e.data.points) {
              if (_pointInPolygon(Offset(p.x, p.y), lassoPolygon)) {
                isSelected = true;
                break;
              }
            }
          },
          text: (_) {},
          image: (_) {},
          shape: (_) {},
        );
      }

      if (isSelected) {
        final id = element.map(
          stroke: (e) => e.id, text: (e) => e.id,
          image: (e) => e.id, shape: (e) => e.id,
        );
        selectedIds.add(id);
        selectionBounds = selectionBounds == null
            ? elementBounds
            : selectionBounds.expandToInclude(elementBounds);
      }
    }

    if (selectedIds.isEmpty || selectionBounds == null) {
      state = s.copyWith(lassoPath: [], clearLasso: true);
      return;
    }

    state = s.copyWith(
      lassoPath: [],
      lassoSelection: LassoSelection(selectedIds: selectedIds, bounds: selectionBounds),
    );
  }

  /// Ray casting point-in-polygon test
  bool _pointInPolygon(Offset point, List<Offset> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      if ((polygon[i].dy > point.dy) != (polygon[j].dy > point.dy) &&
          point.dx < (polygon[j].dx - polygon[i].dx) * (point.dy - polygon[i].dy) / (polygon[j].dy - polygon[i].dy) + polygon[i].dx) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  Rect? _getElementBounds(ContentElement element) {
    return element.map(
      stroke: (e) {
        if (e.data.points.isEmpty) return null;
        final xs = e.data.points.map((p) => p.x);
        final ys = e.data.points.map((p) => p.y);
        final halfW = e.data.baseWidth / 2.0;
        return Rect.fromLTRB(xs.reduce(min) - halfW, ys.reduce(min) - halfW, xs.reduce(max) + halfW, ys.reduce(max) + halfW);
      },
      text: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      image: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      shape: (e) {
        final halfW = e.data.strokeWidth / 2.0;
        return Rect.fromPoints(Offset(e.data.x1, e.data.y1), Offset(e.data.x2, e.data.y2)).inflate(halfW);
      },
    );
  }

  void moveSelection(Offset delta) {
    if (state == null || state!.lassoSelection == null) return;
    state = state!.copyWith(
      lassoSelection: state!.lassoSelection!.copyWith(
        dragOffset: state!.lassoSelection!.dragOffset + delta,
      ),
    );
  }

  void resizeSelection(double scaleFactor) {
    if (state == null || state!.lassoSelection == null) return;
    final s = state!;
    final sel = s.lassoSelection!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);
    final center = sel.bounds.center;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!sel.selectedIds.contains(id)) return element;
      return _scaleElement(element, center, scaleFactor);
    }).toList();

    final newBounds = Rect.fromCenter(
      center: center,
      width: sel.bounds.width * scaleFactor,
      height: sel.bounds.height * scaleFactor,
    );

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
      lassoSelection: LassoSelection(selectedIds: sel.selectedIds, bounds: newBounds),
    );
  }

  void rotateSelection(double angle) {
    if (state == null || state!.lassoSelection == null) return;
    state = state!.copyWith(
      lassoSelection: state!.lassoSelection!.copyWith(
        rotation: state!.lassoSelection!.rotation + angle,
      ),
    );
  }

  void scaleSelectionPreview(double scale) {
    if (state == null || state!.lassoSelection == null) return;
    state = state!.copyWith(
      lassoSelection: state!.lassoSelection!.copyWith(scale: scale),
    );
  }

  void applySelectionTransform() {
    if (state == null || state!.lassoSelection == null) return;
    final s = state!;
    final sel = s.lassoSelection!;
    if (sel.rotation == 0.0 && sel.dragOffset == Offset.zero && sel.scale == 1.0) return;

    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);
    final center = sel.bounds.center;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!sel.selectedIds.contains(id)) return element;
      var updated = element;
      if (sel.scale != 1.0) {
        updated = _scaleElement(updated, center, sel.scale);
      }
      if (sel.rotation != 0.0) {
        updated = _rotateElementAroundCenter(updated, center, sel.rotation);
      }
      if (sel.dragOffset != Offset.zero) {
        updated = _translateElement(updated, sel.dragOffset);
      }
      return updated;
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    // Recalculate bounds from actual transformed element positions
    Rect? newBounds;
    for (final element in updatedContent) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!sel.selectedIds.contains(id)) continue;
      final eb = _getElementBounds(element);
      if (eb == null) continue;
      newBounds = newBounds == null ? eb : newBounds.expandToInclude(eb);
    }

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
      lassoSelection: LassoSelection(
        selectedIds: sel.selectedIds,
        bounds: newBounds ?? sel.bounds.translate(sel.dragOffset.dx, sel.dragOffset.dy),
      ),
    );
  }

  ContentElement _rotateElementAroundCenter(ContentElement element, Offset center, double angle) {
    Offset rotatePoint(double x, double y) {
      final cosA = cos(angle);
      final sinA = sin(angle);
      final dx = x - center.dx;
      final dy = y - center.dy;
      return Offset(center.dx + dx * cosA - dy * sinA, center.dy + dx * sinA + dy * cosA);
    }

    return element.map(
      stroke: (e) => ContentElement.stroke(
        id: e.id, zIndex: e.zIndex,
        data: StrokeData(
          points: e.data.points.map((p) {
            final rp = rotatePoint(p.x, p.y);
            return StrokePoint(x: rp.dx, y: rp.dy, pressure: p.pressure, tilt: p.tilt, timestamp: p.timestamp);
          }).toList(),
          toolType: e.data.toolType, color: e.data.color,
          baseWidth: e.data.baseWidth, isHighlighter: e.data.isHighlighter,
          opacity: e.data.opacity, timestamp: e.data.timestamp,
        ),
      ),
      text: (e) {
        final rp = rotatePoint(e.data.x, e.data.y);
        return ContentElement.text(
          id: e.id, zIndex: e.zIndex,
          data: TextData(
            x: rp.dx, y: rp.dy,
            width: e.data.width, height: e.data.height,
            content: e.data.content, fontFamily: e.data.fontFamily,
            fontSize: e.data.fontSize, color: e.data.color,
            bold: e.data.bold, italic: e.data.italic, alignment: e.data.alignment,
          ),
        );
      },
      image: (e) {
        final rp = rotatePoint(e.data.x, e.data.y);
        return ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: rp.dx, y: rp.dy,
            width: e.data.width, height: e.data.height,
            assetPath: e.data.assetPath,
            rotation: e.data.rotation + angle,
            opacity: e.data.opacity,
            locked: e.data.locked,
            comment: e.data.comment,
          ),
        );
      },
      shape: (e) {
        final rp1 = rotatePoint(e.data.x1, e.data.y1);
        final rp2 = rotatePoint(e.data.x2, e.data.y2);
        return ContentElement.shape(
          id: e.id, zIndex: e.zIndex,
          data: ShapeData(
            shapeType: e.data.shapeType,
            x1: rp1.dx, y1: rp1.dy,
            x2: rp2.dx, y2: rp2.dy,
            strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth,
            fillColor: e.data.fillColor, rotation: e.data.rotation + angle,
          ),
        );
      },
    );
  }

  void deleteSelection() {
    if (state == null || state!.lassoSelection == null) return;
    final s = state!;
    final sel = s.lassoSelection!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final filteredContent = page.layers.content.where((element) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      return !sel.selectedIds.contains(id);
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: filteredContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
      clearLasso: true, lassoPath: [],
    );
  }

  void clearSelection() {
    if (state == null) return;
    state = state!.copyWith(clearLasso: true, lassoPath: []);
  }

  // ── Undo / Redo ──

  void undo() {
    if (state == null || state!.undoStack.isEmpty) return;
    final s = state!;
    final entry = s.undoStack.last;
    final currentPage = s.pages[entry.pageFileName];

    final newUndo = List<_UndoEntry>.from(s.undoStack)..removeLast();
    final newRedo = [...s.redoStack, if (currentPage != null) _UndoEntry(entry.pageFileName, currentPage)];

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[entry.pageFileName] = entry.pageData;

    state = s.copyWith(pages: updatedPages, undoStack: newUndo, redoStack: newRedo, isDirty: true);
  }

  void redo() {
    if (state == null || state!.redoStack.isEmpty) return;
    final s = state!;
    final entry = s.redoStack.last;
    final currentPage = s.pages[entry.pageFileName];

    final newRedo = List<_UndoEntry>.from(s.redoStack)..removeLast();
    final newUndo = [...s.undoStack, if (currentPage != null) _UndoEntry(entry.pageFileName, currentPage)];

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[entry.pageFileName] = entry.pageData;

    state = s.copyWith(pages: updatedPages, undoStack: newUndo, redoStack: newRedo, isDirty: true);
  }

  bool get canUndo => state != null && state!.undoStack.isNotEmpty;
  bool get canRedo => state != null && state!.redoStack.isNotEmpty;

  // ── Page management ──

  void setActiveChapter(String? chapterId) {
    if (state == null) return;
    final s = state!;
    if (chapterId == null) {
      state = s.copyWith(clearActiveChapter: true);
      return;
    }
    // Jump to first page of the chapter
    final firstIdx = s.document.pages.indexWhere((p) => p.chapterId == chapterId);
    state = s.copyWith(
      activeChapterId: chapterId,
      currentPageIndex: firstIdx >= 0 ? firstIdx : s.currentPageIndex,
      clearLasso: true,
      lassoPath: [],
    );
  }

  void goToPage(int index) {
    if (state == null || index < 0 || index >= state!.pageCount) return;
    state = state!.copyWith(
      currentPageIndex: index,
      activeStroke: [],
      clearLasso: true,
      lassoPath: [],
      clearSelectedElement: true,
    );
  }

  void nextPage() {
    if (state == null) return;
    final s = state!;
    final filtered = s.filteredPageIndices;
    final pos = filtered.indexOf(s.currentPageIndex);
    if (pos >= 0 && pos + 1 < filtered.length) {
      goToPage(filtered[pos + 1]);
    }
  }

  void prevPage() {
    if (state == null) return;
    final s = state!;
    final filtered = s.filteredPageIndices;
    final pos = filtered.indexOf(s.currentPageIndex);
    if (pos > 0) {
      goToPage(filtered[pos - 1]);
    }
  }

  void addPage() {
    if (state == null) return;
    final s = state!;
    final uuid = const Uuid();
    final pageId = uuid.v4();
    final now = DateTime.now();
    final pageNum = s.pageCount + 1;
    final fileName = 'page_${pageNum.toString().padLeft(3, '0')}.json';

    final currentBg = s.currentPage?.layers.background;
    final bgType = currentBg?.type ?? 'blank';
    final lineSpacing = currentBg?.lineSpacing ?? 30.0;

    final newPage = PageData(
      pageId: pageId, pageNumber: pageNum,
      width: AppConfig.defaultPageWidth, height: AppConfig.defaultPageHeight,
      layers: RenderingLayers(
        background: BackgroundLayer(type: bgType, lineSpacing: lineSpacing),
        content: const [],
      ),
      createdAt: now, modifiedAt: now,
    );

    // Auto-assign chapter if one is active
    final newEntry = PageEntry(
      pageId: pageId, pageNumber: pageNum, fileName: fileName,
      lastModified: now, chapterId: s.activeChapterId,
    );

    // Insert after current page position (not always at end)
    final insertIndex = s.currentPageIndex + 1;
    final pageList = List<PageEntry>.from(s.document.pages)..insert(insertIndex, newEntry);

    final updatedDoc = DocumentStructure(
      notebookId: s.document.notebookId,
      formatVersion: s.document.formatVersion,
      pages: pageList,
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = newPage;

    state = s.copyWith(
      metadata: s.metadata.copyWith(pageCount: pageNum, modifiedAt: now),
      document: updatedDoc,
      pages: updatedPages,
      currentPageIndex: insertIndex,
      isDirty: true,
    );
  }

  void addChapter(String title) {
    if (state == null) return;
    final s = state!;
    final chapter = Chapter(id: const Uuid().v4(), title: title, pageIds: []);
    state = s.copyWith(
      metadata: s.metadata.copyWith(chapters: [...s.metadata.chapters, chapter], modifiedAt: DateTime.now()),
      isDirty: true,
    );
  }

  void renameChapter(String chapterId, String title) {
    if (state == null) return;
    final s = state!;
    final chapters = s.metadata.chapters.map((c) => c.id == chapterId ? c.copyWith(title: title) : c).toList();
    state = s.copyWith(
      metadata: s.metadata.copyWith(chapters: chapters, modifiedAt: DateTime.now()),
      isDirty: true,
    );
  }

  void deleteChapter(String chapterId) {
    if (state == null) return;
    final s = state!;
    final chapters = s.metadata.chapters.where((c) => c.id != chapterId).toList();
    // Pages remain, but chapterId is cleared.
    final pages = s.document.pages.map((p) => p.chapterId == chapterId ? p.copyWith(chapterId: null) : p).toList();
    final document = s.document.copyWith(pages: pages);
    // If deleted chapter was the active filter, clear the filter
    final clearActiveChapter = s.activeChapterId == chapterId;
    state = s.copyWith(
      metadata: s.metadata.copyWith(chapters: chapters, modifiedAt: DateTime.now()),
      document: document,
      isDirty: true,
      clearActiveChapter: clearActiveChapter,
    );
  }

  void assignPageToChapter(int pageIndex, String? chapterId) {
    if (state == null) return;
    final s = state!;
    if (pageIndex < 0 || pageIndex >= s.document.pages.length) return;
    final pages = List<PageEntry>.from(s.document.pages);
    pages[pageIndex] = pages[pageIndex].copyWith(chapterId: chapterId);
    final document = s.document.copyWith(pages: pages);
    state = s.copyWith(document: document, isDirty: true);
  }

  // ── Zoom & Pan ──

  void setZoom(double zoom) {
    if (state == null) return;
    state = state!.copyWith(zoom: zoom.clamp(0.25, 5.0));
  }

  void setPanOffset(Offset offset) {
    if (state == null) return;
    state = state!.copyWith(panOffset: offset);
  }

  /// Set zoom and pan in a single state update to avoid intermediate render frames.
  void setZoomAndPan(double zoom, Offset pan) {
    if (state == null) return;
    state = state!.copyWith(zoom: zoom.clamp(0.25, 5.0), panOffset: pan);
  }

  // ── Text ──

  void addTextElement(Offset position, String content, {double fontSize = 16}) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final newElement = ContentElement.text(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: TextData(
        x: position.dx, y: position.dy,
        width: 300, height: 50,
        content: content,
        fontSize: fontSize,
        color: s.toolSettings.color,
      ),
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true);
  }

  // ── Helpers ──

  List<_UndoEntry> _pushUndo(CanvasState s, String fileName, PageData page) {
    final stack = [...s.undoStack, _UndoEntry(fileName, page)];
    if (stack.length > 50) stack.removeAt(0);
    return stack;
  }

  PageData _pageWithNewElement(PageData page, ContentElement element) {
    return PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(
        background: page.layers.background,
        content: [...page.layers.content, element],
      ),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );
  }

  ContentElement _translateElement(ContentElement element, Offset offset) {
    return element.map(
      stroke: (e) => ContentElement.stroke(
        id: e.id, zIndex: e.zIndex,
        data: StrokeData(
          points: e.data.points.map((p) => StrokePoint(
            x: p.x + offset.dx, y: p.y + offset.dy,
            pressure: p.pressure, tilt: p.tilt, timestamp: p.timestamp,
          )).toList(),
          toolType: e.data.toolType, color: e.data.color,
          baseWidth: e.data.baseWidth, isHighlighter: e.data.isHighlighter,
          opacity: e.data.opacity, timestamp: e.data.timestamp,
        ),
      ),
      text: (e) => ContentElement.text(
        id: e.id, zIndex: e.zIndex,
        data: TextData(
          x: e.data.x + offset.dx, y: e.data.y + offset.dy,
          width: e.data.width, height: e.data.height,
          content: e.data.content, fontFamily: e.data.fontFamily,
          fontSize: e.data.fontSize, color: e.data.color,
          bold: e.data.bold, italic: e.data.italic, alignment: e.data.alignment,
        ),
      ),
      image: (e) => ContentElement.image(
        id: e.id, zIndex: e.zIndex,
        data: ImageData(
          x: e.data.x + offset.dx, y: e.data.y + offset.dy,
          width: e.data.width, height: e.data.height,
          assetPath: e.data.assetPath, rotation: e.data.rotation, opacity: e.data.opacity,
          locked: e.data.locked, comment: e.data.comment,
        ),
      ),
      shape: (e) => ContentElement.shape(
        id: e.id, zIndex: e.zIndex,
        data: ShapeData(
          shapeType: e.data.shapeType,
          x1: e.data.x1 + offset.dx, y1: e.data.y1 + offset.dy,
          x2: e.data.x2 + offset.dx, y2: e.data.y2 + offset.dy,
          strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth,
          fillColor: e.data.fillColor, rotation: e.data.rotation,
        ),
      ),
    );
  }

  ContentElement _scaleElement(ContentElement element, Offset center, double scale) {
    return element.map(
      stroke: (e) => ContentElement.stroke(
        id: e.id, zIndex: e.zIndex,
        data: StrokeData(
          points: e.data.points.map((p) => StrokePoint(
            x: center.dx + (p.x - center.dx) * scale,
            y: center.dy + (p.y - center.dy) * scale,
            pressure: p.pressure, tilt: p.tilt, timestamp: p.timestamp,
          )).toList(),
          toolType: e.data.toolType, color: e.data.color,
          baseWidth: e.data.baseWidth * scale, isHighlighter: e.data.isHighlighter,
          opacity: e.data.opacity, timestamp: e.data.timestamp,
        ),
      ),
      text: (e) => ContentElement.text(
        id: e.id, zIndex: e.zIndex,
        data: TextData(
          x: center.dx + (e.data.x - center.dx) * scale,
          y: center.dy + (e.data.y - center.dy) * scale,
          width: e.data.width * scale, height: e.data.height * scale,
          content: e.data.content, fontFamily: e.data.fontFamily,
          fontSize: e.data.fontSize * scale, color: e.data.color,
          bold: e.data.bold, italic: e.data.italic, alignment: e.data.alignment,
        ),
      ),
      image: (e) => ContentElement.image(
        id: e.id, zIndex: e.zIndex,
        data: ImageData(
          x: center.dx + (e.data.x - center.dx) * scale,
          y: center.dy + (e.data.y - center.dy) * scale,
          width: e.data.width * scale, height: e.data.height * scale,
          assetPath: e.data.assetPath, rotation: e.data.rotation, opacity: e.data.opacity,
          locked: e.data.locked, comment: e.data.comment,
        ),
      ),
      shape: (e) => ContentElement.shape(
        id: e.id, zIndex: e.zIndex,
        data: ShapeData(
          shapeType: e.data.shapeType,
          x1: center.dx + (e.data.x1 - center.dx) * scale,
          y1: center.dy + (e.data.y1 - center.dy) * scale,
          x2: center.dx + (e.data.x2 - center.dx) * scale,
          y2: center.dy + (e.data.y2 - center.dy) * scale,
          strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth * scale,
          fillColor: e.data.fillColor, rotation: e.data.rotation,
        ),
      ),
    );
  }

  // ── Element selection & transform ──

  void selectElement(String elementId) {
    if (state == null) return;
    state = state!.copyWith(selectedElementId: elementId, clearLasso: true, lassoPath: []);
  }

  void deselectElement() {
    if (state == null) return;
    state = state!.copyWith(clearSelectedElement: true);
  }

  void moveElement(String elementId, Offset delta) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    // Push undo only on the first move (when not yet dirty from a drag)
    // This avoids filling the undo stack with per-frame entries
    final undoStack = s.undoStack;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return _translateElement(element, delta);
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;
    state = s.copyWith(pages: updatedPages, undoStack: undoStack, isDirty: true);
  }

  /// Call this before starting a drag to push undo state once
  void startDragElement(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);
    state = s.copyWith(undoStack: undoStack, redoStack: []);
  }

  void resizeElement(String elementId, Rect newBounds) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return element.map(
        stroke: (e) => e as ContentElement, // can't resize strokes this way
        text: (e) => ContentElement.text(
          id: e.id, zIndex: e.zIndex,
          data: TextData(
            x: newBounds.left, y: newBounds.top,
            width: newBounds.width, height: newBounds.height,
            content: e.data.content, fontFamily: e.data.fontFamily,
            fontSize: e.data.fontSize, color: e.data.color,
            bold: e.data.bold, italic: e.data.italic, alignment: e.data.alignment,
          ),
        ),
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: newBounds.left, y: newBounds.top,
            width: newBounds.width, height: newBounds.height,
            assetPath: e.data.assetPath, rotation: e.data.rotation, opacity: e.data.opacity,
            locked: e.data.locked, comment: e.data.comment,
          ),
        ),
        shape: (e) => ContentElement.shape(
          id: e.id, zIndex: e.zIndex,
          data: ShapeData(
            shapeType: e.data.shapeType,
            x1: newBounds.left, y1: newBounds.top,
            x2: newBounds.right, y2: newBounds.bottom,
            strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth,
            fillColor: e.data.fillColor, rotation: e.data.rotation,
          ),
        ),
      );
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;
    state = s.copyWith(pages: updatedPages, isDirty: true);
  }

  void rotateElement(String elementId, double deltaAngle) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return element.map(
        stroke: (e) => e as ContentElement,
        text: (e) => e as ContentElement,
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: e.data.x, y: e.data.y,
            width: e.data.width, height: e.data.height,
            assetPath: e.data.assetPath,
            rotation: e.data.rotation + deltaAngle,
            opacity: e.data.opacity,
            locked: e.data.locked, comment: e.data.comment,
          ),
        ),
        shape: (e) => ContentElement.shape(
          id: e.id, zIndex: e.zIndex,
          data: ShapeData(
            shapeType: e.data.shapeType,
            x1: e.data.x1, y1: e.data.y1, x2: e.data.x2, y2: e.data.y2,
            strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth,
            fillColor: e.data.fillColor,
            rotation: e.data.rotation + deltaAngle,
          ),
        ),
      );
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;
    state = s.copyWith(pages: updatedPages, isDirty: true);
  }

  void deleteElement(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final filteredContent = page.layers.content.where((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return id != elementId;
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: filteredContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;
    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
      clearSelectedElement: true,
    );
  }

  void bringToFront(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final content = List<ContentElement>.from(page.layers.content);
    final idx = content.indexWhere((e) =>
        e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id) == elementId);
    if (idx < 0 || idx == content.length - 1) return;
    final element = content.removeAt(idx);
    content.add(element);

    _updatePageContent(s, page, fileName, content, undoStack);
  }

  void sendToBack(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final content = List<ContentElement>.from(page.layers.content);
    final idx = content.indexWhere((e) =>
        e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id) == elementId);
    if (idx <= 0) return;
    final element = content.removeAt(idx);
    content.insert(0, element);

    _updatePageContent(s, page, fileName, content, undoStack);
  }

  void toggleImageLock(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return element.map(
        stroke: (e) => e as ContentElement,
        text: (e) => e as ContentElement,
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: e.data.copyWith(locked: !e.data.locked),
        ),
        shape: (e) => e as ContentElement,
      );
    }).toList();

    _updatePageContent(s, page, fileName, updatedContent, s.undoStack);
  }

  void setImageComment(String elementId, String? comment) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return element.map(
        stroke: (e) => e as ContentElement,
        text: (e) => e as ContentElement,
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: e.data.copyWith(comment: comment),
        ),
        shape: (e) => e as ContentElement,
      );
    }).toList();

    _updatePageContent(s, page, fileName, updatedContent, s.undoStack);
  }

  bool isImageLocked(String elementId) {
    if (state == null) return false;
    final page = state!.currentPage;
    if (page == null) return false;
    for (final el in page.layers.content) {
      final id = el.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) continue;
      return el.map(
        stroke: (_) => false, text: (_) => false,
        image: (e) => e.data.locked,
        shape: (_) => false,
      );
    }
    return false;
  }

  void _updatePageContent(CanvasState s, PageData page, String fileName, List<ContentElement> content, List<_UndoEntry> undoStack) {
    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: content),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;
    state = s.copyWith(pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true);
  }

  // ── Image insertion ──

  void addImageElement(Offset position, String fileName, Uint8List bytes, double width, double height) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final pageFileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, pageFileName, page);

    final assetId = '${const Uuid().v4()}_$fileName';

    final newElement = ContentElement.image(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: ImageData(
        x: position.dx, y: position.dy,
        width: width, height: height,
        assetPath: assetId,
      ),
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[pageFileName] = updatedPage;

    // Store raw bytes for persistence and decode for rendering
    final newAssetBytes = Map<String, Uint8List>.from(s.assetBytes);
    newAssetBytes[assetId] = bytes;
    _decodeAndCacheImage(assetId, bytes);

    state = s.copyWith(
      pages: updatedPages,
      assetBytes: newAssetBytes,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
      selectedElementId: newElement.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id),
      currentTool: CanvasTool.lasso,
    );
  }

  Future<void> _decodeAndCacheImage(String assetId, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      if (state != null) {
        final newCache = Map<String, ui.Image>.from(state!.imageCache);
        newCache[assetId] = image;
        state = state!.copyWith(imageCache: newCache);
      }
    } catch (_) {
      // Image decoding failed — placeholder will be shown
    }
  }

  /// Crop an image element using a normalized crop rect (0..1).
  /// Creates a new cropped image from the original bytes.
  Future<void> cropImageElement(String elementId, Rect normalizedCrop) async {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;

    // Find the image element
    ImageData? imgData;
    for (final el in page.layers.content) {
      el.map(
        stroke: (_) {},
        text: (_) {},
        image: (i) { if (i.id == elementId) imgData = i.data; },
        shape: (_) {},
      );
    }
    if (imgData == null) return;

    final cachedImage = s.imageCache[imgData!.assetPath];
    if (cachedImage == null) return;

    // Crop the image using a PictureRecorder
    final srcW = cachedImage.width.toDouble();
    final srcH = cachedImage.height.toDouble();
    final cropSrc = Rect.fromLTRB(
      normalizedCrop.left * srcW,
      normalizedCrop.top * srcH,
      normalizedCrop.right * srcW,
      normalizedCrop.bottom * srcH,
    );
    final cropW = cropSrc.width.toInt();
    final cropH = cropSrc.height.toInt();
    if (cropW < 1 || cropH < 1) return;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      cachedImage,
      cropSrc,
      Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final croppedImage = await picture.toImage(cropW, cropH);

    // Encode the cropped image to PNG bytes
    final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return;
    final croppedBytes = Uint8List.view(byteData.buffer);

    final newAssetId = '${const Uuid().v4()}_cropped.png';

    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    // Update the image element dimensions (scale on page proportionally)
    final scaleX = normalizedCrop.width;
    final scaleY = normalizedCrop.height;
    final newPageW = imgData!.width * scaleX;
    final newPageH = imgData!.height * scaleY;
    final newX = imgData!.x + imgData!.width * normalizedCrop.left;
    final newY = imgData!.y + imgData!.height * normalizedCrop.top;

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      if (id != elementId) return element;
      return element.map(
        stroke: (e) => e as ContentElement,
        text: (e) => e as ContentElement,
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: newX, y: newY,
            width: newPageW, height: newPageH,
            assetPath: newAssetId,
            rotation: e.data.rotation,
            opacity: e.data.opacity,
            locked: e.data.locked, comment: e.data.comment,
          ),
        ),
        shape: (e) => e as ContentElement,
      );
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: updatedContent),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    // Update caches
    final newCache = Map<String, ui.Image>.from(s.imageCache);
    newCache[newAssetId] = croppedImage;
    final newAssets = Map<String, Uint8List>.from(s.assetBytes);
    newAssets[newAssetId] = croppedBytes;

    state = s.copyWith(
      pages: updatedPages,
      imageCache: newCache,
      assetBytes: newAssets,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
    );
  }

  // ── Clipboard operations ──

  void copySelection() {
    if (state == null || state!.lassoSelection == null) return;
    final sel = state!.lassoSelection!;
    final page = state!.currentPage;
    if (page == null) return;

    final copied = page.layers.content.where((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return sel.selectedIds.contains(id);
    }).toList();

    if (copied.isEmpty) return;
    state = state!.copyWith(clipboard: CanvasClipboard(elements: copied, bounds: sel.bounds));
  }

  void cutSelection() {
    copySelection();
    deleteSelection();
  }

  void paste({Offset? at}) {
    if (state == null || state!.clipboard == null) return;
    final s = state!;
    final clip = s.clipboard!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    // Offset paste position slightly from original
    final pasteOffset = at != null
        ? Offset(at.dx - clip.bounds.center.dx, at.dy - clip.bounds.center.dy)
        : const Offset(20, 20);

    final newElements = clip.elements.map((element) {
      final newId = const Uuid().v4();
      final translated = _translateElement(element, pasteOffset);
      // Replace the id with a new one
      return translated.map(
        stroke: (e) => ContentElement.stroke(id: newId, zIndex: page.layers.content.length, data: e.data),
        text: (e) => ContentElement.text(id: newId, zIndex: page.layers.content.length, data: e.data),
        image: (e) => ContentElement.image(id: newId, zIndex: page.layers.content.length, data: e.data),
        shape: (e) => ContentElement.shape(id: newId, zIndex: page.layers.content.length, data: e.data),
      );
    }).toList();

    final updatedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: [...page.layers.content, ...newElements]),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true, clearLasso: true, lassoPath: []);
  }

  void duplicateSelection() {
    copySelection();
    paste();
  }

  void duplicateElement(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;

    final original = page.layers.content.where((e) {
      final id = e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return id == elementId;
    }).firstOrNull;
    if (original == null) return;

    final undoStack = _pushUndo(s, fileName, page);
    final translated = _translateElement(original, const Offset(20, 20));
    final newId = const Uuid().v4();
    final newElement = translated.map(
      stroke: (e) => ContentElement.stroke(id: newId, zIndex: page.layers.content.length, data: e.data),
      text: (e) => ContentElement.text(id: newId, zIndex: page.layers.content.length, data: e.data),
      image: (e) => ContentElement.image(id: newId, zIndex: page.layers.content.length, data: e.data),
      shape: (e) => ContentElement.shape(id: newId, zIndex: page.layers.content.length, data: e.data),
    );

    final updatedPage = _pageWithNewElement(page, newElement);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = updatedPage;

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
      selectedElementId: newId, clearLasso: true,
    );
  }

  // ── Reusable Symbols & Libraries ──

  /// Returns the first library, or creates a default one if none exists.
  SymbolLibrary _defaultLibrary() {
    if (state!.symbolLibraries.isEmpty) {
      final lib = SymbolLibrary(id: const Uuid().v4(), name: 'Simboli');
      state = state!.copyWith(symbolLibraries: [lib]);
      return lib;
    }
    return state!.symbolLibraries.first;
  }

  void createSymbolLibrary(String name) {
    if (state == null) return;
    final lib = SymbolLibrary(id: const Uuid().v4(), name: name);
    state = state!.copyWith(symbolLibraries: [...state!.symbolLibraries, lib]);
  }

  void renameSymbolLibrary(String libId, String newName) {
    if (state == null) return;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) => l.id == libId ? l.copyWith(name: newName) : l).toList(),
    );
  }

  void deleteSymbolLibrary(String libId) {
    if (state == null) return;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.where((l) => l.id != libId).toList(),
    );
  }

  void renameSymbol(String libId, String symbolId, String newName) {
    if (state == null) return;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) {
        if (l.id != libId) return l;
        return l.copyWith(symbols: l.symbols.map((s) => s.id == symbolId
            ? ReusableSymbol(id: s.id, name: newName, elements: s.elements, bounds: s.bounds, createdAt: s.createdAt)
            : s).toList());
      }).toList(),
    );
  }

  void deleteSymbolFromLibrary(String libId, String symbolId) {
    if (state == null) return;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) {
        if (l.id != libId) return l;
        return l.copyWith(symbols: l.symbols.where((s) => s.id != symbolId).toList());
      }).toList(),
    );
  }

  /// Creates a symbol from the current lasso selection and adds it to the
  /// target library (first library if [targetLibId] is null).
  void createSymbolFromSelection(String name, {String? targetLibId}) {
    if (state == null || state!.lassoSelection == null) return;
    final sel = state!.lassoSelection!;
    final page = state!.currentPage;
    if (page == null) return;

    final elements = page.layers.content.where((element) {
      final id = element.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return sel.selectedIds.contains(id);
    }).toList();

    if (elements.isEmpty) return;

    final symbol = ReusableSymbol(
      id: const Uuid().v4(),
      name: name,
      elements: elements,
      bounds: sel.bounds,
      createdAt: DateTime.now(),
    );

    // Ensure there is at least one library
    _defaultLibrary();

    final targetId = targetLibId ?? state!.symbolLibraries.first.id;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) {
        if (l.id != targetId) return l;
        return l.copyWith(symbols: [...l.symbols, symbol]);
      }).toList(),
    );
  }

  void createSymbolFromElement(String elementId, String name) {
    if (state == null) return;
    final page = state!.currentPage;
    if (page == null) return;

    final element = page.layers.content.where((e) {
      final id = e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return id == elementId;
    }).firstOrNull;
    if (element == null) return;

    final bounds = _getElementBounds(element);
    if (bounds == null) return;

    final symbol = ReusableSymbol(
      id: const Uuid().v4(),
      name: name,
      elements: [element],
      bounds: bounds,
      createdAt: DateTime.now(),
    );

    _defaultLibrary();
    final targetId = state!.symbolLibraries.first.id;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) {
        if (l.id != targetId) return l;
        return l.copyWith(symbols: [...l.symbols, symbol]);
      }).toList(),
    );
  }

  // Legacy: keep for backward compatibility
  void deleteSymbol(String symbolId) {
    if (state == null) return;
    state = state!.copyWith(
      symbolLibraries: state!.symbolLibraries.map((l) =>
          l.copyWith(symbols: l.symbols.where((s) => s.id != symbolId).toList())
      ).toList(),
    );
  }

  void setPendingSymbol(ReusableSymbol symbol) {
    if (state == null) return;
    state = state!.copyWith(pendingSymbol: symbol);
  }

  void clearPendingSymbol() {
    if (state == null) return;
    state = state!.copyWith(clearPendingSymbol: true);
  }

  Future<void> insertSymbol(ReusableSymbol symbol, Offset position) async {
    if (state == null) return;
    // Clear pending symbol immediately to prevent multiple placements
    state = state!.copyWith(clearPendingSymbol: true);

    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final symbolImage = await _rasterizeSymbol(symbol);
    if (symbolImage == null || state == null) return;

    // Re-read current state after async gap (state may have changed)
    final current = state!;
    final currentPage = current.currentPage;
    if (currentPage == null) return;
    final currentFileName = current.currentPageFileName;

    // Compute the same padding used during rasterization
    double maxHalfStroke = 2.0;
    for (final e in symbol.elements) {
      e.mapOrNull(
        stroke: (s) {
          final half = s.data.baseWidth / 2.0;
          if (half > maxHalfStroke) maxHalfStroke = half;
        },
        shape: (s) {
          final half = s.data.strokeWidth / 2.0;
          if (half > maxHalfStroke) maxHalfStroke = half;
        },
      );
    }
    final paddedBounds = symbol.bounds.inflate(maxHalfStroke);
    final symbolW = paddedBounds.width <= 0 ? 1.0 : paddedBounds.width;
    final symbolH = paddedBounds.height <= 0 ? 1.0 : paddedBounds.height;
    final assetId = 'symbol_${const Uuid().v4()}.png';

    final imgElement = ContentElement.image(
      id: const Uuid().v4(),
      zIndex: page.layers.content.length,
      data: ImageData(
        x: position.dx - symbolW / 2,
        y: position.dy - symbolH / 2,
        width: symbolW,
        height: symbolH,
        assetPath: assetId,
      ),
    );

    final updatedPage = PageData(
      pageId: currentPage.pageId, pageNumber: currentPage.pageNumber,
      width: currentPage.width, height: currentPage.height,
      layers: RenderingLayers(background: currentPage.layers.background, content: [...currentPage.layers.content, imgElement]),
      assetReferences: currentPage.assetReferences,
      createdAt: currentPage.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(current.pages);
    updatedPages[currentFileName] = updatedPage;

    final newAssets = Map<String, Uint8List>.from(current.assetBytes);
    newAssets[assetId] = symbolImage.$1;
    final newCache = Map<String, ui.Image>.from(current.imageCache);
    newCache[assetId] = symbolImage.$2;

    state = current.copyWith(
      pages: updatedPages,
      assetBytes: newAssets,
      imageCache: newCache,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
      clearSelectedElement: true,
      clearLasso: true,
      clearPendingSymbol: true,
      currentTool: CanvasTool.pen,
    );
  }

  Future<(Uint8List, ui.Image)?> _rasterizeSymbol(ReusableSymbol symbol) async {
    // Render at 3x resolution for crisp quality
    const double renderScale = 3.0;

    // Compute padding: half of the thickest stroke so edges aren't clipped
    double maxHalfStroke = 2.0; // minimum padding
    for (final e in symbol.elements) {
      e.mapOrNull(
        stroke: (s) {
          final half = s.data.baseWidth / 2.0;
          if (half > maxHalfStroke) maxHalfStroke = half;
        },
        shape: (s) {
          final half = s.data.strokeWidth / 2.0;
          if (half > maxHalfStroke) maxHalfStroke = half;
        },
      );
    }

    final paddedBounds = symbol.bounds.inflate(maxHalfStroke);
    final baseW = paddedBounds.width <= 0 ? 1.0 : paddedBounds.width;
    final baseH = paddedBounds.height <= 0 ? 1.0 : paddedBounds.height;
    final renderW = (baseW * renderScale).ceil();
    final renderH = (baseH * renderScale).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, renderW.toDouble(), renderH.toDouble()));
    canvas.scale(renderScale);
    canvas.translate(-paddedBounds.left, -paddedBounds.top);

    for (final element in symbol.elements) {
      element.map(
        stroke: (e) => _paintStrokeSymbol(canvas, e.data),
        text: (e) => _paintTextSymbol(canvas, e.data),
        image: (e) => _paintImageSymbol(canvas, e.data),
        shape: (e) => _paintShapeSymbol(canvas, e.data),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(renderW, renderH);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      image.dispose();
      return null;
    }
    return (byteData.buffer.asUint8List(), image);
  }

  void _paintStrokeSymbol(Canvas canvas, StrokeData stroke) {
    if (stroke.points.length < 2) return;
    final paint = Paint()
      ..color = Color(stroke.color).withValues(alpha: stroke.opacity)
      ..strokeWidth = stroke.baseWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    for (int i = 0; i < stroke.points.length - 1; i++) {
      final p0 = stroke.points[i];
      final p1 = stroke.points[i + 1];
      canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
    }
  }

  void _paintTextSymbol(Canvas canvas, TextData textData) {
    final style = ui.TextStyle(
      color: Color(textData.color),
      fontSize: textData.fontSize,
      fontFamily: textData.fontFamily,
      fontWeight: textData.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: textData.italic ? FontStyle.italic : FontStyle.normal,
    );
    final paragraphStyle = ui.ParagraphStyle(
      textAlign: textData.alignment == 'center'
          ? TextAlign.center
          : textData.alignment == 'right'
              ? TextAlign.right
              : TextAlign.left,
    );
    final builder = ui.ParagraphBuilder(paragraphStyle)..pushStyle(style)..addText(textData.content);
    final paragraph = builder.build()..layout(ui.ParagraphConstraints(width: textData.width));
    canvas.drawParagraph(paragraph, Offset(textData.x, textData.y));
  }

  void _paintImageSymbol(Canvas canvas, ImageData imageData) {
    final cachedImage = state?.imageCache[imageData.assetPath];
    if (cachedImage == null) return;

    canvas.save();
    if (imageData.rotation != 0) {
      final cx = imageData.x + imageData.width / 2;
      final cy = imageData.y + imageData.height / 2;
      canvas.translate(cx, cy);
      canvas.rotate(imageData.rotation);
      canvas.translate(-cx, -cy);
    }

    final srcRect = Rect.fromLTWH(0, 0, cachedImage.width.toDouble(), cachedImage.height.toDouble());
    final dstRect = Rect.fromLTWH(imageData.x, imageData.y, imageData.width, imageData.height);
    final paint = Paint()..color = Colors.white.withValues(alpha: imageData.opacity);
    canvas.drawImageRect(cachedImage, srcRect, dstRect, paint);
    canvas.restore();
  }

  void _paintShapeSymbol(Canvas canvas, ShapeData shape) {
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
      case 'arrow':
        canvas.drawLine(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2), strokePaint);
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
      default:
        canvas.drawRect(Rect.fromPoints(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2)), strokePaint);
    }
    canvas.restore();
  }

  // ── Page management ──

  void deletePage(int index) {
    if (state == null || state!.pageCount <= 1) return;
    final s = state!;
    final entry = s.document.pages[index];
    final fileName = entry.fileName;

    final newPages = List<PageEntry>.from(s.document.pages)..removeAt(index);
    // Renumber pages
    for (int i = 0; i < newPages.length; i++) {
      newPages[i] = PageEntry(
        pageId: newPages[i].pageId,
        pageNumber: i + 1,
        fileName: newPages[i].fileName,
        lastModified: newPages[i].lastModified,
      );
    }

    final updatedDoc = DocumentStructure(
      notebookId: s.document.notebookId,
      formatVersion: s.document.formatVersion,
      pages: newPages,
    );

    final updatedPages = Map<String, PageData>.from(s.pages)..remove(fileName);
    final newIndex = index >= newPages.length ? newPages.length - 1 : index;

    state = s.copyWith(
      document: updatedDoc,
      pages: updatedPages,
      currentPageIndex: newIndex,
      metadata: s.metadata.copyWith(pageCount: newPages.length, modifiedAt: DateTime.now()),
      isDirty: true,
    );
  }

  void duplicatePage(int index) {
    if (state == null) return;
    final s = state!;
    final entry = s.document.pages[index];
    final sourcePage = s.pages[entry.fileName];
    if (sourcePage == null) return;

    final uuid = const Uuid();
    final pageId = uuid.v4();
    final now = DateTime.now();
    final pageNum = s.pageCount + 1;
    final fileName = 'page_${pageNum.toString().padLeft(3, '0')}.json';

    final newPage = PageData(
      pageId: pageId, pageNumber: pageNum,
      width: sourcePage.width, height: sourcePage.height,
      layers: RenderingLayers(
        background: sourcePage.layers.background,
        content: sourcePage.layers.content.map((e) {
          final newId = uuid.v4();
          return e.map(
            stroke: (e) => ContentElement.stroke(id: newId, zIndex: e.zIndex, data: e.data),
            text: (e) => ContentElement.text(id: newId, zIndex: e.zIndex, data: e.data),
            image: (e) => ContentElement.image(id: newId, zIndex: e.zIndex, data: e.data),
            shape: (e) => ContentElement.shape(id: newId, zIndex: e.zIndex, data: e.data),
          );
        }).toList(),
      ),
      createdAt: now, modifiedAt: now,
    );

    final newEntry = PageEntry(pageId: pageId, pageNumber: pageNum, fileName: fileName, lastModified: now);

    final updatedDoc = DocumentStructure(
      notebookId: s.document.notebookId,
      formatVersion: s.document.formatVersion,
      pages: [...s.document.pages, newEntry],
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = newPage;

    state = s.copyWith(
      document: updatedDoc,
      pages: updatedPages,
      currentPageIndex: pageNum - 1,
      metadata: s.metadata.copyWith(pageCount: pageNum, modifiedAt: now),
      isDirty: true,
    );
  }

  void reorderPage(int oldIndex, int newIndex) {
    if (state == null) return;
    final s = state!;
    final pages = List<PageEntry>.from(s.document.pages);
    final entry = pages.removeAt(oldIndex);
    pages.insert(newIndex, entry);

    // Renumber
    for (int i = 0; i < pages.length; i++) {
      pages[i] = PageEntry(
        pageId: pages[i].pageId,
        pageNumber: i + 1,
        fileName: pages[i].fileName,
        lastModified: pages[i].lastModified,
        chapterId: pages[i].chapterId,
      );
    }

    final updatedDoc = DocumentStructure(
      notebookId: s.document.notebookId,
      formatVersion: s.document.formatVersion,
      pages: pages,
    );

    // Adjust current page index to follow the page that was being viewed
    int newCurrentIndex = s.currentPageIndex;
    if (s.currentPageIndex == oldIndex) {
      newCurrentIndex = newIndex;
    } else if (oldIndex < s.currentPageIndex && newIndex >= s.currentPageIndex) {
      newCurrentIndex--;
    } else if (oldIndex > s.currentPageIndex && newIndex <= s.currentPageIndex) {
      newCurrentIndex++;
    }

    state = s.copyWith(document: updatedDoc, currentPageIndex: newCurrentIndex, isDirty: true);
  }

  // ── Clear page ──

  void clearPage() {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final clearedPage = PageData(
      pageId: page.pageId, pageNumber: page.pageNumber,
      width: page.width, height: page.height,
      layers: RenderingLayers(background: page.layers.background, content: const []),
      assetReferences: page.assetReferences,
      createdAt: page.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = clearedPage;

    state = s.copyWith(pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true);
  }

  // ── Select all elements ──

  void selectAll() {
    if (state == null) return;
    final page = state!.currentPage;
    if (page == null || page.layers.content.isEmpty) return;

    final allIds = page.layers.content.map((e) {
      return e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
    }).toList();

    Rect? bounds;
    for (final element in page.layers.content) {
      final b = _getElementBounds(element);
      if (b != null) bounds = bounds == null ? b : bounds.expandToInclude(b);
    }

    if (bounds == null) return;
    state = state!.copyWith(
      lassoSelection: LassoSelection(selectedIds: allIds, bounds: bounds),
      currentTool: CanvasTool.lasso,
    );
  }

  // ── Reset zoom ──

  void resetZoom() {
    if (state == null) return;
    state = state!.copyWith(zoom: 1.0, panOffset: Offset.zero);
  }

  Future<void> save() async {
    if (state == null || !state!.isDirty) return;
    final s = state!;
    final syncService = _ref.read(syncServiceProvider);
    if (syncService == null) return;

    final updatedMeta = s.metadata.copyWith(modifiedAt: DateTime.now());

    await syncService.uploadNotebook(
      remotePath: s.remotePath,
      metadata: updatedMeta,
      document: s.document,
      pages: s.pages,
      assets: s.assetBytes.isNotEmpty ? s.assetBytes : null,
      symbolLibraries: s.symbolLibraries.isNotEmpty
          ? s.symbolLibraries.map((l) => l.toJson()).toList()
          : null,
    );

    state = s.copyWith(metadata: updatedMeta, isDirty: false);
  }
}
