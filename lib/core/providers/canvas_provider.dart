import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
//  PENDING REMOTE CHANGES — shown to user for accept/dismiss
// ═══════════════════════════════════════════════════════════════

enum PageChangeType { modified, added, deleted }

class PageChangeDetail {
  final String fileName;
  final int pageNumber;
  final int pageIndex;
  final String? chapterName;
  final PageChangeType changeType;
  /// Element count diff: e.g. {strokes: +3, images: -1}
  final int localStrokeCount;
  final int remoteStrokeCount;
  final int localImageCount;
  final int remoteImageCount;
  final int localShapeCount;
  final int remoteShapeCount;
  final int localTextCount;
  final int remoteTextCount;

  const PageChangeDetail({
    required this.fileName,
    required this.pageNumber,
    required this.pageIndex,
    this.chapterName,
    required this.changeType,
    this.localStrokeCount = 0,
    this.remoteStrokeCount = 0,
    this.localImageCount = 0,
    this.remoteImageCount = 0,
    this.localShapeCount = 0,
    this.remoteShapeCount = 0,
    this.localTextCount = 0,
    this.remoteTextCount = 0,
  });

  bool get hasElementDiff =>
      localStrokeCount != remoteStrokeCount ||
      localImageCount != remoteImageCount ||
      localShapeCount != remoteShapeCount ||
      localTextCount != remoteTextCount;
}

class PendingRemoteChanges {
  final NotebookMetadata metadata;
  final DocumentStructure document;
  final Map<String, PageData> pages;
  final Map<String, Uint8List> assets;

  /// Per-page change details for the UI.
  final List<PageChangeDetail> changedPages;
  final int newPageCount;
  final int modifiedPageCount;
  final int deletedPageCount;
  final int newAssetCount;

  const PendingRemoteChanges({
    required this.metadata,
    required this.document,
    required this.pages,
    required this.assets,
    this.changedPages = const [],
    this.newPageCount = 0,
    this.modifiedPageCount = 0,
    this.deletedPageCount = 0,
    this.newAssetCount = 0,
  });

  int get totalChanges => newPageCount + modifiedPageCount + deletedPageCount + newAssetCount;
}

// ═══════════════════════════════════════════════════════════════
//  PAGE CONFLICT — local vs remote for visual diff
// ═══════════════════════════════════════════════════════════════

class PageConflict {
  final String fileName;
  final int pageNumber;
  final String? chapterName;
  final PageData localPage;
  final PageData remotePage;
  /// Pre-decoded images for rendering local version in preview.
  final Map<String, ui.Image> localImageCache;
  /// Pre-decoded images for rendering remote version in preview.
  final Map<String, ui.Image> remoteImageCache;

  const PageConflict({
    required this.fileName,
    required this.pageNumber,
    this.chapterName,
    required this.localPage,
    required this.remotePage,
    this.localImageCache = const {},
    this.remoteImageCache = const {},
  });
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
  final List<UndoEntry> undoStack;
  final List<UndoEntry> redoStack;
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
  final bool pendingPaste;
  final String? activeChapterId;
  final PendingRemoteChanges? pendingRemoteChanges;
  final List<PageConflict> pendingConflicts;

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
    this.zoom = 2.0,
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
    this.pendingPaste = false,
    this.activeChapterId,
    this.pendingRemoteChanges,
    this.pendingConflicts = const [],
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
    List<UndoEntry>? undoStack,
    List<UndoEntry>? redoStack,
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
    bool? pendingPaste,
    String? activeChapterId,
    bool clearActiveChapter = false,
    PendingRemoteChanges? pendingRemoteChanges,
    bool clearPendingRemoteChanges = false,
    List<PageConflict>? pendingConflicts,
    bool clearPendingConflicts = false,
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
        pendingPaste: pendingPaste ?? this.pendingPaste,
        activeChapterId: clearActiveChapter ? null : (activeChapterId ?? this.activeChapterId),
        pendingRemoteChanges: clearPendingRemoteChanges ? null : (pendingRemoteChanges ?? this.pendingRemoteChanges),
        pendingConflicts: clearPendingConflicts ? const [] : (pendingConflicts ?? this.pendingConflicts),
      );
}

class UndoEntry {
  final String pageFileName;
  final PageData pageData;
  UndoEntry(this.pageFileName, this.pageData);
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
  Size? _viewportSize;

  /// Mutex: serializes save() and _pullRemoteChanges() so they never
  /// race each other. Only one can modify state at a time.
  Completer<void>? _syncLock;
  bool _disposed = false;

  /// Acquire exclusive sync lock. Returns when lock available.
  /// Returns false if notifier was disposed while waiting.
  Future<bool> _acquireSyncLock() async {
    while (_syncLock != null && !_disposed) {
      try {
        await _syncLock!.future;
      } catch (_) {
        break;
      }
    }
    if (_disposed) return false;
    _syncLock = Completer<void>();
    return true;
  }

  /// Release sync lock.
  void _releaseSyncLock() {
    final lock = _syncLock;
    _syncLock = null;
    if (lock != null && !lock.isCompleted) lock.complete();
  }

  /// Force-release lock and cancel pending waiters (used on close/dispose).
  void _forceReleaseSyncLock() {
    final lock = _syncLock;
    _syncLock = null;
    if (lock != null && !lock.isCompleted) lock.complete();
  }

  /// Page file names modified since the last successful delta sync.
  /// Cleared after each sync cycle. Used to upload only changed pages.
  final Set<String> _dirtyPageFileNames = {};

  /// Asset keys modified since last sync (e.g. "images/foo.png").
  final Set<String> _dirtyAssetKeys = {};

  /// Snapshot of page map references from the last sync.
  /// Used for identity-based dirty detection: if `pages[fileName]` is a
  /// different object than `_lastSyncedPages[fileName]`, it was edited.
  Map<String, PageData> _lastSyncedPages = {};

  /// Cache of encoded page JSON bytes per fileName. Reused when the current
  /// [PageData] instance is identical to the one that produced the cached
  /// bytes — i.e. the page wasn't mutated since the last save. For big
  /// notebooks where only one page changes per save, this avoids re-encoding
  /// every other page on every write.
  final Map<String, _CachedPageJson> _pageJsonCache = {};

  /// ETag of the remote metadata.json — used to detect remote changes.
  String? _remoteMetaEtag;

  /// Per-page WebDAV ETags from the last pull — used to detect which pages changed.
  Map<String, String> _lastPageEtags = {};

  /// Timer for pulling remote changes from other devices.
  Timer? _pullTimer;

  CanvasNotifier(this._ref) : super(null);

  void setViewportSize(Size size) {
    final wasNull = _viewportSize == null;
    _viewportSize = size;
    // On first layout, centre the page if zoom != 1.0
    if (wasNull && state != null && state!.zoom != 1.0) {
      // Defer state update to avoid modifying state during build phase
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (state != null) {
          state = state!.copyWith(panOffset: _centeredPanOffset(state!.zoom));
        }
      });
    }
  }

  /// Compute the panOffset that horizontally centres the page at given zoom.
  Offset _centeredPanOffset(double zoom) {
    final vp = _viewportSize;
    if (vp == null) return Offset.zero;
    return Offset(vp.width * (1 - zoom) / 2, 0);
  }

  void openNotebook({
    required NotebookMetadata metadata,
    required DocumentStructure document,
    required Map<String, PageData> pages,
    required String remotePath,
    Map<String, Uint8List>? assets,
    List<SymbolLibrary>? symbolLibraries,
  }) {
    // Try to restore the last viewed chapter and page for this notebook
    _restoreLastPosition(metadata, document, pages, remotePath, assets, symbolLibraries);
  }

  Future<void> _restoreLastPosition(
    NotebookMetadata metadata,
    DocumentStructure document,
    Map<String, PageData> pages,
    String remotePath,
    Map<String, Uint8List>? assets,
    List<SymbolLibrary>? symbolLibraries,
  ) async {
    String? restoredChapterId;
    int startPageIndex = 0;

    try {
      final prefs = await SharedPreferences.getInstance();
      final nbId = metadata.id;
      final savedChapter = prefs.getString('last_chapter_$nbId');
      final savedPage = prefs.getInt('last_page_$nbId') ?? 0;

      // Validate saved chapter still exists
      if (savedChapter != null && metadata.chapters.any((c) => c.id == savedChapter)) {
        restoredChapterId = savedChapter;
        // Validate saved page index is within range and belongs to the chapter
        if (savedPage >= 0 && savedPage < document.pages.length) {
          startPageIndex = savedPage;
        } else {
          // Page index out of range, find first page of the chapter
          final idx = document.pages.indexWhere((p) => p.chapterId == savedChapter);
          if (idx >= 0) startPageIndex = idx;
        }
      } else if (metadata.chapters.isNotEmpty) {
        // No saved position or chapter was deleted — default to first chapter
        restoredChapterId = metadata.chapters.first.id;
        final idx = document.pages.indexWhere((p) => p.chapterId == restoredChapterId);
        if (idx >= 0) startPageIndex = idx;
      }
    } catch (_) {
      // SharedPreferences failed — fall back to first chapter
      if (metadata.chapters.isNotEmpty) {
        restoredChapterId = metadata.chapters.first.id;
        final idx = document.pages.indexWhere((p) => p.chapterId == restoredChapterId);
        if (idx >= 0) startPageIndex = idx;
      }
    }

    state = CanvasState(
      metadata: metadata,
      document: document,
      pages: Map.of(pages),
      remotePath: remotePath,
      assetBytes: assets != null ? Map.of(assets) : const {},
      symbolLibraries: symbolLibraries ?? const [],
      activeChapterId: restoredChapterId,
      currentPageIndex: startPageIndex,
    );

    // Initialize delta sync tracking
    _disposed = false;
    _lastSyncedPages = Map.of(pages);
    _pageJsonCache.clear();
    _dirtyPageFileNames.clear();
    _dirtyAssetKeys.clear();
    // Pre-populate page ETags so the first pull doesn't see every page as
    // "changed" (empty cache vs all remote ETags → false positives).
    _initPageEtags(metadata.id);
    _startPullTimer();

    // Decode all asset images into the render cache
    if (assets != null) {
      for (final entry in assets.entries) {
        _decodeAndCacheImage(entry.key, entry.value);
      }
    }
  }

  /// Fetch current page ETags from the server and cache them so the first
  /// pull cycle has a baseline to diff against.
  Future<void> _initPageEtags(String notebookId) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      if (syncService == null) return;
      final changeState = await syncService.getRemoteChangeState(notebookId);
      _lastPageEtags = Map.of(changeState.pageEtags);
      _remoteMetaEtag = changeState.metaEtag;
      debugPrint('[Canvas] Initialized ${_lastPageEtags.length} page ETags');
    } catch (e) {
      debugPrint('[Canvas] Could not init page ETags: $e');
    }
  }

  void closeNotebook() {
    _disposed = true;
    _saveLastPosition();
    _pullTimer?.cancel();
    _pullTimer = null;
    _isPulling = false;
    _forceReleaseSyncLock();
    _dirtyPageFileNames.clear();
    _dirtyAssetKeys.clear();
    _lastSyncedPages = {};
    _pageJsonCache.clear();
    // Keep _remoteMetaEtag, _lastPageEtags across
    // close/open to avoid re-pulling all pages on re-enter.
    state = null;
  }

  Future<void> _saveLastPosition() async {
    if (state == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final nbId = state!.metadata.id;
      await prefs.setInt('last_page_$nbId', state!.currentPageIndex);
      if (state!.activeChapterId != null) {
        await prefs.setString('last_chapter_$nbId', state!.activeChapterId!);
      } else {
        await prefs.remove('last_chapter_$nbId');
      }
    } catch (_) {
      // Non-critical — silently ignore
    }
  }

  // ── Tool management ──

  void setTool(CanvasTool tool) {
    if (state == null) return;
    
    // Bake any pending lasso transformations before switching tools
    if (tool != CanvasTool.lasso && state!.lassoSelection != null) {
      applySelectionTransform();
    }

    // Auto-set highlighter to yellow; always restore pen defaults (width/opacity
    // and color only when it was the default yellow) when leaving highlighter,
    // so picking a custom color in highlighter mode doesn't leak into the pen.
    ToolSettings? updatedSettings;
    if (tool == CanvasTool.highlighter &&
        state!.currentTool != CanvasTool.highlighter) {
      updatedSettings = state!.toolSettings.copyWith(
        color: state!.toolSettings.color == 0xFF000000
            ? 0xFFFFEB3B
            : state!.toolSettings.color,
        strokeWidth: 12.0,
        opacity: 0.35,
      );
    } else if (state!.currentTool == CanvasTool.highlighter &&
        tool != CanvasTool.highlighter) {
      updatedSettings = state!.toolSettings.copyWith(
        color: state!.toolSettings.color == 0xFFFFEB3B
            ? 0xFF000000
            : state!.toolSettings.color,
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

    // Try shape recognition at commit time if enabled
    if (s.toolSettings.shapeRecognition && s.activeStroke.length >= 5) {
      final recognized = _recognizeShape(s.activeStroke);
      if (recognized != null) {
        _commitRecognizedShape(s, recognized);
        return;
      }
    }

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
      case 'arrow':
        final snapped = _snapLineEnd(shape.x1, shape.y1, position.dx, position.dy);
        updated = ShapeData(
          shapeType: shape.shapeType,
          x1: shape.x1, y1: shape.y1,
          x2: snapped[0], y2: snapped[1],
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
    final snapped = _snapLineEnd(s.x1, s.y1, position.dx, position.dy);
    state = state!.copyWith(
      recognizedShape: ShapeData(
        shapeType: s.shapeType,
        x1: s.x1, y1: s.y1,
        x2: snapped[0], y2: snapped[1],
        strokeColor: s.strokeColor,
        strokeWidth: s.strokeWidth,
        fillColor: s.fillColor,
        rotation: s.rotation,
      ),
    );
  }

  /// Fix top-left corner (x1,y1), resize by dragging bottom-right to [position].
  /// For circles: keep center fixed, change radius based on cursor distance.
  void resizeRecognizedShape(Offset position) {
    if (state == null || state!.recognizedShape == null) return;
    final s = state!.recognizedShape!;

    if (s.shapeType == 'circle' || s.shapeType == 'triangle') {
      // Keep center fixed, compute new size from cursor distance to center
      final cx = (s.x1 + s.x2) / 2;
      final cy = (s.y1 + s.y2) / 2;
      final dx = (position.dx - cx).abs();
      final dy = (position.dy - cy).abs();
      final halfW = max(dx, 5.0);
      final halfH = max(dy, 5.0);
      state = state!.copyWith(
        recognizedShape: ShapeData(
          shapeType: s.shapeType,
          x1: cx - halfW, y1: cy - halfH,
          x2: cx + halfW, y2: cy + halfH,
          strokeColor: s.strokeColor,
          strokeWidth: s.strokeWidth,
          fillColor: s.fillColor,
          rotation: s.rotation,
        ),
      );
      return;
    }

    // x1,y1 is the anchor (opposite corner from pen at recognition time).
    // x2,y2 follows the cursor freely — rendering uses Rect.fromPoints
    // so any ordering is handled correctly.
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

  /// Immediately commit a recognized shape (used at endStroke for instant recognition).
  void _commitRecognizedShape(CanvasState s, ShapeData shape) {
    _addShapeElement(shape);
    state = state!.copyWith(activeStroke: []);
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

    // Smooth the raw input points to reduce jitter/wigglyness.
    // Skip smoothing for dense stylus input (iPad etc.) — already smooth,
    // and the gaussian stretch distorts precise pen strokes.
    final smoothedPoints = s.activeStroke.length > 80
        ? s.activeStroke
        : _smoothStrokePoints(s.activeStroke);

    final newElement = ContentElement.stroke(
      id: const Uuid().v4(),
      zIndex: _nextZIndex(page),
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

  /// Light position smoothing on commit to reduce jitter.
  /// Only smooths interior points — first and last stay fixed to preserve
  /// stroke bounds. Pressure is NOT smoothed (already done in real-time).
  List<StrokePoint> _smoothStrokePoints(List<StrokePoint> raw) {
    if (raw.length < 5) return raw;
    // Single pass of 1-2-1 Gaussian smoothing — subtle cleanup without
    // visibly reshaping the stroke the user drew.
    final result = List<StrokePoint>.from(raw);
    for (int i = 1; i < raw.length - 1; i++) {
      final p0 = raw[i - 1];
      final p1 = raw[i];
      final p2 = raw[i + 1];
      result[i] = StrokePoint(
        x: (p0.x + p1.x * 2 + p2.x) / 4,
        y: (p0.y + p1.y * 2 + p2.y) / 4,
        pressure: p1.pressure,
        timestamp: p1.timestamp,
      );
    }
    return result;
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
    final maxDim = max(width, height);

    if (maxDim < 10) return null;

    // Total path length vs straight line distance
    double pathLen = 0;
    for (int i = 1; i < points.length; i++) {
      pathLen += sqrt(pow(points[i].x - points[i - 1].x, 2) + pow(points[i].y - points[i - 1].y, 2));
    }
    final startEndDist = sqrt(pow(points.last.x - points.first.x, 2) + pow(points.last.y - points.first.y, 2));
    
    final avgPressure = points.map((p) => p.pressure).reduce((a, b) => a + b) / points.length;
    final visualWidth = state!.toolSettings.strokeWidth * (0.15 + avgPressure * 0.85);
    final color = state!.toolSettings.color;

    // ── LINE & ARROW DETECTION ──
    // If the path length is barely longer than the distance between start and end, it's a straight line.
    if (pathLen > 20 && (pathLen / startEndDist) < 1.25) {
      // Basic arrow detection (checking if the tail hooks back)
      final tailStart = points[(points.length * 0.8).round()];
      final tailDist = sqrt(pow(points.last.x - tailStart.x, 2) + pow(points.last.y - tailStart.y, 2));
      if (tailDist > 5 && tailDist < maxDim * 0.4) {
        // We can confidently assume it's an arrow if it hooks
        final arrowEnd = _snapLineEnd(points.first.x, points.first.y, points.last.x, points.last.y);
        return ShapeData(
          shapeType: 'arrow',
          x1: points.first.x, y1: points.first.y,
          x2: arrowEnd[0], y2: arrowEnd[1],
          strokeColor: color, strokeWidth: visualWidth,
        );
      }
      
      return ShapeData(
        shapeType: 'line',
        x1: points.first.x, y1: points.first.y,
        x2: _snapLineEnd(points.first.x, points.first.y, points.last.x, points.last.y)[0],
        y2: _snapLineEnd(points.first.x, points.first.y, points.last.x, points.last.y)[1],
        strokeColor: color, strokeWidth: visualWidth,
      );
    }

    // ── CLOSURE CHECK ──
    // Allow a generous overlap gap for messy hand drawing
    final isClosed = startEndDist < maxDim * 0.35;
    if (!isClosed) return null;

    // Auto-fill closed shapes with a transparent version of the stroke color.
    const fillAlpha = 0x30; // ~19% opacity
    final autoFill = (color & 0x00FFFFFF) | (fillAlpha << 24);

    // ── POLYGON DETECTION (Douglas-Peucker) — run early to inform circle vs rect ──
    final offsets = points.map((p) => Offset(p.x, p.y)).toList();
    
    // Lowered epsilon to 0.06 to avoid over-smoothing rounded corners
    final simplified = _douglasPeucker(offsets, maxDim * 0.06);
    
    // Remove the last point if it overlaps the first to get the true corner count
    List<Offset> corners = List.from(simplified);
    if (corners.length > 1 && (corners.first - corners.last).distance < maxDim * 0.25) {
      corners.removeLast();
    }

    // ── CIRCLE DETECTION (Radial Variance) ──
    // A circle has many Douglas-Peucker segments (7+), while
    // rectangles have 4-6 and triangles have 3. Use corner count
    // to disambiguate: only accept circle if NOT in polygon range (4-6).
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    double sumR = 0, sumR2 = 0;
    
    for (final p in points) {
      final r = sqrt(pow(p.x - cx, 2) + pow(p.y - cy, 2));
      sumR += r;
      sumR2 += r * r;
    }
    
    final avgR = sumR / points.length;
    final radialVariance = (sumR2 / points.length) - (avgR * avgR);
    final radialCV = avgR > 0 ? sqrt(radialVariance) / avgR : 0.0;
    final aspectRatio = min(width, height) / max(width, height);

    // Accept circle if: good radial fit AND either not in rectangle corner range,
    // or radial fit is very strong (CV < 0.08 overrides corner count).
    final isCircleCandidate = radialCV < 0.15 && aspectRatio > 0.60;
    final notPolygonRange = corners.length < 4 || corners.length > 6;
    final veryStrongCircle = radialCV < 0.08;

    if (isCircleCandidate && (notPolygonRange || veryStrongCircle)) {
      // Use avgR (mean distance from center to drawn points) to preserve drawn size
      final r = avgR;
      return ShapeData(
        shapeType: 'circle',
        x1: cx - r, y1: cy - r,
        x2: cx + r, y2: cy + r,
        strokeColor: color, strokeWidth: visualWidth,
        fillColor: autoFill,
      );
    }

    // ── TRIANGLE ──
    if (corners.length == 3) {
      // Anchor (x1,y1) = corner opposite the pen; Free (x2,y2) = pen's corner.
      // This lets the user drag x2,y2 naturally after recognition.
      final endPoint = Offset(points.last.x, points.last.y);
      final boxCorners = [
        Offset(minX, minY), Offset(maxX, minY),
        Offset(maxX, maxY), Offset(minX, maxY)
      ];
      int closestIdx = 0;
      double closestDist = double.infinity;
      for (int i = 0; i < 4; i++) {
        final d = (boxCorners[i] - endPoint).distance;
        if (d < closestDist) {
          closestDist = d;
          closestIdx = i;
        }
      }
      return ShapeData(
        shapeType: 'triangle',
        x1: boxCorners[(closestIdx + 2) % 4].dx,
        y1: boxCorners[(closestIdx + 2) % 4].dy,
        x2: boxCorners[closestIdx].dx,
        y2: boxCorners[closestIdx].dy,
        strokeColor: color, strokeWidth: visualWidth,
        fillColor: autoFill,
      );
    }

    // ── RHOMBUS (4 corners with roughly equal edge lengths, diamond shape) ──
    if (corners.length == 4) {
      // Check if all edge lengths are roughly equal (within 30%)
      final edgeLengths = <double>[];
      for (int i = 0; i < 4; i++) {
        edgeLengths.add((corners[i] - corners[(i + 1) % 4]).distance);
      }
      final avgEdge = edgeLengths.reduce((a, b) => a + b) / 4;
      final edgeVariation = edgeLengths.map((e) => (e - avgEdge).abs() / avgEdge).reduce(max);

      if (edgeVariation < 0.30) {
        // Check it's more diamond-like than rectangular:
        // diagonals should be perpendicular (or close to it)
        final d1 = corners[2] - corners[0]; // diagonal 1
        final d2 = corners[3] - corners[1]; // diagonal 2
        final dotProduct = (d1.dx * d2.dx + d1.dy * d2.dy).abs();
        final d1Len = d1.distance;
        final d2Len = d2.distance;
        final cosAngle = (d1Len > 0 && d2Len > 0) ? dotProduct / (d1Len * d2Len) : 1.0;

        // Also check the shape area vs bounding box area ratio
        // A rhombus fills ~50% of its bounding box, a rectangle fills ~100%
        double shapeArea = 0;
        for (int i = 0; i < 4; i++) {
          final p1 = corners[i];
          final p2 = corners[(i + 1) % 4];
          shapeArea += (p1.dx * p2.dy) - (p2.dx * p1.dy);
        }
        shapeArea = shapeArea.abs() / 2;
        final bboxArea = width * height;
        final fillRatio = bboxArea > 0 ? shapeArea / bboxArea : 1.0;

        // Rhombus: near-perpendicular diagonals OR diamond-like fill ratio (<75%)
        if (cosAngle < 0.3 || fillRatio < 0.75) {
          return ShapeData(
            shapeType: 'rhombus',
            x1: minX, y1: minY,
            x2: maxX, y2: maxY,
            strokeColor: color, strokeWidth: visualWidth,
            fillColor: autoFill,
          );
        }
      }
    }

    // ── RECTANGLE (With slant/rotation support) ──
    if (corners.length >= 4 && corners.length <= 6) {
      double maxEdgeLen = 0;
      double angle = 0;
      for (int i = 0; i < corners.length; i++) {
        final p1 = corners[i];
        final p2 = corners[(i + 1) % corners.length];
        final dist = (p1 - p2).distance;
        if (dist > maxEdgeLen) {
          maxEdgeLen = dist;
          angle = atan2(p2.dy - p1.dy, p2.dx - p1.dx);
        }
      }

      final snappedAngle = (angle / (pi / 2)).round() * (pi / 2);
      if ((angle - snappedAngle).abs() < 0.2) angle = snappedAngle;

      // For axis-aligned rectangles (angle is multiple of π/2), use the
      // simple bounding box directly. The OBB rotation is only needed for
      // truly tilted rectangles — using it for axis-aligned ones produces
      // distorted coordinates that break resize and rendering.
      final isAxisAligned = (angle % (pi / 2)).abs() < 0.01 || ((angle % (pi / 2)).abs() - pi / 2).abs() < 0.01;

      double rMinX, rMaxX, rMinY, rMaxY;
      double finalAngle;

      if (isAxisAligned) {
        // Use raw bounding box — no rotation needed
        rMinX = minX;
        rMaxX = maxX;
        rMinY = minY;
        rMaxY = maxY;
        finalAngle = 0;
      } else {
        // Tilted rectangle: compute OBB
        final cosA = cos(-angle);
        final sinA = sin(-angle);
        rMinX = double.infinity;
        rMaxX = double.negativeInfinity;
        rMinY = double.infinity;
        rMaxY = double.negativeInfinity;

        for (final p in offsets) {
          final dx = p.dx - cx;
          final dy = p.dy - cy;
          final rx = dx * cosA - dy * sinA;
          final ry = dx * sinA + dy * cosA;
          if (rx < rMinX) rMinX = rx;
          if (rx > rMaxX) rMaxX = rx;
          if (ry < rMinY) rMinY = ry;
          if (ry > rMaxY) rMaxY = ry;
        }
        // Convert back to page-space
        rMinX += cx;
        rMaxX += cx;
        rMinY += cy;
        rMaxY += cy;
        finalAngle = angle;
      }

      final obbW = rMaxX - (isAxisAligned ? rMinX : rMinX);
      final obbH = rMaxY - (isAxisAligned ? rMinY : rMinY);
      final obbArea = obbW * obbH;

      double shapeArea = 0;
      for (int i = 0; i < corners.length; i++) {
        final p1 = corners[i];
        final p2 = corners[(i + 1) % corners.length];
        shapeArea += (p1.dx * p2.dy) - (p2.dx * p1.dy);
      }
      shapeArea = (shapeArea.abs() / 2);

      if (obbArea > 0 && (shapeArea / obbArea) > 0.70) {
        // Find which corner the pen ended near
        final endPoint = Offset(points.last.x, points.last.y);
        final rectCorners = [
          Offset(rMinX, rMinY), // Top-Left
          Offset(rMaxX, rMinY), // Top-Right
          Offset(rMaxX, rMaxY), // Bottom-Right
          Offset(rMinX, rMaxY), // Bottom-Left
        ];
        int closestIdx = 0;
        double closestDist = double.infinity;
        for (int i = 0; i < 4; i++) {
          final d = (rectCorners[i] - endPoint).distance;
          if (d < closestDist) {
            closestDist = d;
            closestIdx = i;
          }
        }
        return ShapeData(
          shapeType: 'rectangle',
          x1: rectCorners[(closestIdx + 2) % 4].dx,
          y1: rectCorners[(closestIdx + 2) % 4].dy,
          x2: rectCorners[closestIdx].dx,
          y2: rectCorners[closestIdx].dy,
          rotation: finalAngle,
          strokeColor: color, strokeWidth: visualWidth,
          fillColor: autoFill,
        );
      }
    }

    return null;
  }

  // ── MATHEMATICAL HELPERS ──

  /// Snap line end to nearest common angle if within threshold.
  /// Snaps to multiples of 15° (0°, 15°, 30°, 45°, 60°, 75°, 90°, …).
  /// Returns [snappedX2, snappedY2].
  List<double> _snapLineEnd(double x1, double y1, double x2, double y2) {
    final dx = x2 - x1;
    final dy = y2 - y1;
    final lineLen = sqrt(dx * dx + dy * dy);
    if (lineLen < 5) return [x2, y2];

    final angle = atan2(dy, dx); // radians
    // Snap to multiples of 15° (π/12)
    const snapStep = pi / 12; // 15 degrees
    const snapThreshold = 0.065; // ~3.7 degrees in radians

    final nearest = (angle / snapStep).round() * snapStep;
    if ((angle - nearest).abs() < snapThreshold) {
      return [x1 + lineLen * cos(nearest), y1 + lineLen * sin(nearest)];
    }
    return [x2, y2];
  }

  /// Douglas-Peucker algorithm to reduce complex paths into core geometric vertices
  List<Offset> _douglasPeucker(List<Offset> points, double epsilon) {
    if (points.length <= 2) return points;

    double maxDist = 0.0;
    int index = 0;
    final end = points.length - 1;

    for (int i = 1; i < end; i++) {
      final dist = _perpendicularDistance(points[i], points[0], points[end]);
      if (dist > maxDist) {
        maxDist = dist;
        index = i;
      }
    }

    if (maxDist > epsilon) {
      final left = _douglasPeucker(points.sublist(0, index + 1), epsilon);
      final right = _douglasPeucker(points.sublist(index, end + 1), epsilon);
      return [...left.sublist(0, left.length - 1), ...right];
    } else {
      return [points[0], points[end]];
    }
  }

  /// Calculates the shortest distance from a point to a line segment
  double _perpendicularDistance(Offset pt, Offset lineStart, Offset lineEnd) {
    final dx = lineEnd.dx - lineStart.dx;
    final dy = lineEnd.dy - lineStart.dy;
    final mag = sqrt(dx * dx + dy * dy);
    
    if (mag > 0.0) {
      return ((pt.dx - lineStart.dx) * dy - (pt.dy - lineStart.dy) * dx).abs() / mag;
    }
    return (pt - lineStart).distance;
  }


  void _addShapeElement(ShapeData shapeData) {
    final s = state!;
    final page = s.currentPage!;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final newElement = ContentElement.shape(
      id: const Uuid().v4(),
      zIndex: _nextZIndex(page),
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
      zIndex: _nextZIndex(page),
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

  /// Distance from point [p] to the line segment [a]-[b].
  static double _distToSegment(Offset p, Offset a, Offset b) {
    final l2 = (b - a).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy))).distance;
  }

  /// Minimum distance from point [p] to the four edges of [rect].
  static double _distToRectEdges(Offset p, Rect rect) {
    final tl = rect.topLeft, tr = rect.topRight, bl = rect.bottomLeft, br = rect.bottomRight;
    return [
      _distToSegment(p, tl, tr),
      _distToSegment(p, tr, br),
      _distToSegment(p, br, bl),
      _distToSegment(p, bl, tl),
    ].reduce(min);
  }

  /// Convert a shape outline into sampled edge segments (list of point lists).
  /// Each edge is densely sampled so point-by-point erasure works.
  /// Points are in final (rotated) coordinates.
  static List<List<StrokePoint>> _shapeToSampledEdges(ShapeData sh, double stepSize) {
    final rawEdges = <List<Offset>>[];

    switch (sh.shapeType) {
      case 'line':
      case 'arrow':
        rawEdges.add([Offset(sh.x1, sh.y1), Offset(sh.x2, sh.y2)]);
        break;
      case 'rectangle':
        final l = min(sh.x1, sh.x2), r = max(sh.x1, sh.x2);
        final t = min(sh.y1, sh.y2), b = max(sh.y1, sh.y2);
        rawEdges.addAll([
          [Offset(l, t), Offset(r, t)],
          [Offset(r, t), Offset(r, b)],
          [Offset(r, b), Offset(l, b)],
          [Offset(l, b), Offset(l, t)],
        ]);
        break;
      case 'triangle':
        final tLeft = min(sh.x1, sh.x2), tRight = max(sh.x1, sh.x2);
        final top = min(sh.y1, sh.y2), bottom = max(sh.y1, sh.y2);
        final apex = Offset((tLeft + tRight) / 2, top);
        final bl = Offset(tLeft, bottom), br = Offset(tRight, bottom);
        rawEdges.addAll([[apex, bl], [bl, br], [br, apex]]);
        break;
      case 'circle':
        final cx = (sh.x1 + sh.x2) / 2;
        final cy = (sh.y1 + sh.y2) / 2;
        final radius = Offset(sh.x2 - sh.x1, sh.y2 - sh.y1).distance / 2;
        final n = max(36, (2 * pi * radius / stepSize).ceil());
        // Circle as one continuous edge of n+1 points
        final pts = <Offset>[];
        for (int i = 0; i <= n; i++) {
          final a = 2 * pi * i / n;
          pts.add(Offset(cx + radius * cos(a), cy + radius * sin(a)));
        }
        rawEdges.add(pts);
        break;
      default:
        final l = min(sh.x1, sh.x2), r = max(sh.x1, sh.x2);
        final t = min(sh.y1, sh.y2), b = max(sh.y1, sh.y2);
        rawEdges.addAll([
          [Offset(l, t), Offset(r, t)],
          [Offset(r, t), Offset(r, b)],
          [Offset(r, b), Offset(l, b)],
          [Offset(l, b), Offset(l, t)],
        ]);
        break;
    }

    // Rotation transform
    final cx = (sh.x1 + sh.x2) / 2;
    final cy = (sh.y1 + sh.y2) / 2;
    final hasRotation = sh.rotation != 0;
    final cosA = hasRotation ? cos(sh.rotation) : 1.0;
    final sinA = hasRotation ? sin(sh.rotation) : 0.0;

    Offset rotatePoint(Offset p) {
      if (!hasRotation) return p;
      final dx = p.dx - cx;
      final dy = p.dy - cy;
      return Offset(cx + dx * cosA - dy * sinA, cy + dx * sinA + dy * cosA);
    }

    // Sample each edge and apply rotation
    final result = <List<StrokePoint>>[];
    for (final edge in rawEdges) {
      final sampled = <StrokePoint>[];
      // For multi-point edges (circles), sample between consecutive pairs
      for (int i = 0; i < edge.length - 1; i++) {
        final p1 = edge[i];
        final p2 = edge[i + 1];
        final dist = (p2 - p1).distance;
        final count = max(2, (dist / stepSize).ceil() + 1);
        // Don't duplicate the start point for interior segments
        final startIdx = (i == 0) ? 0 : 1;
        for (int j = startIdx; j < count; j++) {
          final t = j / (count - 1);
          final raw = Offset(p1.dx + (p2.dx - p1.dx) * t, p1.dy + (p2.dy - p1.dy) * t);
          final rotated = rotatePoint(raw);
          sampled.add(StrokePoint(x: rotated.dx, y: rotated.dy, pressure: 0.5));
        }
      }
      if (sampled.length >= 2) result.add(sampled);
    }
    return result;
  }

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

      // Check non-stroke elements (text, symbols, shapes).
      // Per-tratto eraser: remove whole element if within bounding box.
      // Standard eraser: only remove if the eraser touches the actual outline/edge.
      element.map(
        stroke: (_) {},
        text: (t) {
          final rect = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height);
          if (isStrokeEraser) {
            if (rect.inflate(eraseRadius).contains(position)) shouldRemoveWhole = true;
          } else {
            // Standard: check proximity to edges of text box
            if (_distToRectEdges(position, rect) < eraseRadius) shouldRemoveWhole = true;
          }
        },
        image: (img) {
          if (img.data.assetPath.startsWith('symbol_')) {
            final rect = Rect.fromLTWH(img.data.x, img.data.y, img.data.width, img.data.height);
            if (isStrokeEraser) {
              if (rect.inflate(eraseRadius).contains(position)) shouldRemoveWhole = true;
            } else {
              // Standard: check proximity to edges of symbol bounding box
              if (_distToRectEdges(position, rect) < eraseRadius) shouldRemoveWhole = true;
            }
          }
        },
        shape: (sh) {
          if (isStrokeEraser) {
            final rect = Rect.fromPoints(
              Offset(sh.data.x1, sh.data.y1),
              Offset(sh.data.x2, sh.data.y2),
            );
            if (rect.inflate(eraseRadius).contains(position)) shouldRemoveWhole = true;
          }
          // Standard eraser is handled below (partial erase, not whole removal)
        },
      );

      if (shouldRemoveWhole) {
        changed = true;
        continue;
      }

      // For strokes: stroke eraser removes entire stroke, standard eraser
      // splits it into segments by erasing only the touched points.
      // For shapes (standard eraser only): decompose outline into sampled
      // points and apply the same splitting logic, so only the touched
      // portion is erased.
      bool handled = false;
      element.map(
        stroke: (stroke) {
          handled = true;
          if (isStrokeEraser) {
            // Remove entire stroke if any point is within radius
            for (final point in stroke.data.points) {
              final dx = point.x - position.dx;
              final dy = point.y - position.dy;
              if (dx * dx + dy * dy < eraseRadius * eraseRadius) {
                changed = true;
                return; // skip adding this element
              }
            }
            newContent.add(element);
          } else {
            // Standard eraser: split stroke, keep segments outside eraser
            final segments = <List<StrokePoint>>[];
            var currentSegment = <StrokePoint>[];

            for (final point in stroke.data.points) {
              final dx = point.x - position.dx;
              final dy = point.y - position.dy;
              if (dx * dx + dy * dy < eraseRadius * eraseRadius) {
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
              return;
            }

            if (segments.length == 1 && segments[0].length == stroke.data.points.length) {
              newContent.add(element);
              return;
            }

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
          }
        },
        text: (_) {},
        image: (_) {},
        shape: (sh) {
          // Standard eraser: decompose shape outline into sampled points,
          // then erase only the touched portion (like stroke splitting).
          // Per-tratto already handled above via shouldRemoveWhole.
          if (!isStrokeEraser) {
            handled = true;
            final sampledEdges = _shapeToSampledEdges(sh.data, eraseRadius * 0.5);
            bool anyErased = false;
            final survivingStrokes = <ContentElement>[];

            for (final edgePoints in sampledEdges) {
              final segments = <List<StrokePoint>>[];
              var currentSeg = <StrokePoint>[];

              for (final point in edgePoints) {
                final dx = point.x - position.dx;
                final dy = point.y - position.dy;
                if (dx * dx + dy * dy < eraseRadius * eraseRadius) {
                  if (currentSeg.length >= 2) segments.add(currentSeg);
                  currentSeg = [];
                  anyErased = true;
                } else {
                  currentSeg.add(point);
                }
              }
              if (currentSeg.length >= 2) segments.add(currentSeg);

              for (final seg in segments) {
                survivingStrokes.add(ContentElement.stroke(
                  id: const Uuid().v4(),
                  zIndex: sh.zIndex,
                  data: StrokeData(
                    points: seg,
                    toolType: 'pen',
                    color: sh.data.strokeColor,
                    baseWidth: sh.data.strokeWidth,
                    isHighlighter: false,
                    opacity: 1.0,
                  ),
                ));
              }
            }

            if (anyErased) {
              changed = true;
              newContent.addAll(survivingStrokes);
            } else {
              // Nothing was erased, keep original shape
              newContent.add(element);
            }
          }
        },
      );

      if (!handled) {
        newContent.add(element);
      }
    }

    if (!changed) return;

    // Only push undo once per eraser gesture
    List<UndoEntry> undoStack;
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
      // Wait, is it clicking inside the lasso to drag?
      if (dragBounds.contains(position)) return;
      applySelectionTransform(); // Bake if clicking outside
      state = state!.copyWith(clearLasso: true, lassoPath: []);
    }
    state = state!.copyWith(lassoPath: [position]);
  }

  void clearLassoPath() {
    if (state == null) return;
    if (state!.lassoSelection != null) applySelectionTransform();
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
      // Skip PDF images from lasso selection — they are only selectable via double-tap
      final isPdfImage = element.mapOrNull(
        image: (img) => img.data.assetPath.contains('.pdf_p'),
      ) ?? false;
      if (isPdfImage) continue;

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
    Rect getRotatedBounds(Rect rect, double rotation) {
      if (rotation == 0.0) return rect;
      final c = rect.center;
      final cosA = cos(rotation);
      final sinA = sin(rotation);
      Offset r(Offset p) {
        final dx = p.dx - c.dx;
        final dy = p.dy - c.dy;
        return Offset(c.dx + dx * cosA - dy * sinA, c.dy + dx * sinA + dy * cosA);
      }
      final pts = [r(rect.topLeft), r(rect.topRight), r(rect.bottomLeft), r(rect.bottomRight)];
      final xs = pts.map((p) => p.dx);
      final ys = pts.map((p) => p.dy);
      return Rect.fromLTRB(xs.reduce(min), ys.reduce(min), xs.reduce(max), ys.reduce(max));
    }

    return element.map(
      stroke: (e) {
        if (e.data.points.isEmpty) return null;
        final xs = e.data.points.map((p) => p.x);
        final ys = e.data.points.map((p) => p.y);
        final halfW = e.data.baseWidth / 2.0;
        return Rect.fromLTRB(xs.reduce(min) - halfW, ys.reduce(min) - halfW, xs.reduce(max) + halfW, ys.reduce(max) + halfW);
      },
      text: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      image: (e) {
        final rect = Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height);
        return getRotatedBounds(rect, e.data.rotation);
      },
      shape: (e) {
        final halfW = e.data.strokeWidth / 2.0;
        final baseRect = Rect.fromPoints(Offset(e.data.x1, e.data.y1), Offset(e.data.x2, e.data.y2)).inflate(halfW);
        return getRotatedBounds(baseRect, e.data.rotation);
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

  /// Mirror the current selection around its horizontal center axis (flip X).
  void flipSelectionHorizontal() => _flipSelection(horizontal: true);

  /// Mirror the current selection around its vertical center axis (flip Y).
  void flipSelectionVertical() => _flipSelection(horizontal: false);

  void _flipSelection({required bool horizontal}) {
    if (state == null || state!.lassoSelection == null) return;
    final s = state!;
    final sel = s.lassoSelection!;
    final page = s.currentPage;
    if (page == null || sel.selectedIds.isEmpty) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    // Bake any pending translate/scale/rotate first so the flip axis is the
    // *visual* center the user sees, not the original bounds center.
    if (sel.rotation != 0.0 || sel.dragOffset != Offset.zero || sel.scale != 1.0) {
      applySelectionTransform();
    }
    final postState = state!;
    final postSel = postState.lassoSelection!;
    final postPage = postState.currentPage!;
    final center = postSel.bounds.center;

    double reflectX(double x) => horizontal ? 2 * center.dx - x : x;
    double reflectY(double y) => horizontal ? y : 2 * center.dy - y;

    final updatedContent = postPage.layers.content.map((element) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!postSel.selectedIds.contains(id)) return element;
      return element.map(
        stroke: (e) => ContentElement.stroke(
          id: e.id, zIndex: e.zIndex,
          data: StrokeData(
            points: e.data.points
                .map((p) => StrokePoint(
                      x: reflectX(p.x),
                      y: reflectY(p.y),
                      pressure: p.pressure,
                      tilt: p.tilt,
                      timestamp: p.timestamp,
                    ))
                .toList(),
            toolType: e.data.toolType, color: e.data.color,
            baseWidth: e.data.baseWidth, isHighlighter: e.data.isHighlighter,
            opacity: e.data.opacity, timestamp: e.data.timestamp,
          ),
        ),
        text: (e) => ContentElement.text(
          id: e.id, zIndex: e.zIndex,
          data: TextData(
            // Reflect top-left by accounting for element size so the box
            // mirrors properly around the axis.
            x: horizontal ? 2 * center.dx - e.data.x - e.data.width : e.data.x,
            y: horizontal ? e.data.y : 2 * center.dy - e.data.y - e.data.height,
            width: e.data.width, height: e.data.height,
            content: e.data.content, fontFamily: e.data.fontFamily,
            fontSize: e.data.fontSize, color: e.data.color,
            bold: e.data.bold, italic: e.data.italic, alignment: e.data.alignment,
          ),
        ),
        image: (e) => ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: horizontal ? 2 * center.dx - e.data.x - e.data.width : e.data.x,
            y: horizontal ? e.data.y : 2 * center.dy - e.data.y - e.data.height,
            width: e.data.width, height: e.data.height,
            assetPath: e.data.assetPath,
            // Mirror rotation so the image visually stays aligned.
            rotation: -e.data.rotation,
            opacity: e.data.opacity,
            locked: e.data.locked,
            comment: e.data.comment,
          ),
        ),
        shape: (e) => ContentElement.shape(
          id: e.id, zIndex: e.zIndex,
          data: ShapeData(
            shapeType: e.data.shapeType,
            x1: reflectX(e.data.x1), y1: reflectY(e.data.y1),
            x2: reflectX(e.data.x2), y2: reflectY(e.data.y2),
            strokeColor: e.data.strokeColor, strokeWidth: e.data.strokeWidth,
            fillColor: e.data.fillColor,
            rotation: -e.data.rotation,
          ),
        ),
      );
    }).toList();

    final updatedPage = PageData(
      pageId: postPage.pageId, pageNumber: postPage.pageNumber,
      width: postPage.width, height: postPage.height,
      layers: RenderingLayers(background: postPage.layers.background, content: updatedContent),
      assetReferences: postPage.assetReferences,
      createdAt: postPage.createdAt, modifiedAt: DateTime.now(),
    );

    final updatedPages = Map<String, PageData>.from(postState.pages);
    updatedPages[fileName] = updatedPage;

    // Recompute selection bounds from mirrored elements.
    Rect? newBounds;
    for (final element in updatedContent) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!postSel.selectedIds.contains(id)) continue;
      final eb = _getElementBounds(element);
      if (eb == null) continue;
      newBounds = newBounds == null ? eb : newBounds.expandToInclude(eb);
    }

    state = postState.copyWith(
      pages: updatedPages,
      undoStack: undoStack,
      redoStack: [],
      isDirty: true,
      lassoSelection: LassoSelection(
        selectedIds: postSel.selectedIds,
        bounds: newBounds ?? postSel.bounds,
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
        // Rotate only the element center around the selection center,
        // then translate the bounding box by the center offset.
        // The internal rotation is incremented to match the visual preview.
        final oldCx = e.data.x + e.data.width / 2;
        final oldCy = e.data.y + e.data.height / 2;
        final rCenter = rotatePoint(oldCx, oldCy);
        final dx = rCenter.dx - oldCx;
        final dy = rCenter.dy - oldCy;
        return ContentElement.image(
          id: e.id, zIndex: e.zIndex,
          data: ImageData(
            x: e.data.x + dx, y: e.data.y + dy,
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
        // Rotate only the element center around the selection center,
        // then translate the bounding box by the center offset.
        final oldCx = (e.data.x1 + e.data.x2) / 2;
        final oldCy = (e.data.y1 + e.data.y2) / 2;
        final rCenter = rotatePoint(oldCx, oldCy);
        final dx = rCenter.dx - oldCx;
        final dy = rCenter.dy - oldCy;
        return ContentElement.shape(
          id: e.id, zIndex: e.zIndex,
          data: ShapeData(
            shapeType: e.data.shapeType,
            x1: e.data.x1 + dx, y1: e.data.y1 + dy,
            x2: e.data.x2 + dx, y2: e.data.y2 + dy,
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
    if (state!.lassoSelection != null) applySelectionTransform();
    state = state!.copyWith(clearLasso: true, lassoPath: [], selectedElementId: null, clearSelectedElement: true);
  }

  /// Change the color of all selected strokes/shapes/text.
  void changeSelectionColor(int newColor) {
    if (state == null || state!.lassoSelection == null) return;
    final s = state!;
    final sel = s.lassoSelection!;
    final page = s.currentPage;
    if (page == null) return;
    final fileName = s.currentPageFileName;
    final undoStack = _pushUndo(s, fileName, page);

    final updatedContent = page.layers.content.map((element) {
      final id = element.map(
        stroke: (e) => e.id, text: (e) => e.id,
        image: (e) => e.id, shape: (e) => e.id,
      );
      if (!sel.selectedIds.contains(id)) return element;
      return element.map(
        stroke: (e) => e.copyWith(data: e.data.copyWith(color: newColor)),
        text: (e) => e.copyWith(data: e.data.copyWith(color: newColor)),
        image: (e) => e, // images don't have a stroke color
        shape: (e) => e.copyWith(data: e.data.copyWith(strokeColor: newColor)),
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

    state = s.copyWith(
      pages: updatedPages, undoStack: undoStack, redoStack: [], isDirty: true,
    );
  }

  // ── Undo / Redo ──

  void undo() {
    if (state == null || state!.undoStack.isEmpty) return;
    final s = state!;
    final entry = s.undoStack.last;
    final currentPage = s.pages[entry.pageFileName];

    final newUndo = List<UndoEntry>.from(s.undoStack)..removeLast();
    final newRedo = [...s.redoStack, if (currentPage != null) UndoEntry(entry.pageFileName, currentPage)];

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[entry.pageFileName] = entry.pageData;

    state = s.copyWith(pages: updatedPages, undoStack: newUndo, redoStack: newRedo, isDirty: true);
  }

  void redo() {
    if (state == null || state!.redoStack.isEmpty) return;
    final s = state!;
    final entry = s.redoStack.last;
    final currentPage = s.pages[entry.pageFileName];

    final newRedo = List<UndoEntry>.from(s.redoStack)..removeLast();
    final newUndo = [...s.undoStack, if (currentPage != null) UndoEntry(entry.pageFileName, currentPage)];

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

  /// Navigate to [index]. By default the user's zoom/pan is preserved so
  /// arrow-button and grid taps don't rip the viewport out from under them.
  /// Pass [resetViewport]=true for gestures where a fresh view is wanted
  /// (e.g. swipe-to-turn-page).
  void goToPage(int index, {bool resetViewport = false}) {
    if (state == null || index < 0 || index >= state!.pageCount) return;
    if (resetViewport) {
      state = state!.copyWith(
        currentPageIndex: index,
        activeStroke: [],
        clearLasso: true,
        lassoPath: [],
        clearSelectedElement: true,
        zoom: 2.0,
        panOffset: _centeredPanOffset(2.0),
      );
    } else {
      state = state!.copyWith(
        currentPageIndex: index,
        activeStroke: [],
        clearLasso: true,
        lassoPath: [],
        clearSelectedElement: true,
      );
    }
  }

  void nextPage({bool resetViewport = false}) {
    if (state == null) return;
    final s = state!;
    final filtered = s.filteredPageIndices;
    final pos = filtered.indexOf(s.currentPageIndex);
    if (pos >= 0 && pos + 1 < filtered.length) {
      goToPage(filtered[pos + 1], resetViewport: resetViewport);
    }
  }

  void prevPage({bool resetViewport = false}) {
    if (state == null) return;
    final s = state!;
    final filtered = s.filteredPageIndices;
    final pos = filtered.indexOf(s.currentPageIndex);
    if (pos > 0) {
      goToPage(filtered[pos - 1], resetViewport: resetViewport);
    }
  }

  void addPage() {
    if (state == null) return;
    final s = state!;
    const uuid = Uuid();
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
      zoom: 2.0,
      panOffset: _centeredPanOffset(2.0),
      isDirty: true,
    );
  }

  /// Insert a new blank page at a specific position (0-based index).
  void insertPageAt(int index) {
    if (state == null) return;
    final s = state!;
    const uuid = Uuid();
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

    final insertIdx = index.clamp(0, s.document.pages.length);

    // Inherit chapter from the page before the insert position
    String? chapterId;
    if (insertIdx > 0) {
      chapterId = s.document.pages[insertIdx - 1].chapterId;
    } else if (s.document.pages.isNotEmpty) {
      chapterId = s.document.pages[0].chapterId;
    }

    final newEntry = PageEntry(
      pageId: pageId, pageNumber: pageNum, fileName: fileName,
      lastModified: now, chapterId: chapterId,
    );

    final pageList = List<PageEntry>.from(s.document.pages)..insert(insertIdx, newEntry);
    final updatedDoc = s.document.copyWith(pages: pageList);
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = newPage;

    state = s.copyWith(
      metadata: s.metadata.copyWith(pageCount: pageNum, modifiedAt: now),
      document: updatedDoc,
      pages: updatedPages,
      currentPageIndex: insertIdx,
      zoom: 2.0,
      panOffset: _centeredPanOffset(2.0),
      isDirty: true,
    );
  }

  /// Move a page to a different chapter.
  void movePageToChapter(int pageIndex, String? chapterId) {
    assignPageToChapter(pageIndex, chapterId);
  }

  void addChapter(String title) {
    if (state == null) return;
    final s = state!;
    final now = DateTime.now();
    final chapterId = const Uuid().v4();
    const uuid = Uuid();

    // Create a new blank page for the chapter instead of reassigning the current page
    final pageId = uuid.v4();
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

    final newEntry = PageEntry(
      pageId: pageId, pageNumber: pageNum, fileName: fileName,
      lastModified: now, chapterId: chapterId,
    );

    final chapter = Chapter(id: chapterId, title: title, pageIds: [pageId]);

    // Insert the new page after current position
    final insertIndex = s.currentPageIndex + 1;
    final pageList = List<PageEntry>.from(s.document.pages)..insert(insertIndex, newEntry);
    final updatedDoc = s.document.copyWith(pages: pageList);

    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[fileName] = newPage;

    state = s.copyWith(
      metadata: s.metadata.copyWith(
        chapters: [...s.metadata.chapters, chapter],
        pageCount: pageNum,
        modifiedAt: now,
      ),
      document: updatedDoc,
      pages: updatedPages,
      currentPageIndex: insertIndex,
      activeChapterId: chapterId,
      zoom: 2.0,
      panOffset: _centeredPanOffset(2.0),
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

  void reorderChapters(int oldIndex, int newIndex) {
    if (state == null) return;
    final s = state!;
    final chapters = List<Chapter>.from(s.metadata.chapters);
    if (oldIndex < 0 || oldIndex >= chapters.length) return;
    if (newIndex < 0 || newIndex >= chapters.length) return;
    final item = chapters.removeAt(oldIndex);
    chapters.insert(newIndex, item);
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
      zIndex: _nextZIndex(page),
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

  List<UndoEntry> _pushUndo(CanvasState s, String fileName, PageData page) {
    final stack = [...s.undoStack, UndoEntry(fileName, page)];
    if (stack.length > 50) stack.removeAt(0);
    return stack;
  }

  int _nextZIndex(PageData page) {
    int maxZ = -1;
    for (final e in page.layers.content) {
      final z = e.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex);
      if (z > maxZ) maxZ = z;
    }
    return maxZ + 1;
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

  Rect _elementBounds(ContentElement element) {
    return element.map(
      stroke: (e) {
        if (e.data.points.isEmpty) return Rect.zero;
        double mnX = e.data.points.first.x, mxX = mnX, mnY = e.data.points.first.y, mxY = mnY;
        for (final p in e.data.points) {
          if (p.x < mnX) mnX = p.x; if (p.x > mxX) mxX = p.x;
          if (p.y < mnY) mnY = p.y; if (p.y > mxY) mxY = p.y;
        }
        return Rect.fromLTRB(mnX, mnY, mxX, mxY);
      },
      text: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      image: (e) => Rect.fromLTWH(e.data.x, e.data.y, e.data.width, e.data.height),
      shape: (e) => Rect.fromPoints(Offset(e.data.x1, e.data.y1), Offset(e.data.x2, e.data.y2)),
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
    if (state!.lassoSelection != null) applySelectionTransform();
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
    // Give it a zIndex higher than all others
    final maxZ = content.fold<int>(0, (m, e) =>
        max(m, e.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex)));
    final updated = element.map(
      stroke: (e) => ContentElement.stroke(id: e.id, zIndex: maxZ + 1, data: e.data),
      text: (e) => ContentElement.text(id: e.id, zIndex: maxZ + 1, data: e.data),
      image: (e) => ContentElement.image(id: e.id, zIndex: maxZ + 1, data: e.data),
      shape: (e) => ContentElement.shape(id: e.id, zIndex: maxZ + 1, data: e.data),
    );
    content.add(updated);

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
    // Give it a zIndex lower than all others
    final minZ = content.fold<int>(999999, (m, e) =>
        min(m, e.map(stroke: (s) => s.zIndex, text: (t) => t.zIndex, image: (i) => i.zIndex, shape: (s) => s.zIndex)));
    final updated = element.map(
      stroke: (e) => ContentElement.stroke(id: e.id, zIndex: minZ - 1, data: e.data),
      text: (e) => ContentElement.text(id: e.id, zIndex: minZ - 1, data: e.data),
      image: (e) => ContentElement.image(id: e.id, zIndex: minZ - 1, data: e.data),
      shape: (e) => ContentElement.shape(id: e.id, zIndex: minZ - 1, data: e.data),
    );
    content.insert(0, updated);

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

  void _updatePageContent(CanvasState s, PageData page, String fileName, List<ContentElement> content, List<UndoEntry> undoStack) {
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
      zIndex: _nextZIndex(page),
      data: ImageData(
        x: position.dx, y: position.dy,
        width: width, height: height,
        assetPath: assetId,
      ),
    );

    final updatedPage = _pageWithNewElement(page, newElement).copyWith(
      assetReferences: [...page.assetReferences, assetId],
    );
    final updatedPages = Map<String, PageData>.from(s.pages);
    updatedPages[pageFileName] = updatedPage;

    // Store raw bytes for persistence and decode for rendering
    final newAssetBytes = Map<String, Uint8List>.from(s.assetBytes);
    newAssetBytes[assetId] = bytes;
    _decodeAndCacheImage(assetId, bytes);
    _markAssetDirty(assetId);

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
    _markAssetDirty(newAssetId);

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

  /// Copy a single element (e.g. an image / PDF preview) to the clipboard.
  void copyElement(String elementId) {
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
    state = state!.copyWith(clipboard: CanvasClipboard(elements: [element], bounds: bounds));
  }

  /// Cut a single element: copy to clipboard, then delete.
  void cutElement(String elementId) {
    copyElement(elementId);
    deleteElement(elementId);
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

    final baseZ = _nextZIndex(page);
    final newElements = <ContentElement>[];
    for (int idx = 0; idx < clip.elements.length; idx++) {
      final element = clip.elements[idx];
      final newId = const Uuid().v4();
      final translated = _translateElement(element, pasteOffset);
      final z = baseZ + idx;
      newElements.add(translated.map(
        stroke: (e) => ContentElement.stroke(id: newId, zIndex: z, data: e.data),
        text: (e) => ContentElement.text(id: newId, zIndex: z, data: e.data),
        image: (e) => ContentElement.image(id: newId, zIndex: z, data: e.data),
        shape: (e) => ContentElement.shape(id: newId, zIndex: z, data: e.data),
      ));
    }

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
    // Enter placement mode — user taps to place the copy
    if (state != null && state!.clipboard != null) {
      state = state!.copyWith(pendingPaste: true, clearLasso: true);
    }
  }

  void duplicateElement(String elementId) {
    if (state == null) return;
    final s = state!;
    final page = s.currentPage;
    if (page == null) return;

    final original = page.layers.content.where((e) {
      final id = e.map(stroke: (e) => e.id, text: (e) => e.id, image: (e) => e.id, shape: (e) => e.id);
      return id == elementId;
    }).firstOrNull;
    if (original == null) return;

    // Copy the element to clipboard and enter placement mode
    final bounds = _elementBounds(original);
    state = s.copyWith(
      clipboard: CanvasClipboard(elements: [original], bounds: bounds),
      pendingPaste: true,
      clearSelectedElement: true,
    );
  }

  void cancelPendingPaste() {
    if (state == null) return;
    state = state!.copyWith(pendingPaste: false);
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
      zIndex: _nextZIndex(page),
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
    _markAssetDirty(assetId);

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
    final color = Color(stroke.color);

    // Highlighter
    if (stroke.isHighlighter) {
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

    // Ballpoint
    if (stroke.toolType == 'ballpoint') {
      final paint = Paint()
        ..color = color.withValues(alpha: stroke.opacity)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final interp = _catmullRomInterpolateSymbol(stroke.points);
      for (int i = 0; i < interp.length - 1; i++) {
        final p0 = interp[i];
        final p1 = interp[i + 1];
        final avgP = (p0.pressure + p1.pressure) / 2;
        paint.strokeWidth = stroke.baseWidth * (0.6 + avgP * 0.4);
        canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
      }
      return;
    }

    // Brush
    if (stroke.toolType == 'brush') {
      final interp = _catmullRomInterpolateSymbol(stroke.points);
      for (int layer = 0; layer < 3; layer++) {
        final alpha = (stroke.opacity * (0.3 - layer * 0.08)).clamp(0.05, 1.0);
        final widthMul = 1.0 + layer * 0.6;
        final paint = Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        for (int i = 0; i < interp.length - 1; i++) {
          final p0 = interp[i];
          final p1 = interp[i + 1];
          final avgP = (p0.pressure + p1.pressure) / 2;
          paint.strokeWidth = stroke.baseWidth * widthMul * (0.2 + avgP * 0.8);
          canvas.drawLine(Offset(p0.x, p0.y), Offset(p1.x, p1.y), paint);
        }
      }
      return;
    }

    // Fountain pen (default)
    final n = stroke.points.length;
    final velocities = List<double>.filled(n, 0.0);
    for (int i = 1; i < n; i++) {
      final dx = stroke.points[i].x - stroke.points[i - 1].x;
      final dy = stroke.points[i].y - stroke.points[i - 1].y;
      velocities[i] = sqrt(dx * dx + dy * dy);
    }
    if (n > 1) velocities[0] = velocities[1];

    final rawWidths = List<double>.filled(n, stroke.baseWidth);
    for (int i = 0; i < n; i++) {
      final velocityFactor = (1.0 - (velocities[i] / 20.0).clamp(0.0, 0.50));
      final pressureFactor = 0.15 + stroke.points[i].pressure * 0.85;
      rawWidths[i] = stroke.baseWidth * pressureFactor * velocityFactor;
    }
    for (int pass = 0; pass < 2; pass++) {
      for (int i = 1; i < n - 1; i++) {
        rawWidths[i] = (rawWidths[i - 1] + rawWidths[i] * 2 + rawWidths[i + 1]) / 4;
      }
    }

    final interp = _catmullRomAdaptiveWithWidthSymbol(stroke.points, rawWidths);
    if (interp.length < 2) return;

    // Render as filled outline polygon for smooth edges.
    final count = interp.length;
    final nxArr = List<double>.filled(count, 0.0);
    final nyArr = List<double>.filled(count, 0.0);
    for (int i = 0; i < count; i++) {
      double dx, dy;
      if (i == 0) {
        dx = interp[1].$1 - interp[0].$1;
        dy = interp[1].$2 - interp[0].$2;
      } else if (i == count - 1) {
        dx = interp[i].$1 - interp[i - 1].$1;
        dy = interp[i].$2 - interp[i - 1].$2;
      } else {
        dx = interp[i + 1].$1 - interp[i - 1].$1;
        dy = interp[i + 1].$2 - interp[i - 1].$2;
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
    final hw0 = (interp[0].$4 * 0.5).clamp(0.2, 999.0);

    // Right edge (forward)
    path.moveTo(
      interp[0].$1 + nxArr[0] * hw0,
      interp[0].$2 + nyArr[0] * hw0,
    );
    for (int i = 1; i < count; i++) {
      final hw = (interp[i].$4 * 0.5).clamp(0.2, 999.0);
      path.lineTo(
        interp[i].$1 + nxArr[i] * hw,
        interp[i].$2 + nyArr[i] * hw,
      );
    }

    // Left edge (backward) — straight connection at the end
    for (int i = count - 1; i >= 0; i--) {
      final hw = (interp[i].$4 * 0.5).clamp(0.2, 999.0);
      path.lineTo(
        interp[i].$1 - nxArr[i] * hw,
        interp[i].$2 - nyArr[i] * hw,
      );
    }
    path.close();

    final fillPaint = Paint()
      ..color = color.withValues(alpha: stroke.opacity)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(path, fillPaint);

    // Round endpoint circles
    canvas.drawCircle(
      Offset(interp.first.$1, interp.first.$2),
      hw0,
      fillPaint,
    );
    final lastHw = (interp.last.$4 * 0.5).clamp(0.2, 999.0);
    canvas.drawCircle(
      Offset(interp.last.$1, interp.last.$2),
      lastHw,
      fillPaint,
    );
  }

  List<StrokePoint> _catmullRomInterpolateSymbol(List<StrokePoint> points) {
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
      final segments = dist < 2 ? 2 : dist < 8 ? 4 : dist < 20 ? 6 : 8;
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

  /// Adaptive Catmull-Rom with width for symbol rasterization.
  /// Returns list of (x, y, pressure, width) tuples.
  List<(double, double, double, double)> _catmullRomAdaptiveWithWidthSymbol(
      List<StrokePoint> points, List<double> widths) {
    if (points.length < 4) {
      return List.generate(points.length, (i) =>
          (points[i].x, points[i].y, points[i].pressure, widths[i]));
    }
    final result = <(double, double, double, double)>[];
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
      final segments = dist < 2 ? 2 : dist < 8 ? 4 : dist < 20 ? 6 : 8;
      for (int j = 0; j < segments; j++) {
        final t = j / segments;
        final t2 = t * t;
        final t3 = t2 * t;
        final x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        final y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);
        final w = w1 + (w2 - w1) * t;
        result.add((x, y, p1.pressure + (p2.pressure - p1.pressure) * t, w));
      }
    }
    result.add((points.last.x, points.last.y, points.last.pressure, widths.last));
    return result;
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
        final radius = Offset(shape.x2 - shape.x1, shape.y2 - shape.y1).distance / 2;
        if (fillPaint != null) canvas.drawCircle(center, radius, fillPaint);
        canvas.drawCircle(center, radius, strokePaint);
        break;
      case 'line':
      case 'arrow':
        canvas.drawLine(Offset(shape.x1, shape.y1), Offset(shape.x2, shape.y2), strokePaint);
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
    // Renumber pages (preserve all fields including chapterId)
    for (int i = 0; i < newPages.length; i++) {
      newPages[i] = newPages[i].copyWith(pageNumber: i + 1);
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

    const uuid = Uuid();
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

    final newEntry = PageEntry(pageId: pageId, pageNumber: pageNum, fileName: fileName, lastModified: now, chapterId: entry.chapterId);

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
    state = state!.copyWith(zoom: 2.0, panOffset: _centeredPanOffset(2.0));
  }

  Future<void> save() async {
    if (state == null || !state!.isDirty) return;
    final locked = await _acquireSyncLock();
    if (!locked || state == null) return;
    bool lockTransferred = false;
    try {
      lockTransferred = await _saveInner();
    } finally {
      if (!lockTransferred) _releaseSyncLock();
    }
  }

  /// Performs local save synchronously, then hands the sync lock to a
  /// background task that uploads to the server.
  ///
  /// Returns `true` if the background task has taken ownership of the
  /// sync lock (caller must NOT release it). Returns `false` if the
  /// caller must release the lock itself (nothing scheduled).
  Future<bool> _saveInner() async {
    if (state == null || !state!.isDirty) return false;
    final s = state!;
    final syncService = _ref.read(syncServiceProvider);
    final fileService = _ref.read(fileServiceProvider);
    if (syncService == null) return false;

    final updatedMeta = s.metadata.copyWith(modifiedAt: DateTime.now());

    // ── Detect which pages actually changed (identity comparison) ──
    final changedPages = <String, PageData>{};

    for (final entry in s.pages.entries) {
      if (!identical(entry.value, _lastSyncedPages[entry.key])) {
        changedPages[entry.key] = entry.value;
      }
    }
    // Also detect new pages (added since last sync)
    for (final key in s.pages.keys) {
      if (!_lastSyncedPages.containsKey(key)) {
        changedPages[key] = s.pages[key]!;
      }
    }

    // Detect changed assets
    final changedAssets = <String, Uint8List>{};
    for (final key in _dirtyAssetKeys) {
      if (s.assetBytes.containsKey(key)) {
        changedAssets[key] = s.assetBytes[key]!;
      }
    }

    // Detect deleted pages (existed in last sync but no longer in current state)
    final deletedPages = <String>[];
    for (final key in _lastSyncedPages.keys) {
      if (!s.pages.containsKey(key)) {
        deletedPages.add(key);
      }
    }

    debugPrint('[Canvas] Dirty: ${changedPages.length} pages, '
        '${changedAssets.length} assets, ${deletedPages.length} deleted');

    // 1. Encode pages on the main thread with a per-page cache (so unchanged
    //    pages skip JSON encoding), then build the ZIP in a background isolate.
    final encodedPages = _encodePagesWithCache(s.pages);
    final package = await compute(_buildPackageInIsolate, _PackageParams(
      metadata: updatedMeta,
      document: s.document,
      encodedPages: encodedPages,
      assets: s.assetBytes.isNotEmpty ? s.assetBytes : null,
      symbolLibraries: s.symbolLibraries.isNotEmpty
          ? s.symbolLibraries.map((l) => l.toJson()).toList()
          : null,
    ));

    debugPrint('[Canvas] Package built off-thread: ${package.length} bytes');

    // 2. Update state IMMEDIATELY so the user sees "saved" — no more waiting.
    if (state != null) {
      final changedDuringSave = !identical(state!.pages, s.pages);
      state = state!.copyWith(
        metadata: updatedMeta,
        isDirty: changedDuringSave,
      );
    }
    _saveLastPosition();

    // 3. Update the snapshot so future diffs are against this save.
    _lastSyncedPages = Map.of(s.pages);
    _dirtyAssetKeys.clear();

    // 4. Start local save + remote sync in parallel. Await only the local
    //    save — the remote sync continues in the background while holding
    //    the sync lock (so pulls wait). This lets `save()` return to the
    //    UI as soon as data is safe on disk.
    final localSaveFuture = _localSave(
      fileService: fileService,
      package: package,
      updatedMeta: updatedMeta,
      remotePath: s.remotePath,
    );

    final remoteSyncFuture = _remoteSync(
      syncService: syncService,
      fileService: fileService,
      updatedMeta: updatedMeta,
      document: s.document,
      dirtyPages: changedPages,
      dirtyAssets: changedAssets.isNotEmpty ? changedAssets : null,
      symbolLibraries: s.symbolLibraries.isNotEmpty
          ? s.symbolLibraries.map((l) => l.toJson()).toList()
          : null,
      deletedPages: deletedPages.isNotEmpty ? deletedPages : null,
    );

    final localOk = await localSaveFuture;
    if (!localOk) {
      // Local failed. Still drain the remote future under the lock so we
      // don't leave an orphan upload running without guards.
      try { await remoteSyncFuture; } catch (_) {}
      return false;
    }

    // Fire-and-forget: refresh thumbnail for the library card. Uses the
    // first page of the document — failures are swallowed (cards fall
    // back to the gradient placeholder).
    () async {
      try {
        final thumbs = _ref.read(thumbnailServiceProvider);
        final firstPageEntry = s.document.pages.isNotEmpty
            ? s.document.pages.first
            : null;
        if (firstPageEntry == null) return;
        final firstPage = s.pages[firstPageEntry.fileName];
        if (firstPage == null) return;
        await thumbs.renderAndCache(
          updatedMeta.id,
          firstPage,
          imageCache: s.imageCache,
        );
      } catch (e) {
        debugPrint('[Canvas] Thumbnail cache failed: $e');
      }
    }();

    // Hand the lock to a background task that waits for the remote sync
    // to finish (or fail), then releases the lock.
    () async {
      try {
        await remoteSyncFuture;
      } catch (e) {
        debugPrint('[Canvas] Remote sync deferred (offline?): $e');
        try {
          await fileService.markNotebookDirty(updatedMeta.id);
        } catch (_) {}
      } finally {
        _releaseSyncLock();
      }
    }();
    return true;
  }

  Future<bool> _localSave({
    required dynamic fileService,
    required Uint8List package,
    required NotebookMetadata updatedMeta,
    required String remotePath,
  }) async {
    try {
      await fileService.saveNotebookFile(updatedMeta.id, package);
      await fileService.upsertNotebookMeta(
        id: updatedMeta.id,
        title: updatedMeta.title,
        remotePath: remotePath,
        localModifiedAt: updatedMeta.modifiedAt,
        syncStatus: 'modified',
        fileSize: package.length,
        coverColor: updatedMeta.coverColor,
        paperType: updatedMeta.paperType,
        pageCount: updatedMeta.pageCount,
        createdAt: updatedMeta.createdAt,
      );
      debugPrint('[Canvas] Saved locally: ${updatedMeta.title}');
      return true;
    } catch (e) {
      debugPrint('[Canvas] Local save failed: $e');
      return false;
    }
  }

  Future<void> _remoteSync({
    required SyncService syncService,
    required dynamic fileService,
    required NotebookMetadata updatedMeta,
    required DocumentStructure document,
    required Map<String, PageData> dirtyPages,
    Map<String, Uint8List>? dirtyAssets,
    List<Map<String, dynamic>>? symbolLibraries,
    List<String>? deletedPages,
  }) async {
    debugPrint('[Canvas] Starting delta sync: ${dirtyPages.length} pages');
    final etag = await syncService.syncDelta(
      notebookId: updatedMeta.id,
      metadata: updatedMeta,
      document: document,
      dirtyPages: dirtyPages,
      dirtyAssets: dirtyAssets,
      symbolLibraries: symbolLibraries,
      deletedPageFileNames: deletedPages,
    );

    _remoteMetaEtag = etag;
    // Snapshot page ETags to avoid re-pulling our own save. Still awaited
    // because it runs under the sync lock on the background path — pulls
    // are gated on this lock, so we don't need to race the UI for it.
    _lastPageEtags = await syncService.getRemotePageEtags(updatedMeta.id);
    await fileService.markNotebookSynced(updatedMeta.id, etag);
    print('[Canvas] Delta synced: ${dirtyPages.length} pages → server');
  }

  // ══════════════════════════════════════════════════════════════
  //  PULL TIMER — receive remote changes from other devices
  // ══════════════════════════════════════════════════════════════

  void _startPullTimer() {
    _pullTimer?.cancel();
    // Immediate pull on notebook open — don't wait first interval
    _pullRemoteChanges();
    _pullTimer = Timer.periodic(AppConfig.deltaPullInterval, (_) {
      _pullRemoteChanges();
    });
  }

  bool _isPulling = false;
  // _isSyncing tracked by _syncLock mutex

  /// Checks if the remote metadata.json ETag has changed, then pulls
  /// only the pages that differ. Falls back to checking the .ncnote ZIP
  /// for devices that don't use delta sync. Merges into the live canvas.
  ///
  /// Now mutex-protected: waits for any in-flight save() to finish first,
  /// and if local pages are dirty, creates per-page conflicts instead of
  /// silently overwriting.
  Future<void> _pullRemoteChanges() async {
    if (_isPulling || state == null) return;
    // Don't pull while user is resolving conflicts or reviewing pending
    // remote changes — avoids overwriting with a fresh pull.
    if (state!.pendingConflicts.isNotEmpty) return;
    if (state!.pendingRemoteChanges != null) return;
    _isPulling = true;

    final locked = await _acquireSyncLock();
    if (!locked) {
      _isPulling = false;
      return;
    }
    try {
      if (state == null) return;
      final s = state!;
      final syncService = _ref.read(syncServiceProvider);
      if (syncService == null) return;

      // Fetch metadata ETag + page ETags in parallel
      final changeState = await syncService.getRemoteChangeState(s.metadata.id);
      if (changeState.metaEtag != null && changeState.metaEtag != _remoteMetaEtag) {
        print('[Canvas] Delta metadata changed, pulling delta...');
        await _pullFromDeltaFast(
          s, syncService, changeState.pageEtags,
        );
        _remoteMetaEtag = changeState.metaEtag;
      }
    } catch (e) {
      print('[Canvas] Pull failed: $e');
    } finally {
      _isPulling = false;
      _releaseSyncLock();
    }
  }

  /// Pull changed pages from the exploded _delta/ folder.
  /// Uses per-page WebDAV ETags to detect which pages actually changed.
  /// Returns true if any pages were merged.
  /// [preloadedPageEtags]: already-fetched page ETags (parallel optimization).
  Future<bool> _pullFromDeltaFast(
    CanvasState s,
    SyncService syncService,
    Map<String, String> preloadedPageEtags,
  ) async {
    return _pullFromDeltaInner(s, syncService, preloadedPageEtags);
  }

  Future<bool> _pullFromDeltaInner(
    CanvasState s,
    SyncService syncService,
    Map<String, String> remotePageEtags,
  ) async {
    print('[Canvas] Remote has ${remotePageEtags.length} pages, local cache has ${_lastPageEtags.length} ETags');

    // Find pages whose WebDAV ETag changed since last pull
    final pagesToPull = <String>[];
    for (final entry in remotePageEtags.entries) {
      if (_lastPageEtags[entry.key] != entry.value) {
        pagesToPull.add(entry.key);
      }
    }

    // Detect pages that were deleted remotely (in our ETag cache but gone
    // from the remote pages/ folder listing).
    final deletedRemotelyByEtag = _lastPageEtags.keys
        .where((k) => !remotePageEtags.containsKey(k))
        .toSet();

    if (pagesToPull.isEmpty && deletedRemotelyByEtag.isEmpty) {
      print('[Canvas] Delta pull: no page ETags changed, no deletions');
      _lastPageEtags = Map.of(remotePageEtags);
      return false;
    }

    print('[Canvas] Delta pull: ${pagesToPull.length} pages changed, '
        '${deletedRemotelyByEtag.length} pages deleted remotely');

    // Download metadata + changed pages in parallel (one round-trip)
    late final ({NotebookMetadata metadata, DocumentStructure document}) remoteMeta;
    final updatedPages = Map<String, PageData>.from(s.pages);
    final updatedAssets = Map<String, Uint8List>.from(s.assetBytes);
    var anyPageChanged = false;

    final metaFuture = syncService.downloadDeltaMeta(s.metadata.id);
    final pagesFuture = Future.wait(
      pagesToPull.map((pageFileName) async {
        try {
          final remotePage = await syncService.downloadDeltaPage(
            s.metadata.id,
            pageFileName,
          );
          return (pageFileName, remotePage, null as Object?);
        } catch (e) {
          return (pageFileName, null as PageData?, e);
        }
      }),
    );
    // Await both in parallel — pages and metadata finish together
    final results = await pagesFuture;
    remoteMeta = await metaFuture;

    for (final (fileName, page, error) in results) {
      if (page != null) {
        updatedPages[fileName] = page;
        anyPageChanged = true;
      } else {
        print('[Canvas] Failed to pull page $fileName: $error');
      }
    }
    if (anyPageChanged) {
      print('[Canvas] Pulled ${results.where((r) => r.$2 != null).length} pages in parallel');
    }

    // Download new assets in parallel
    // Collect asset references from both assetReferences list AND image elements
    final missingAssets = <String>{};
    for (final page in updatedPages.values) {
      for (final ref in page.assetReferences) {
        if (!updatedAssets.containsKey(ref)) {
          missingAssets.add(ref);
        }
      }
      // Also scan image elements directly (assetReferences may be out of date)
      for (final el in page.layers.content) {
        el.map(
          stroke: (_) {},
          text: (_) {},
          shape: (_) {},
          image: (img) {
            final path = img.data.assetPath;
            if (path.isNotEmpty && !updatedAssets.containsKey(path)) {
              missingAssets.add(path);
            }
          },
        );
      }
    }
    if (missingAssets.isNotEmpty) {
      final assetResults = await Future.wait(
        missingAssets.map((ref) async {
          try {
            final data = await syncService.downloadDeltaAsset(s.metadata.id, ref);
            return (ref, data, null as Object?);
          } catch (e) {
            return (ref, null as Uint8List?, e);
          }
        }),
      );
      for (final (ref, data, _) in assetResults) {
        if (data != null) {
          updatedAssets[ref] = data;
          _decodeAndCacheImage(ref, data);
          anyPageChanged = true;
        }
      }
      print('[Canvas] Pulled ${assetResults.where((r) => r.$2 != null).length} assets in parallel');
    }

    // ── Detect remote deletions: pages in local state but gone from
    //    remote pages/ folder ──
    final deletionConflicts = <PageConflict>[];

    if (deletedRemotelyByEtag.isNotEmpty) {
      for (final fileName in deletedRemotelyByEtag) {
        final localPage = s.pages[fileName];
        if (localPage == null) continue;
        // Was this page edited locally since last sync?
        final locallyEdited = _lastSyncedPages[fileName] != null &&
            localPage != _lastSyncedPages[fileName];
        if (locallyEdited) {
          // Conflict: local edit vs remote deletion — let user decide
          final pageIndex = s.document.pages.indexWhere(
              (e) => e.fileName == fileName);
          final pageEntry = pageIndex >= 0
              ? s.document.pages[pageIndex] : null;
          final chapterName = _chapterNameForPage(pageEntry, s.metadata);
          deletionConflicts.add(PageConflict(
            fileName: fileName,
            pageNumber: localPage.pageNumber,
            chapterName: chapterName,
            localPage: localPage,
            remotePage: localPage, // no remote version — show local as both
            localImageCache: Map.of(state!.imageCache),
            remoteImageCache: const {},
          ));
          print('[Canvas] CONFLICT: $fileName edited locally but deleted remotely');
        } else {
          // Safe deletion — auto-remove
          updatedPages.remove(fileName);
          anyPageChanged = true;
          print('[Canvas] Auto-removing page deleted remotely: $fileName');
        }
      }
    }

    if ((anyPageChanged || deletionConflicts.isNotEmpty) && state != null) {
      // ── Detect conflicts: pages changed both locally AND remotely ──
      final conflicts = <PageConflict>[...deletionConflicts];
      final safePages = <String>{}; // non-conflicting remote pages
      for (final fileName in pagesToPull) {
        final remotePage = updatedPages[fileName];
        final localPage = s.pages[fileName];
        if (remotePage == null) continue;

        // Skip pages where local and remote have identical content —
        // no conflict and no change to report.
        if (localPage != null && localPage == remotePage) {
          continue;
        }

        // Conflict: local page was edited since last sync AND remote changed.
        // Use deep equality (==) instead of identical() — object identity
        // breaks after state rebuilds even when content hasn't changed.
        final locallyEdited = localPage != null &&
            _lastSyncedPages[fileName] != null &&
            localPage != _lastSyncedPages[fileName];
        if (locallyEdited) {
          final pageIndex = remoteMeta.document.pages.indexWhere(
              (e) => e.fileName == fileName);
          final pageEntry = pageIndex >= 0
              ? remoteMeta.document.pages[pageIndex]
              : null;
          final chapterName = _chapterNameForPage(pageEntry, remoteMeta.metadata);
          conflicts.add(PageConflict(
            fileName: fileName,
            pageNumber: remotePage.pageNumber,
            chapterName: chapterName,
            localPage: localPage,
            remotePage: remotePage,
            localImageCache: Map.of(state!.imageCache),
            remoteImageCache: Map.of(state!.imageCache),
          ));
          print('[Canvas] CONFLICT on $fileName — local + remote edits');
        } else {
          safePages.add(fileName);
        }
      }

      // ── Build per-page change details for non-conflicting pages ──
      // Skip pages whose content is identical to local (same ETag ≠ same
      // content, but downloading gave us the actual data to compare).
      final details = <PageChangeDetail>[];
      var newCount = 0;
      var modCount = 0;
      for (final fileName in safePages) {
        final remotePage = updatedPages[fileName];
        final localPage = s.pages[fileName];
        if (remotePage == null) continue;
        final isNew = localPage == null;
        // Content-equality check: if the downloaded page has the same
        // data as local, don't report it as modified.
        if (!isNew && localPage == remotePage) {
          // Silently accept the identical page (keeps updatedPages in sync)
          continue;
        }
        if (isNew) {
          newCount++;
        } else {
          modCount++;
        }
        final pageIndex = remoteMeta.document.pages.indexWhere((e) => e.fileName == fileName);
        final pageEntry = pageIndex >= 0 ? remoteMeta.document.pages[pageIndex] : null;
        final chapterName = _chapterNameForPage(pageEntry, remoteMeta.metadata);
        final localCounts = _elementCounts(localPage);
        final remoteCounts = _elementCounts(remotePage);
        details.add(PageChangeDetail(
          fileName: fileName,
          pageNumber: remotePage.pageNumber,
          pageIndex: pageIndex >= 0 ? pageIndex : 0,
          chapterName: chapterName,
          changeType: isNew ? PageChangeType.added : PageChangeType.modified,
          localStrokeCount: localCounts.$1, remoteStrokeCount: remoteCounts.$1,
          localImageCount: localCounts.$2, remoteImageCount: remoteCounts.$2,
          localShapeCount: localCounts.$3, remoteShapeCount: remoteCounts.$3,
          localTextCount: localCounts.$4, remoteTextCount: remoteCounts.$4,
        ));
      }

      // Count safe deletions (auto-removed, not conflicting)
      final safeDeleteCount = deletedRemotelyByEtag.length - deletionConflicts.length;

      // Show conflicts if any, plus non-conflicting changes banner
      if (conflicts.isNotEmpty || details.isNotEmpty || safeDeleteCount > 0) {
        final pending = (details.isNotEmpty || safeDeleteCount > 0)
            ? PendingRemoteChanges(
                metadata: remoteMeta.metadata,
                document: remoteMeta.document,
                pages: updatedPages,
                assets: updatedAssets,
                changedPages: details,
                newPageCount: newCount,
                modifiedPageCount: modCount,
                deletedPageCount: safeDeleteCount,
                newAssetCount: missingAssets.length,
              )
            : null;

        // Auto-accept all non-conflicting changes silently.
        // Only show UI when there are true per-page conflicts
        // (both local and remote edited the same page).
        if (conflicts.isEmpty && pending != null) {
          print('[Canvas] Auto-accepting ${pending.totalChanges} remote changes '
              '($newCount new, $modCount modified)');
          state = state!.copyWith(
            pendingRemoteChanges: pending,
            clearPendingConflicts: true,
          );
          acceptRemoteChanges();
        } else {
          state = state!.copyWith(
            pendingRemoteChanges: pending,
            pendingConflicts: conflicts.isNotEmpty ? conflicts : null,
            clearPendingRemoteChanges: pending == null,
            clearPendingConflicts: conflicts.isEmpty,
          );
          print('[Canvas] Pull result: ${conflicts.length} conflicts, '
              '$modCount safe merges, $newCount new pages');
        }
      }
    }
    _lastPageEtags = Map.of(remotePageEtags);
    return anyPageChanged;
  }

  // ══════════════════════════════════════════════════════════════
  //  ACCEPT / DISMISS REMOTE CHANGES
  // ══════════════════════════════════════════════════════════════

  /// User accepted the incoming remote changes — apply them to the canvas.
  void acceptRemoteChanges() {
    final s = state;
    final pending = s?.pendingRemoteChanges;
    if (s == null || pending == null) return;

    _lastSyncedPages = Map.of(pending.pages);
    state = s.copyWith(
      metadata: pending.metadata,
      document: pending.document,
      pages: pending.pages,
      assetBytes: pending.assets,
      clearPendingRemoteChanges: true,
    );
    print('[Canvas] User accepted remote changes');

    // Persist the merged state locally
    _savePulledChangesLocally(
      pending.metadata, pending.document,
      pending.pages, pending.assets,
    );

  }

  /// User dismissed the incoming remote changes — keep local state.
  /// The changes are discarded; they won't re-appear until the remote
  /// side is modified again (ETags already updated).
  void dismissRemoteChanges() {
    if (state == null) return;
    state = state!.copyWith(clearPendingRemoteChanges: true);
    print('[Canvas] User dismissed remote changes');
  }

  /// User resolved per-page conflicts via visual diff screen.
  /// [resolutions]: fileName → true=keep local, false=accept remote.
  void resolveConflicts(Map<String, bool> resolutions) {
    if (state == null || state!.pendingConflicts.isEmpty) return;
    final s = state!;
    final updatedPages = Map<String, PageData>.from(s.pages);
    var anyRemoteAccepted = false;

    for (final conflict in s.pendingConflicts) {
      final keepLocal = resolutions[conflict.fileName] ?? true;
      if (!keepLocal) {
        updatedPages[conflict.fileName] = conflict.remotePage;
        anyRemoteAccepted = true;
        print('[Canvas] Conflict resolved → REMOTE: ${conflict.fileName}');
      } else {
        print('[Canvas] Conflict resolved → LOCAL: ${conflict.fileName}');
      }
    }

    _lastSyncedPages = Map.of(updatedPages);
    state = s.copyWith(
      pages: updatedPages,
      isDirty: anyRemoteAccepted || s.isDirty,
      clearPendingConflicts: true,
    );

    // Save merged result locally + trigger sync
    if (anyRemoteAccepted) {
      _triggerSaveAfterConflictResolution();
    }
  }

  /// Keep all local versions, discard conflicts.
  void dismissConflicts() {
    if (state == null) return;
    // Update baseline so the next pull doesn't re-detect the same edits.
    _lastSyncedPages = Map.of(state!.pages);
    state = state!.copyWith(clearPendingConflicts: true);
    print('[Canvas] User dismissed all conflicts (kept local)');
  }

  /// After conflict resolution, save merged state.
  Future<void> _triggerSaveAfterConflictResolution() async {
    if (state == null) return;
    // Mark dirty so save() picks it up
    state = state!.copyWith(isDirty: true);
    await save();
  }

  /// Accept remote changes and navigate to a specific page.
  void acceptAndGoToPage(int pageIndex) {
    acceptRemoteChanges();
    if (state != null && pageIndex >= 0 && pageIndex < state!.document.pages.length) {
      goToPage(pageIndex);
    }
  }

  /// Resolve chapter name for a page entry.
  static String? _chapterNameForPage(PageEntry? pageEntry, NotebookMetadata meta) {
    if (pageEntry == null || pageEntry.chapterId == null) return null;
    final idx = meta.chapters.indexWhere((c) => c.id == pageEntry.chapterId);
    return idx >= 0 ? meta.chapters[idx].title : null;
  }

  /// Count elements by type in a page: (strokes, images, shapes, texts).
  static (int, int, int, int) _elementCounts(PageData? page) {
    if (page == null) return (0, 0, 0, 0);
    var strokes = 0, images = 0, shapes = 0, texts = 0;
    for (final el in page.layers.content) {
      el.map(
        stroke: (_) => strokes++,
        image: (_) => images++,
        shape: (_) => shapes++,
        text: (_) => texts++,
      );
    }
    return (strokes, images, shapes, texts);
  }

  /// Track an asset as dirty when added/modified (e.g. image paste/add).
  void _markAssetDirty(String assetKey) {
    _dirtyAssetKeys.add(assetKey);
  }

  /// Build a ZIP from the pulled state and save it locally so changes
  /// survive close/reopen without re-downloading.
  Future<void> _savePulledChangesLocally(
    NotebookMetadata metadata,
    DocumentStructure document,
    Map<String, PageData> pages,
    Map<String, Uint8List> assets,
  ) async {
    try {
      final fileService = _ref.read(fileServiceProvider);
      final symbolLibs = state?.symbolLibraries
          .map((l) => l.toJson())
          .toList();
      // Pulled pages are all new to us, so the cache will miss for each of
      // them and re-encode. This is fine — happens once after a remote pull.
      final encodedPages = _encodePagesWithCache(pages);
      final package = await compute(_buildPackageInIsolate, _PackageParams(
        metadata: metadata,
        document: document,
        encodedPages: encodedPages,
        assets: assets.isNotEmpty ? assets : null,
        symbolLibraries: symbolLibs,
      ));
      await fileService.saveNotebookFile(metadata.id, package);
      // Also update DB metadata so the library screen reflects the pulled
      // title, page count, cover color, etc. without a full re-download.
      await fileService.upsertNotebookMeta(
        id: metadata.id,
        title: metadata.title,
        remotePath: state?.remotePath ?? '',
        localModifiedAt: metadata.modifiedAt,
        syncStatus: 'synced',
        fileSize: package.length,
        coverColor: metadata.coverColor,
        paperType: metadata.paperType,
        pageCount: metadata.pageCount,
        createdAt: metadata.createdAt,
      );
      print('[Canvas] Saved pulled changes locally (${package.length} bytes)');
    } catch (e) {
      print('[Canvas] Failed to save pulled changes locally: $e');
    }
  }

  /// Encodes every page in [pages] to JSON bytes, reusing cached encodings for
  /// pages whose [PageData] instance hasn't changed since the last save.
  ///
  /// Returns a fresh Map safe to ship to a background isolate. Stale cache
  /// entries (for pages that were deleted) are evicted.
  Map<String, Uint8List> _encodePagesWithCache(Map<String, PageData> pages) {
    final result = <String, Uint8List>{};
    final seen = <String>{};
    for (final entry in pages.entries) {
      seen.add(entry.key);
      final cached = _pageJsonCache[entry.key];
      if (cached != null && identical(cached.page, entry.value)) {
        result[entry.key] = cached.bytes;
        continue;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(entry.value.toJson())));
      _pageJsonCache[entry.key] = _CachedPageJson(entry.value, bytes);
      result[entry.key] = bytes;
    }
    // Evict deleted pages from the cache.
    _pageJsonCache.removeWhere((k, _) => !seen.contains(k));
    return result;
  }
}

/// Parameters for the isolate packaging function.
class _PackageParams {
  final NotebookMetadata metadata;
  final DocumentStructure document;
  /// Pre-encoded page JSON bytes keyed by page file name. Encoding is done on
  /// the main thread so unchanged pages can skip re-encoding via a cache in
  /// [CanvasNotifier]. The isolate only ZIPs these bytes.
  final Map<String, Uint8List> encodedPages;
  final Map<String, Uint8List>? assets;
  final List<Map<String, dynamic>>? symbolLibraries;

  _PackageParams({
    required this.metadata,
    required this.document,
    required this.encodedPages,
    this.assets,
    this.symbolLibraries,
  });
}

/// Tiny record tying cached encoded bytes to the exact [PageData] instance
/// they were produced from. Identity check (`identical`) is enough because
/// [PageData] is a freezed/immutable model.
class _CachedPageJson {
  final PageData page;
  final Uint8List bytes;
  const _CachedPageJson(this.page, this.bytes);
}

/// Top-level function run inside [Isolate.run] via [compute].
/// Builds + validates the .ncnote ZIP package off the main thread.
Uint8List _buildPackageInIsolate(_PackageParams p) {
  // Create a throwaway SyncService-less package builder (static-ish logic).
  final archive = Archive();

  // IMPORTANT: Use utf8.encode() first, then .length for the byte count.
  // String.length returns UTF-16 code units, which differs from UTF-8 byte
  // length for non-ASCII characters (e.g. accented Italian letters).
  final metaBytes = utf8.encode(jsonEncode(p.metadata.toJson()));
  archive.addFile(ArchiveFile(AppConfig.metadataFile, metaBytes.length, metaBytes));

  final docBytes = utf8.encode(jsonEncode(p.document.toJson()));
  archive.addFile(ArchiveFile(AppConfig.documentFile, docBytes.length, docBytes));

  for (final entry in p.encodedPages.entries) {
    archive.addFile(ArchiveFile(
      '${AppConfig.pagesDir}/${entry.key}',
      entry.value.length,
      entry.value,
    ));
  }

  if (p.assets != null) {
    for (final entry in p.assets!.entries) {
      archive.addFile(ArchiveFile(
        '${AppConfig.assetsDir}/${entry.key}',
        entry.value.length,
        entry.value,
      ));
    }
  }

  if (p.symbolLibraries != null && p.symbolLibraries!.isNotEmpty) {
    final symbolsBytes = utf8.encode(jsonEncode(p.symbolLibraries));
    archive.addFile(ArchiveFile('symbols.json', symbolsBytes.length, symbolsBytes));
  }

  final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

  // Validate the produced archive
  SyncService.validateNcnoteArchive(bytes, context: 'isolate-build ${p.metadata.title}');

  return bytes;
}
