import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart' as pw_pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/auth_provider.dart' show webdavServiceProvider;
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/cross_notebook_clipboard_provider.dart';
import 'package:handwriter/core/providers/pending_import_provider.dart';
import 'package:handwriter/core/providers/preset_colors_provider.dart';
import 'package:handwriter/core/services/sync_service.dart' as sync_svc;
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/features/canvas/presentation/image_handle_overlay.dart';
import 'package:handwriter/features/canvas/presentation/remote_changes_banner.dart';
import 'package:handwriter/features/canvas/presentation/conflict_resolution_screen.dart';
import 'package:handwriter/features/canvas/presentation/symbol_library_panel.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:handwriter/core/services/crash_logger.dart';
import 'package:share_plus/share_plus.dart';
import 'package:handwriter/features/canvas/presentation/canvas_painter_notifiers.dart';
import 'package:handwriter/features/canvas/presentation/canvas_crop_dialog.dart';
import 'package:handwriter/features/canvas/presentation/page_manager_sheet.dart';
import 'package:handwriter/ui/editor/hw_editor_chrome.dart';
import 'package:handwriter/ui/primitives/sync_badge.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';

enum _ExportScope { currentPage, currentChapter, entireNotebook }

/// Full export selection — scope + scope-specific options.
class _ExportSelection {
  final _ExportScope scope;
  // currentChapter only: 1-based inclusive range within the chapter's pages
  final int? rangeStart;
  final int? rangeEnd;
  // entireNotebook only: insert a divider page before each chapter
  final bool chapterSeparators;

  const _ExportSelection({
    required this.scope,
    this.rangeStart,
    this.rangeEnd,
    this.chapterSeparators = false,
  });
}

class CanvasScreen extends ConsumerStatefulWidget {
  const CanvasScreen({super.key});

  @override
  ConsumerState<CanvasScreen> createState() => _CanvasScreenState();
}

class _CanvasScreenState extends ConsumerState<CanvasScreen>
    with WidgetsBindingObserver {
  bool _isSaving = false;
  Future<void>? _saveInFlight;
  bool _closing = false;
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

  // ── New chrome state (warm-paper redesign) ─────────────────────
  bool _popupOpen = false;
  final DockPosition _dockPosition = DockPosition.floating;

  // Long-press context menu for touch
  Timer? _longPressTimer;
  Offset _longPressGlobalPos = Offset.zero;
  bool _longPressFired = false;

  // Track last stroke activity to suppress long-press menu while drawing
  DateTime _lastStrokeActivity = DateTime(0);

  // Track whether the stylus is physically touching the screen right now
  bool _stylusDown = false;

  // ── Stroke break debug ──
  // Records when the previous stroke finalized (commit / end / cancel).
  // On next stylus DOWN, gap < 200 ms is flagged as a likely break event
  // so the iPad-side log can pinpoint who is tearing strokes mid-pen-down.
  // Helper [_strokeDbg] writes a tagged line to CrashLogger; only DOWN /
  // UP / CANCEL are logged (not MOVE) to keep the log readable.
  DateTime? _strokeEndedAt;
  String _lastStrokeEndReason = 'never';

  // ── Deferred stylus commit (iPad spurious Up→Down protection) ──
  // On stylus PointerUp we hold the points for [_deferStylusMs] ms instead
  // of committing immediately. If a fresh stylus PointerDown arrives in
  // that window close in space (<= [_deferStylusPx] screen px) and time,
  // we resume the same stroke — preventing the visible mid-letter break
  // caused by Apple Pencil sample dropouts / iOS pointer rebatching.
  //
  // Tuning rationale:
  //   * Hardware spurious Up→Down has dist ≈ 0–3 logical px (the pen does
  //     not move during a sample dropout) and gap ≈ a few ms.
  //   * A deliberate new stroke (lift the pen, move, set down) takes the
  //     user 60+ ms even at sketch speed and lands a few px away once the
  //     pen has actually moved.
  //   * The previous 80 ms / 10 px window was generous enough to swallow
  //     short fast taps as "continuation": the new stroke would graft
  //     onto the tail of the previous one and the user saw a phantom
  //     line stretching from the old end-point to where they actually
  //     wrote. Tightened to 50 ms / 4 px — still well above any real
  //     hardware glitch but no longer captures intentional re-strokes.
  static const int _deferStylusMs = 50;
  static const double _deferStylusPx = 4.0;
  Timer? _deferredCommitTimer;
  List<StrokePoint>? _deferredCommitPoints;
  DateTime? _deferredCommitAt;
  Offset? _deferredCommitLastScreenPos;
  /// True for the very next pointer-move after a "continuation" decision —
  /// lets us double-check that the new pointer position is actually close
  /// to the tail of the kept-alive stroke. If the user really started a
  /// fresh stroke that just happened to land within the defer window, the
  /// first move will be far away from the kept tail; in that case we
  /// commit the old stroke and start a new one. Without this guard, the
  /// new mark would graft onto the previous stroke, producing the
  /// "phantom line stretching from the old end-point" bug.
  bool _justContinuedFromDefer = false;

  // [StrokeDbg] logging is gated by [CrashLogger.verboseEnabled] (default
  // false). Set that flag to true to re-enable [Pull], [Mem], [StrokeDbg]
  // and [Retry] tags all at once when investigating an issue.
  void _strokeDbg(String msg) {
    CrashLogger.append('[StrokeDbg] $msg');
  }

  void _markStrokeEnded(String reason) {
    _strokeEndedAt = DateTime.now();
    _lastStrokeEndReason = reason;
  }

  /// Flush a deferred stylus commit immediately (timer fired, or another
  /// code path needs the stroke to be persisted right now). Commits to
  /// provider state THEN clears the live notifier so the rendered stroke
  /// transitions seamlessly from "live (notifier)" to "committed (state
  /// strokes)" inside the same frame — no flicker.
  void _flushDeferredCommit() {
    final pts = _deferredCommitPoints;
    if (pts == null) return;
    _deferredCommitPoints = null;
    _deferredCommitAt = null;
    _deferredCommitLastScreenPos = null;
    _deferredCommitTimer?.cancel();
    _deferredCommitTimer = null;
    // Clear the live notifier BEFORE the commit so the painter, which
    // pulls from the notifier when it has points, doesn't keep drawing
    // the old stroke as "live" alongside the freshly-committed one.
    // Forgetting this clear was the cause of the "phantom segment from
    // a previous stroke when I start drawing again" bug — if the next
    // pointer event arrived as a MOVE rather than a fresh DOWN (iPad
    // sometimes resumes from a hovering pen this way), the move would
    // append to the still-active notifier and the user saw a line from
    // the old end-point stretching to where they really wrote.
    _activeStrokeNotifier.clear();
    _justContinuedFromDefer = false;
    ref.read(canvasProvider.notifier).commitAndEndStroke(pts);
    _activeStrokeNotifier.clear();
    _markStrokeEnded('pointerUp.commit');
  }

  // Double-tap detection for element selection
  DateTime _lastTapTime = DateTime(0);
  Offset _lastTapPos = Offset.zero;

  // Cached canvas size for pointer-up page-drag commit
  Size _lastCanvasSize = Size.zero;

  // ── High-performance active stroke notifier ──
  final _activeStrokeNotifier = ActiveStrokeNotifier();
  // ── High-performance lasso path notifier (avoids Riverpod rebuild per point) ──
  final _lassoPathNotifier = LassoPathNotifier();
  // ── Laser pointer trail (fades out, never committed) ──
  final _laserStrokeNotifier = LaserStrokeNotifier();
  // ── Live transform of an existing lasso selection (drag/rotate/scale) ──
  // Updated on every pointer-move so the painter repaints without firing
  // a Riverpod state update; committed back to Riverpod once on pan-end.
  final _lassoTransformNotifier = LassoTransformNotifier();
  // ── Live transform of a single non-lasso element (image / shape / text
  // selected via double-tap). Same purpose as the lasso notifier — bypass
  // Riverpod during the gesture, commit once on pan-end.
  final _elementTransformNotifier = ElementTransformNotifier();
  // Cached Listenable.merge for the CustomPaint.repaintNotifier — avoids
  // rebuilding the composite on every parent rebuild (each new merge re-
  // subscribes to both underlying notifiers, which is non-trivial work on
  // the hot draw path).
  late final Listenable _repaintNotifier = Listenable.merge([
    _activeStrokeNotifier,
    _lassoPathNotifier,
    _lassoTransformNotifier,
    _elementTransformNotifier,
    _laserStrokeNotifier,
  ]);

  // ── Auto-save (debounced) ──
  //
  // We save after a short idle window (no new edits) so rapid strokes batch
  // into a single disk write. A second "max delay" timer guarantees we never
  // defer more than _autoSaveMaxDelay even if the user keeps drawing.
  //
  // Idle window tuned down from 4 s to 1.2 s so small-stroke edits reach
  // the server in ~2-3 s end-to-end on Tailscale instead of the old 6-8 s.
  // The hot-path save() is now non-blocking (remote delta fires first,
  // local ZIP rebuild runs in the background), so firing it more often
  // no longer pauses the UI.
  Timer? _autoSaveDebounce;
  Timer? _autoSaveMaxWait;
  bool _wasDirty = false;
  static const _autoSaveIdle = Duration(milliseconds: 1200);
  static const _autoSaveMaxDelay = Duration(seconds: 15);

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
    WidgetsBinding.instance.addObserver(this);
    _startAutoSave();
    _watchForPendingImport();
  }

  /// Waits for the notebook to finish loading, then runs any pending share
  /// import (files dropped in via the Android/iOS share sheet). Fires once.
  ///
  /// Listens to a narrow select (`s != null`) instead of the full state so
  /// the callback doesn't run 60×/s during pan/zoom.
  void _watchForPendingImport() {
    bool handled = false;
    ref.listenManual<bool>(
      canvasProvider.select((s) => s != null),
      (_, hasState) {
        if (handled) return;
        if (!hasState) return;
        final pending = ref.read(pendingImportProvider);
        if (pending == null) return;
        handled = true;
        ref.read(pendingImportProvider.notifier).state = null;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _runPendingImport(pending));
      },
    );
  }

  Future<void> _runPendingImport(PendingImport pending) async {
    if (!mounted) return;
    final notifier = ref.read(canvasProvider.notifier);
    if (pending.newChapterTitle != null && pending.newChapterTitle!.isNotEmpty) {
      notifier.addChapter(pending.newChapterTitle!);
    } else if (pending.targetChapterId != null) {
      notifier.setActiveChapter(pending.targetChapterId);
    }
    for (final path in pending.filePaths) {
      if (!mounted) break;
      try {
        final file = io.File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final name = path.split(io.Platform.pathSeparator).last;
        final state = ref.read(canvasProvider);
        final pg = state?.currentPage;
        final center = pg == null
            ? const Offset(100, 100)
            : Offset(pg.width / 2, pg.height / 2);
        if (name.toLowerCase().endsWith('.pdf')) {
          await _insertPdf(bytes, name, center);
        } else {
          _insertImage(bytes, name, center);
          // For multiple shared images, give each its own page.
          if (pending.filePaths.length > 1 &&
              path != pending.filePaths.last) {
            notifier.addPage();
          }
        }
      } catch (e) {
        debugPrint('[Canvas] Pending import failed for $path: $e');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Flush any pending deferred stylus commit before tearing down so a
    // partial stroke isn't lost on screen close. Cancel the timer first
    // since dispose is the terminal callsite. Notifier clear happens in
    // the dispose() call below regardless, so we just need to push the
    // points into provider state.
    _deferredCommitTimer?.cancel();
    _deferredCommitTimer = null;
    if (_deferredCommitPoints != null) {
      try {
        ref.read(canvasProvider.notifier).commitAndEndStroke(_deferredCommitPoints!);
      } catch (_) {
        // Provider may already be disposed; swallow.
      }
      _deferredCommitPoints = null;
      _deferredCommitAt = null;
      _deferredCommitLastScreenPos = null;
    }
    _activeStrokeNotifier.dispose();
    _lassoPathNotifier.dispose();
    _lassoTransformNotifier.dispose();
    _elementTransformNotifier.dispose();
    _laserStrokeNotifier.dispose();
    _autoSaveDebounce?.cancel();
    _autoSaveMaxWait?.cancel();
    _holdRecognizeTimer?.cancel();
    _longPressTimer?.cancel();
    _focusNode.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _startAutoSave() {
    // Listen to canvas state: every transition into `isDirty=true` bumps the
    // debounce timer. This saves after [_autoSaveIdle] of inactivity, with a
    // cap of [_autoSaveMaxDelay] per burst.
    //
    // Subscribes to `isDirty` only — not the whole state — so the callback
    // doesn't get invoked 60×/s during pan/zoom (each panOffset state.copyWith
    // would otherwise fire the listener even though dirty was unchanged,
    // costing real CPU on a 215-page notebook just to cancel + recreate
    // Timers that nobody needed touched).
    ref.listenManual<bool>(
      canvasProvider.select((s) => s?.isDirty ?? false),
      (_, isDirty) {
        if (!isDirty) {
          // Clean state; cancel any pending save.
          _wasDirty = false;
          _autoSaveDebounce?.cancel();
          _autoSaveMaxWait?.cancel();
          return;
        }
        // Dirty: restart idle timer, start max-wait on first dirty of burst.
        _autoSaveDebounce?.cancel();
        _autoSaveDebounce = Timer(_autoSaveIdle, _triggerAutoSave);
        if (!_wasDirty) {
          _autoSaveMaxWait?.cancel();
          _autoSaveMaxWait = Timer(_autoSaveMaxDelay, _triggerAutoSave);
        }
        _wasDirty = true;
      },
    );
  }

  void _triggerAutoSave() {
    final state = ref.read(canvasProvider);
    if (state == null || !state.isDirty || _isSaving) return;
    // Defer the save while a stroke is mid-flight OR an eraser drag is
    // in progress. _saveInner does enough sync work (state.copyWith,
    // setState in the canvas chrome) plus a 50 MB ZIP rebuild via
    // compute() to drop many frames — a >1.2 s eraser drag would
    // otherwise stall mid-gesture. eraserCursorPos is non-null only
    // between pointer-down and pointer-up on an eraser tool, so it's
    // the right signal. Save fires the moment the pen/eraser lifts,
    // when the next dirty transition re-arms the debounce.
    if (_activeStrokeNotifier.isActive || state.eraserCursorPos != null) {
      _autoSaveDebounce?.cancel();
      _autoSaveDebounce = Timer(const Duration(milliseconds: 600), _triggerAutoSave);
      return;
    }
    _save(silent: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` fires VERY frequently on desktop (every window focus change,
    // dock click, alt-tab). Treating it like a pause killed the pull timer
    // for the entire duration the user was looking at another window and
    // never restarted it — strokes from the iPad became invisible on PC
    // until the user re-opened the notebook. Only treat `paused` and
    // `detached` as real teardown triggers; flush nothing on `inactive`.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // App is being backgrounded / screen locked / process about to die.
      // Skip if we're already tearing down (via _onWillPop → closeNotebook)
      // to avoid two concurrent save paths fighting over the .ncnote.
      if (_closing) return;

      // Flush any in-flight pull-save / remote-sync so pages downloaded
      // by the pull timer actually land on disk before the OS kills us.
      // Without this, closing the PC/iPad app right after a pull would
      // lose all the downloaded pages — next launch would re-run the
      // same pull from scratch ("chiudo riapro e la sync ricomincia").
      unawaited(ref.read(canvasProvider.notifier).flushPendingWork());

      final canvas = ref.read(canvasProvider);
      if (canvas != null && canvas.isDirty && !_isSaving) {
        _save(silent: true);
      }

      // Detached = Flutter engine is shutting down. Release GPU textures
      // NOW so the Linux desktop build doesn't segfault at exit while
      // native ui.Image handles are still in the imageCache.
      if (state == AppLifecycleState.detached) {
        try {
          ref.read(canvasProvider.notifier).releaseImageCache();
        } catch (_) {}
      }
      return;
    }

    // Resume: if we're back in the foreground and a notebook is open but
    // the pull timer got killed by a previous teardown, restart it so
    // cross-device updates arrive promptly again. Also wake up the
    // WebDAV client — iOS backgrounds stranded NSURLSession handles after
    // a screen lock or app-switch and subsequent calls return null even
    // though the network itself is healthy.
    if (state == AppLifecycleState.resumed) {
      if (_closing) return;
      try {
        ref.read(webdavServiceProvider)?.wakeUp();
      } catch (_) {}
      final canvas = ref.read(canvasProvider);
      if (canvas != null) {
        ref.read(canvasProvider.notifier).restartPullTimerIfNeeded();
      }
    }
  }

  Future<void> _save({bool silent = false}) async {
    if (_isSaving) {
      // Coalesce: let the caller await the already-running save so guards
      // like _onWillPop don't race ahead and prompt while a save is still
      // in flight.
      final inFlight = _saveInFlight;
      if (inFlight != null) await inFlight;
      return;
    }
    _isSaving = true;
    if (!silent && mounted) setState(() {});
    final completer = Completer<void>();
    _saveInFlight = completer.future;
    try {
      await ref.read(canvasProvider.notifier).save();
      // Only say 'Salvato!' if the save actually cleared the dirty flag.
      // If state.isDirty is still true, _saveInner aborted silently (most
      // often: pre-save guard #2 fired because document references pages
      // whose data isn't in memory — a pull is now healing that). Tell
      // the user the truth so they don't think their work was saved when
      // it's still pending.
      final stillDirty = ref.read(canvasProvider)?.isDirty ?? false;
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(stillDirty
                ? 'Sincronizzazione in corso…'
                : 'Salvato!'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
      }
    } finally {
      _isSaving = false;
      _saveInFlight = null;
      completer.complete();
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
          {
            final s = ref.read(canvasProvider);
            final notif = ref.read(canvasProvider.notifier);
            // Lasso selection takes priority; otherwise fall back to the
            // single-element selection (image / shape / text picked via
            // double-tap) so Ctrl+C copies an image too.
            if (s?.lassoSelection != null) {
              notif.copySelection();
            } else if (s?.selectedElementId != null) {
              notif.copyElement(s!.selectedElementId!);
            } else {
              return KeyEventResult.ignored;
            }
            _toast('Selezione copiata');
            return KeyEventResult.handled;
          }
        case LogicalKeyboardKey.keyX:
          {
            final s = ref.read(canvasProvider);
            final notif = ref.read(canvasProvider.notifier);
            if (s?.lassoSelection != null) {
              notif.cutSelection();
            } else if (s?.selectedElementId != null) {
              notif.cutElement(s!.selectedElementId!);
            } else {
              return KeyEventResult.ignored;
            }
            _toast('Selezione tagliata');
            return KeyEventResult.handled;
          }
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

    // ? (Shift+/) — open keyboard shortcut cheat sheet. Power users on
    // desktop/iPad with keyboard have no other way to discover the
    // Ctrl+C/X/V/D/A/0, P/E/L/H/T/B/S single-key shortcuts — they were
    // only visible to someone reading the source code.
    if (shift && event.logicalKey == LogicalKeyboardKey.question) {
      _showShortcutHelp();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.slash && shift) {
      _showShortcutHelp();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.keyboard_rounded, size: 20),
            SizedBox(width: 8),
            Text('Scorciatoie tastiera'),
          ],
        ),
        content: const SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShortcutGroup('Generale', [
                  ('Ctrl+S', 'Salva ora'),
                  ('Ctrl+Z', 'Annulla'),
                  ('Ctrl+Shift+Z / Ctrl+Y', 'Ripeti'),
                  ('Ctrl+A', 'Seleziona tutto'),
                  ('Ctrl+0', 'Azzera zoom'),
                  ('Esc', 'Deseleziona / annulla'),
                  ('?', 'Questa guida'),
                ]),
                SizedBox(height: 12),
                _ShortcutGroup('Appunti', [
                  ('Ctrl+C', 'Copia selezione'),
                  ('Ctrl+X', 'Taglia selezione'),
                  ('Ctrl+V', 'Incolla'),
                  ('Ctrl+D', 'Duplica selezione'),
                  ('Canc / Backspace', 'Elimina elemento o selezione'),
                ]),
                SizedBox(height: 12),
                _ShortcutGroup('Strumenti', [
                  ('P', 'Penna'),
                  ('B', 'Pennello'),
                  ('E', 'Gomma'),
                  ('L', 'Lazo'),
                  ('H', 'Mano / sposta'),
                  ('T', 'Testo'),
                  ('S', 'Forma'),
                ]),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  Future<bool> _onWillPop() async {
    // Mark closing so didChangeAppLifecycleState doesn't fire a parallel
    // save if the OS backgrounds the app during the pop dialog.
    _closing = true;
    // If a save is in flight, wait for it to finish before deciding whether
    // to prompt. Otherwise the user just pressed "Save" and sees a
    // "save before leaving?" dialog for the same changes that are already
    // being persisted.
    if (_isSaving) {
      final inFlight = _saveInFlight;
      if (inFlight != null) await inFlight;
    }
    if (!mounted) return false;
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
      if (result == 'cancel') {
        // User backed out — re-enable lifecycle autosave.
        _closing = false;
        return false;
      }
      if (result == 'save') await _save();
    }
    // Fast-close flow:
    //
    //  1) Kick off flushPendingWork() in the background — it drains
    //     pending pulls + pulled-saves + remote-syncs so the SQLite row
    //     reflects the final state.  We do NOT await it before popping
    //     because on a slow network the flush can take seconds and the
    //     user should not be held hostage to a spinner when pressing
    //     back.
    //  2) Hand the flush Future to the route as the pop result.  The
    //     library's `.then()` callback awaits it before refreshing so
    //     the library card still shows the up-to-date pageCount the
    //     moment the flush lands (no stale "1 pagina" card).
    //  3) Fire closeNotebook() unawaited — it internally awaits
    //     flushPendingWork (idempotent) and then tears down state.
    final notifier = ref.read(canvasProvider.notifier);
    final flushFuture = notifier.flushPendingWork();
    if (mounted) Navigator.of(context).pop<Future<void>>(flushFuture);
    unawaited(notifier.closeNotebook());
    return false; // already popped above — don't pop again
  }

  // ── Drag-left/right page navigation ──

  /// [panOverride] lets the caller pass the post-update pan without
  /// allocating a `state.copyWith(panOffset: ...)` per pointer-move
  /// just to read it back. CanvasState's copyWith touches every field
  /// (215 PageData refs, lists, etc.) which is real GC pressure at the
  /// 60–120 Hz pan rate.
  void _checkPageDrag(CanvasState state, Size canvasSize,
      {Offset? panOverride}) {
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    final renderScale = min(canvasSize.width / pageW, canvasSize.height / pageH);
    final scaledW = pageW * renderScale;
    final centerOffsetX = (canvasSize.width - scaledW) / 2;

    final pan = panOverride ?? state.panOffset;
    // Right edge of the page in screen coords
    final pageRightScreen = (scaledW * state.zoom) + pan.dx + (centerOffsetX * state.zoom);
    // Left edge of the page in screen coords
    final pageLeftScreen = pan.dx + (centerOffsetX * state.zoom);

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
        // Swipe commit: reset zoom/pan so the next page opens centered.
        ref.read(canvasProvider.notifier).nextPage(resetViewport: true);
      }
    } else if (pageLeftScreen > canvasSize.width * 0.50 && hasPrev) {
      // Swipe commit: reset zoom/pan so the prev page opens centered.
      ref.read(canvasProvider.notifier).prevPage(resetViewport: true);
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
    // Never show context menu while stylus is actively touching the screen
    // (the touch event is almost certainly a palm).
    if (_stylusDown) return;
    // Bumped from 3 s → 8 s. A user pausing mid-sentence often rests the
    // palm for several seconds before writing again; the old window let
    // the context menu pop up unexpectedly during that pause. 8 s is
    // close to a 'really not writing anymore' threshold without being
    // annoying for legitimate context-menu requests.
    if (DateTime.now().difference(_lastStrokeActivity).inMilliseconds < 8000) return;
    // Require the touch to be the ONLY active pointer at start. Palm-rest
    // during writing typically registers as a touch alongside the stylus,
    // bringing _activePointers to 2; rejecting now avoids opening the
    // menu on the iPad while the user is mid-stroke.
    if (_activePointers > 1) return;
    _longPressGlobalPos = globalPos;
    _longPressFired = false;
    _longPressTimer = Timer(const Duration(milliseconds: 600), () {
      _longPressTimer = null;
      // Recheck guards at fire time — a palm could have landed during
      // the 600 ms wait. Don't open the menu if any of those triggered.
      if (_stylusDown) return;
      if (_activePointers != 1) return;
      if (DateTime.now().difference(_lastStrokeActivity).inMilliseconds < 8000) return;
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
        tool == CanvasTool.calligraphy ||
        tool == CanvasTool.highlighter ||
        tool == CanvasTool.eraserStandard ||
        tool == CanvasTool.eraserStroke ||
        tool == CanvasTool.lasso ||
        tool == CanvasTool.shape ||
        tool == CanvasTool.laser;
  }

  bool _shouldTouchPan(PointerDeviceKind kind, CanvasTool tool) {
    return _stylusOnlyDrawing && kind == PointerDeviceKind.touch && _isDrawLikeTool(tool);
  }

  void _onPointerDown(PointerDownEvent event, CanvasState state, Size canvasSize) {
    _activePointers++;

    // Track stylus presence so we can suppress palm-triggered long-press
    if (event.kind == PointerDeviceKind.stylus || event.kind == PointerDeviceKind.invertedStylus) {
      // Debug: log every stylus-down with the gap from the previous stroke
      // end. A short gap (<200 ms) right after a non-UP end (cancel / commit
      // mid-stroke) is the smoking gun for a "stroke break".
      final now = DateTime.now();
      final gapMs = _strokeEndedAt == null
          ? -1
          : now.difference(_strokeEndedAt!).inMilliseconds;
      final isBreakSusp = gapMs >= 0 && gapMs < 200 && _lastStrokeEndReason != 'pointerUp.commit';
      // Distance from the previous deferred-commit position, if any. Logs
      // even when no continuation happens — helps tune _deferStylusPx if
      // a break sneaks past the threshold.
      String distStr = '';
      if (_deferredCommitLastScreenPos != null) {
        final d = (event.position - _deferredCommitLastScreenPos!).distance;
        distStr = ' deferDist=${d.toStringAsFixed(1)}px';
      }
      _strokeDbg(
        'DOWN stylus p=${event.pointer} t=${event.timeStamp.inMilliseconds}ms '
        'gap=${gapMs}ms prevEnd=$_lastStrokeEndReason '
        'tool=${state.currentTool.name} '
        'active=${_activeStrokeNotifier.isActive} '
        'activePointers=$_activePointers$distStr'
        '${isBreakSusp ? " BREAK_SUSPECTED" : ""}',
      );

      // ── Continuation check (iPad spurious Up→Down) ──
      //
      // If we just deferred a commit, see if this DOWN is close enough in
      // time and space to be the resumption of the same stroke. If so,
      // cancel the deferred commit and skip the rest of the DOWN handling
      // — the notifier is already active with the buffered points (we
      // intentionally never cleared it on PointerUp), so the next move
      // event simply appends to the existing live stroke. Without this
      // iPad / Apple Pencil produces visible mid-letter breaks because
      // the OS occasionally emits a spurious UP+DOWN pair (sample
      // dropout / pressure threshold / pointer rebatching).
      final deferredPts = _deferredCommitPoints;
      if (deferredPts != null && _deferredCommitAt != null && _deferredCommitLastScreenPos != null) {
        final defGapMs = now.difference(_deferredCommitAt!).inMilliseconds;
        final defDist = (event.position - _deferredCommitLastScreenPos!).distance;
        if (defGapMs < _deferStylusMs && defDist < _deferStylusPx) {
          _deferredCommitTimer?.cancel();
          _deferredCommitTimer = null;
          _deferredCommitPoints = null;
          _deferredCommitAt = null;
          _deferredCommitLastScreenPos = null;
          _justContinuedFromDefer = true;
          _strokeDbg(
            'CONTINUATION p=${event.pointer} '
            'gap=${defGapMs}ms dist=${defDist.toStringAsFixed(1)}px '
            'liveStrokePts=${_activeStrokeNotifier.points.length}',
          );
          _stylusDown = true;
          _cancelLongPressTimer();
          return;
        }
        // Out of range → flush the pending commit before starting a new one
        _flushDeferredCommit();
      }

      _stylusDown = true;
      _cancelLongPressTimer(); // kill any pending palm long-press immediately
    }

    if (_activePointers >= 2) {
      // Palm rejection: if a stylus is already drawing and the incoming
      // second pointer is a touch (the user's wrist landing on the screen
      // while writing), DO NOT treat this as a pinch-to-zoom. Previously
      // we cancelled the active stroke here the moment the palm touched
      // down, which wiped the first few strokes the user had just drawn.
      // Instead, ignore the palm touch entirely — the Listener keeps
      // feeding stylus moves to _onPointerMove, and the scale handlers
      // below also early-return while _stylusDown is true.
      if (_stylusDown && event.kind == PointerDeviceKind.touch) {
        _cancelLongPressTimer();
        return;
      }
      // True multi-touch (two fingers, no stylus): pinch-to-zoom gesture.
      if (_activeStrokeNotifier.isActive) {
        _activeStrokeNotifier.clear();
        ref.read(canvasProvider.notifier).cancelStroke();
      }
      _isTouchPanning = false;
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
          // Snapshot the current Riverpod transform so subsequent drag
          // deltas accumulate locally — no per-frame Riverpod rebuild.
          _lassoTransformNotifier.begin(
            dragOffset: sel.dragOffset,
            rotation: sel.rotation,
            scale: sel.scale,
          );
          return;
        }
      }
    }

    // Check if double-tapping on an image/shape → select it.
    // MUST run before tool-specific early returns below (eraser/shape/lasso),
    // otherwise double-click is swallowed by the lasso path start for lasso,
    // and by the stroke start for eraser/shape.
    //
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

    // Eraser: only erase, don't start a stroke visual
    if (tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke) {
      ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
      return;
    }

    // Laser pointer: append to the fading-trail notifier ONLY. Never
    // touches Riverpod, never commits a stroke; the trail evaporates
    // on its own after a couple of seconds.
    if (tool == CanvasTool.laser) {
      _laserStrokeNotifier.addPoint(pagePos);
      return;
    }

    // Shape tool: only set start pos, no visual stroke
    if (tool == CanvasTool.shape) {
      ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
      return;
    }

    // Lasso tool: only track via provider (no visual pen stroke).
    // ORDER MATTERS: bake+clear the previous selection BEFORE starting the new
    // lasso path. Otherwise the render engine paints one frame with the stale
    // selection bounds (still carrying the previous dragOffset) while the new
    // path already contains its first point — the user perceives this as the
    // new lasso "starting offset" from the true touch location.
    if (tool == CanvasTool.lasso) {
      ref.read(canvasProvider.notifier).clearLassoPath(); // bake previous + reset provider path
      _lassoPathNotifier.start(pagePos);
      return;
    }

    // For pen/brush/highlighter only: pass the RAW pressure (incl. 0 for
    // mouse/touchpad) to the fast notifier. The notifier synthesises a
    // velocity-derived pseudo-pressure when the device reports no pressure,
    // restoring stroke modulation that's otherwise stuck at the 0.5
    // fallback. The provider keeps the 0.5 fallback for its own bookkeeping
    // (its activeStroke is overwritten on commit by the notifier's points).
    final rawPressureForPen = event.pressure;
    ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
    _activeStrokeNotifier.start(pagePos, rawPressureForPen);
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
        _checkPageDrag(latest, canvasSize,
            panOverride: latest.panOffset + delta);
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
        _checkPageDrag(latest, canvasSize,
            panOverride: latest.panOffset + delta);
      }
      return;
    }

    if (_isDraggingSelection) {
      final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
      final delta = pagePos - _lastLassoDragPos;
      _lastLassoDragPos = pagePos;
      // Update local notifier (no Riverpod). Painter listens via
      // _repaintNotifier so only the canvas layer repaints.
      _lassoTransformNotifier.translate(delta);
      return;
    }

    final pagePos = _toPageCoords(event.localPosition, state, canvasSize);
    final pressure = event.pressure > 0 ? event.pressure : 0.5;
    // Pass raw pressure (incl. 0) to the active-stroke notifier so it can
    // synth pseudo-pressure from velocity for non-pressure devices
    // (mouse/touchpad). Stylus events always report > 0 and pass through.
    final rawPressureForPen = event.pressure;

    if (tool == CanvasTool.lasso) {
      _onLassoPointerMove(pagePos);
      return;
    }

    // Laser: keep appending to the fading trail, never start a real
    // stroke. Bypasses Riverpod entirely; the painter listens on
    // _laserStrokeNotifier via _repaintNotifier.
    if (tool == CanvasTool.laser) {
      _laserStrokeNotifier.addPoint(pagePos);
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

      // Post-continuation guard: the very first MOVE after a continuation
      // decision must land near the tail of the kept-alive stroke. If it
      // doesn't (the user really started a fresh stroke that happened to
      // arrive inside the defer window), commit the old stroke and start
      // a fresh one — otherwise the new mark would graft a phantom line
      // onto the previous stroke.
      if (_justContinuedFromDefer) {
        _justContinuedFromDefer = false;
        final notifierPts = _activeStrokeNotifier.points;
        if (notifierPts.isNotEmpty) {
          final last = notifierPts.last;
          final ddx = pagePos.dx - last.x;
          final ddy = pagePos.dy - last.y;
          // 12 page-units ≈ 24 screen-px at default 2× zoom — well above
          // any realistic Apple Pencil sample dropout but short enough to
          // catch unintended re-strokes nearby.
          if (ddx * ddx + ddy * ddy > 12 * 12) {
            final keptPts = List<StrokePoint>.from(notifierPts);
            _activeStrokeNotifier.clear();
            ref.read(canvasProvider.notifier).commitAndEndStroke(keptPts);
            ref.read(canvasProvider.notifier).startStroke(pagePos, pressure);
            _activeStrokeNotifier.start(pagePos, rawPressureForPen);
            _lastStrokeActivity = DateTime.now();
            _lastHoldCheckPos = pagePos;
            return;
          }
        }
      }
      _activeStrokeNotifier.addPoint(pagePos, rawPressureForPen);
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

    // Clear stylus tracking when stylus lifts
    if (event.kind == PointerDeviceKind.stylus || event.kind == PointerDeviceKind.invertedStylus) {
      _strokeDbg(
        'UP stylus p=${event.pointer} t=${event.timeStamp.inMilliseconds}ms '
        'active=${_activeStrokeNotifier.isActive} '
        'pts=${_activeStrokeNotifier.points.length} '
        'multiTouch=$wasMultiTouch '
        'activePointers=$_activePointers',
      );
      _stylusDown = false;
    }

    // Don't commit anything if this was a multi-touch gesture (pinch-to-zoom)
    if (wasMultiTouch || _activePointers >= 1) return;

    // Barrel button erase: restore previous tool on lift
    if (_barrelButtonErasing) {
      _barrelButtonErasing = false;
      ref.read(canvasProvider.notifier).endStroke();
      _markStrokeEnded('pointerUp.barrelEnd');
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
      // Commit the locally-tracked drag offset back to Riverpod in one
      // shot. During the drag _lassoTransformNotifier received every
      // delta; now Riverpod catches up exactly once per gesture.
      _commitLassoTransform();
      // The full transform (rotation/scale + drag) stays in lassoSelection
      // and is baked into the canvas when the user clicks away or
      // changes tool, same as before.
      return;
    }

    final state = ref.read(canvasProvider);
    if (state == null) return;

    // Shape recognized during hold → commit immediately
    if (_shapeRecognizedDuringHold && state.recognizedShape != null) {
      _shapeRecognizedDuringHold = false;
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).commitRecognizedShape();
      _markStrokeEnded('pointerUp.shapeCommit');
      return;
    }
    _shapeRecognizedDuringHold = false;

    // Shape adjustment mode: commit the adjusted shape
    if (state.isAdjustingRecognized && state.recognizedShape != null) {
      ref.read(canvasProvider.notifier).commitRecognizedShape();
      _markStrokeEnded('pointerUp.shapeAdjust');
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
      // ── Stroke break defense ──
      //
      // For stylus (Apple Pencil on iPad), defer the commit by
      // _deferStylusMs. iPad/Apple Pencil occasionally emits a spurious
      // PointerUp followed by a PointerDown while the user has not
      // actually lifted the pen. Without defer, each segment would be
      // committed as a separate stroke and the user sees a mid-letter
      // break. If a fresh stylus DOWN arrives in the defer window close
      // to this end position, _onPointerDown resumes the same stroke
      // (notifier is kept active during defer; continuation just cancels
      // the timer). Otherwise the timer fires and commits normally
      // (notifier is cleared inside _flushDeferredCommit, in the same
      // frame as the commit so the rendered stroke does not blink).
      //
      // For non-stylus (mouse/touchpad/touch) commit immediately as
      // before — the bug is iPad-specific and adding latency on PC
      // would be a regression.
      if (event.kind == PointerDeviceKind.stylus ||
          event.kind == PointerDeviceKind.invertedStylus) {
        // Snapshot points (notifier stays active so the rendered live
        // stroke remains on screen during the defer window).
        _deferredCommitPoints = List<StrokePoint>.from(_activeStrokeNotifier.points);
        _deferredCommitAt = DateTime.now();
        _deferredCommitLastScreenPos = event.position;
        _deferredCommitTimer?.cancel();
        _deferredCommitTimer = Timer(
          const Duration(milliseconds: _deferStylusMs),
          _flushDeferredCommit,
        );
      } else {
        final points = List<StrokePoint>.from(_activeStrokeNotifier.points);
        _activeStrokeNotifier.clear();
        ref.read(canvasProvider.notifier).commitAndEndStroke(points);
        _markStrokeEnded('pointerUp.commit');
      }
    } else {
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).endStroke();
      _markStrokeEnded('pointerUp.endEmpty');
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _activePointers = max(0, _activePointers - 1);
    _strokeDbg(
      'CANCEL kind=${event.kind.name} p=${event.pointer} '
      't=${event.timeStamp.inMilliseconds}ms '
      'stylusDown=$_stylusDown active=${_activeStrokeNotifier.isActive} '
      'pts=${_activeStrokeNotifier.points.length} '
      'activePointers=$_activePointers',
    );
    // If iOS palm-rejection cancels a touch pointer while the stylus is
    // actively drawing, DO NOT tear down the stylus stroke — the pen is
    // still making a valid mark. Only reset touch-specific gesture state
    // and return. Previously this path undid the user's first stroke
    // whenever their palm brushed the screen mid-draw on iPad.
    if (event.kind == PointerDeviceKind.touch && _stylusDown) {
      _isTouchPanning = false;
      _holdRecognizeTimer?.cancel();
      _shapeRecognizedDuringHold = false;
      return;
    }
    _isTouchPanning = false;
    _isDraggingSelection = false;
    _holdRecognizeTimer?.cancel();
    _shapeRecognizedDuringHold = false;
    // ── Stroke-break defense ──
    //
    // If a stylus PointerCancel arrives while we already have meaningful
    // points buffered, COMMIT the partial stroke instead of discarding it.
    // This way an unexpected cancel (gesture arena race we didn't catch,
    // iPadOS palm-rejection misfire on the pen, transient Pencil
    // disconnect, app briefly losing focus) still leaves the user's mark
    // on the page rather than producing a visible mid-letter break. The
    // next pointer event simply starts a fresh stroke. <2 points means
    // the stroke is effectively a tap and is safe to discard.
    final isStylusCancel = event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (isStylusCancel &&
        _activeStrokeNotifier.isActive &&
        _activeStrokeNotifier.points.length >= 2) {
      final points = List<StrokePoint>.from(_activeStrokeNotifier.points);
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).commitAndEndStroke(points);
      _markStrokeEnded('pointerCancel.committedStylus');
      _strokeDbg('CANCEL_RESCUED kind=${event.kind.name} pts=${points.length}');
      // Restore barrel button state if needed before returning
      if (_barrelButtonErasing) {
        _barrelButtonErasing = false;
        if (_barrelButtonPreviousTool != null) {
          ref.read(canvasProvider.notifier).setTool(_barrelButtonPreviousTool!);
          _barrelButtonPreviousTool = null;
        }
      }
      return;
    }
    // Cancel any in-progress stroke or lasso
    if (_activeStrokeNotifier.isActive) {
      _activeStrokeNotifier.clear();
      ref.read(canvasProvider.notifier).cancelStroke();
      _markStrokeEnded('pointerCancel.stroke');
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
    // Palm rejection: if the stylus is currently drawing, the scale gesture
    // was triggered by the user's wrist landing on the screen — ignore it
    // so the canvas doesn't zoom mid-stroke.
    if (_stylusDown) return;
    final state = ref.read(canvasProvider);
    if (state == null) return;
    _baseZoom = state.zoom;
    _lastFocalPoint = details.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Same palm guard as _onScaleStart. Even if onScaleStart was already
    // rejected, Flutter still calls onScaleUpdate during the gesture — we
    // must gate it too, otherwise a palm landing mid-stroke can still move
    // the zoom level via the accumulated scale delta.
    if (_stylusDown) return;
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

  /// Formats we accept from the system clipboard, in priority order.
  /// PNG/JPEG first because they're already universally decodable. iOS
  /// screenshots land as HEIC or TIFF on the clipboard — those fell
  /// through the old PNG-or-JPEG-only check and the paste silently did
  /// nothing on iPad. For exotic formats we transcode to PNG before
  /// storing so the asset is readable on every platform (Flutter on
  /// Windows/Linux can't decode HEIC natively).
  static const _clipboardImageFormats = <(SimpleFileFormat, String)>[
    (Formats.png, 'png'),
    (Formats.jpeg, 'jpg'),
    (Formats.heic, 'heic'),
    (Formats.heif, 'heif'),
    (Formats.tiff, 'tiff'),
    (Formats.webp, 'webp'),
    (Formats.gif, 'gif'),
    (Formats.bmp, 'bmp'),
  ];

  /// Paste an image specifically from the SYSTEM clipboard, bypassing the
  /// HandWriter-internal clipboard. Used by the 'Incolla immagine' menu
  /// item — the user explicitly asked for an image, so we must ignore
  /// any older internal selection that might still be in memory.
  Future<void> _pasteSystemClipboardImageOnly() async {
    await _pasteFromClipboard(preferSystemImage: true);
  }

  Future<void> _pasteFromClipboard({bool preferSystemImage = false}) async {
    // The 'preferSystemImage' flag, set by the 'Incolla immagine' menu,
    // skips the internal-first short-circuit. The user explicitly asked
    // for an image, and if they copied one externally (iPad screenshot,
    // Safari image, etc.) that new clipboard entry must win over any
    // stale internal selection the app still holds in memory. Without
    // this, every paste returned the last thing copied INSIDE HandWriter
    // even when the system clipboard had a newer, clearly-intended image.
    if (!preferSystemImage) {
      final cs = ref.read(canvasProvider);
      if (cs != null && cs.clipboard != null) {
        ref.read(canvasProvider.notifier).paste();
        return;
      }
    }

    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        ref.read(canvasProvider.notifier).paste();
        return;
      }
      final reader = await clipboard.read();

      for (final entry in _clipboardImageFormats) {
        final fmt = entry.$1;
        final ext = entry.$2;
        if (!reader.canProvide(fmt)) continue;

        final completer = Completer<Uint8List?>();
        reader.getFile(fmt, (file) async {
          try {
            completer.complete(await file.readAll());
          } catch (_) {
            completer.complete(null);
          }
        }, onError: (_) => completer.complete(null));
        final raw = await completer.future;
        if (raw == null || raw.isEmpty) continue;

        // Non-PNG/JPEG formats (especially HEIC from iPad screenshots) are
        // not universally decodable by Flutter on other platforms, so
        // transcode them to PNG via the platform image codec before we
        // hand them to the asset store.
        Uint8List bytes = raw;
        String fileName = 'clipboard_image.$ext';
        if (ext != 'png' && ext != 'jpg') {
          final transcoded = await _transcodeToPng(raw);
          if (transcoded != null) {
            bytes = transcoded;
            fileName = 'clipboard_image.png';
          } else {
            // Couldn't decode — skip and fall through to the next format.
            CrashLogger.append(
              '[Paste] failed to transcode $ext from clipboard '
              '(${raw.length} bytes)',
            );
            continue;
          }
        }

        final s = ref.read(canvasProvider);
        if (s == null) return;
        if (!mounted) return;
        final viewSize = (context.findRenderObject() as RenderBox?)?.size
            ?? const Size(400, 600);
        final center = Offset(
          (-s.panOffset.dx + viewSize.width / 2) / s.zoom,
          (-s.panOffset.dy + viewSize.height / 2) / s.zoom,
        );
        _insertImage(bytes, fileName, center);
        return;
      }

      // No supported image format on the clipboard. Log which formats WERE
      // offered so we know what to add next time (iOS sometimes advertises
      // vendor-specific UTIs the plugin doesn't map cleanly).
      final offered = _clipboardImageFormats
          .where((e) => reader.canProvide(e.$1))
          .map((e) => e.$2)
          .toList();
      CrashLogger.append(
        '[Paste] no matching image format on clipboard '
        '(offered image formats: $offered)',
      );
    } catch (e, st) {
      CrashLogger.append('[Paste] clipboard read failed: $e\n$st');
    }

    // Final fallback: try internal paste anyway (handles pendingPaste, etc.)
    ref.read(canvasProvider.notifier).paste();
  }

  /// Decode [bytes] with the platform image codec and re-encode as PNG,
  /// so exotic formats (HEIC/HEIF/TIFF/WEBP/...) become portable. Returns
  /// null if the platform can't decode this format.
  Future<Uint8List?> _transcodeToPng(Uint8List bytes) async {
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final pngData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (pngData == null) return null;
      return pngData.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  // ── Image / PDF insertion ──

  Future<void> _captureAndInsertImage(Offset pagePos) async {
    // Capture ref before the async gap — the widget may be unmounted
    // when the camera activity returns on Android.
    final notifier = ref.read(canvasProvider.notifier);
    final messenger = mounted ? ScaffoldMessenger.of(context) : null;
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: ImageSource.camera);
      if (photo == null) return;
      final file = io.File(photo.path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final dims = _decodeImageDimensions(bytes);
      double w = dims?.width.toDouble() ?? 300;
      double h = dims?.height.toDouble() ?? 200;
      if (w > 300) {
        final s = 300 / w;
        w *= s;
        h *= s;
      }
      notifier.addImageElement(pagePos, photo.name, bytes, w, h);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Errore fotocamera: $e')),
      );
    }
  }

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
      // Adaptive DPI: big PDFs get rendered at a lower resolution so the
      // raw pixel buffers don't blow the iOS jetsam limit. 150 DPI on A4
      // is ~8.7 MB/page of RGBA — at 67 pages that's ~580 MB resident if
      // we buffered them, and even streamed it pressures memory.
      final int dpi = estimated > 40 ? 100 : (estimated > 15 ? 120 : 150);

      // Stream page-by-page: consume each raster → PNG → insert → let it
      // go out of scope before pulling the next one from Printing.raster.
      // This is what fixes the ~15-page crash on iPad with long PDFs.
      final notifier = ref.read(canvasProvider.notifier);

      // Suppress remote pulls for the duration of the import.
      // The await Future.delayed(Duration.zero) between pages yields to the
      // event loop; without this guard a pull can fire mid-loop, shifting
      // document.pages and causing insertions at the wrong position or with
      // the wrong chapter assignment.
      notifier.beginBulkOperation();
      int processed = 0;
      await for (final raster in Printing.raster(bytes, dpi: dpi.toDouble())) {
        if (!mounted) return;

        final png = await raster.toPng();
        if (!mounted) return;

        if (processed > 0) notifier.addPage();

        final st = ref.read(canvasProvider);
        final pageW = st?.currentPage?.width ?? 595.0;
        final pageH = st?.currentPage?.height ?? 842.0;
        double imgW = raster.width.toDouble();
        double imgH = raster.height.toDouble();
        final scaleToFit = min(pageW / imgW, pageH / imgH);
        imgW *= scaleToFit;
        imgH *= scaleToFit;
        final insertPos = Offset((pageW - imgW) / 2, (pageH - imgH) / 2);
        notifier.addImageElement(
          insertPos,
          '${name}_p${processed + 1}.png',
          png,
          imgW,
          imgH,
          locked: true,
        );

        processed++;

        // Progress feedback for long imports so the user sees we're alive.
        if (mounted && estimated > kPageConfirmThreshold && processed % 5 == 0) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              content: Text('Importazione PDF: $processed/$estimated'),
              duration: const Duration(seconds: 30),
            ));
        }

        // Yield to the event loop between pages so the engine can reclaim
        // the raster's native pixel buffer before we grab the next one.
        await Future<void>.delayed(Duration.zero);
      }

      notifier.endBulkOperation();

      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();

      if (processed == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossibile leggere il PDF: nessuna pagina trovata')),
        );
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF importato: $processed ${processed == 1 ? 'pagina' : 'pagine'}')),
        );
      }
    } catch (e) {
      ref.read(canvasProvider.notifier).endBulkOperation();
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
    // ── Targeted watch: skip rebuilds during pan/zoom/eraser-cursor ──
    //
    // `state.copyWith(panOffset: x)` and friends fire on every pointer-
    // move event during pan, every wheel event during zoom, and every
    // hover during erase. With a plain `ref.watch(canvasProvider)` each
    // of those events caused a full rebuild of the editor chrome
    // (top bar + bottom strip + floating dock + tool popup) — visibly
    // choppy on a 215-page notebook.
    //
    // Instead we watch a record signature that EXCLUDES the volatile
    // fields. Riverpod's select compares the result with `==`, and a
    // record's `==` is field-wise — when the only change is panOffset,
    // every other field is identical-by-reference (state.copyWith
    // shares unchanged Map/List/object refs), the record compares
    // equal, and the watch is a no-op.
    //
    // The `_buildCanvas` path uses an inner Consumer (or notifier) to
    // pick up the live panOffset/zoom for the painter, so panning
    // still updates the canvas — it just doesn't drag the rest of the
    // UI tree along for the ride.
    ref.watch(canvasProvider.select((s) {
      if (s == null) return null;
      return (
        metadata: s.metadata,
        document: s.document,
        // pages: OMITTED — eraser commits replace the pages Map every
        // 50 ms and the chrome doesn't actually use page CONTENT, only
        // counts (which come from document.pages.length). Letting
        // pages-ref changes rebuild the chrome was the residual stutter
        // on dense ink during eraser drag.
        currentPageIndex: s.currentPageIndex,
        isDirty: s.isDirty,
        toolSettings: s.toolSettings,
        activeChapterId: s.activeChapterId,
        pendingConflicts: s.pendingConflicts,
        pendingRemoteChanges: s.pendingRemoteChanges,
        lassoSelection: s.lassoSelection,
        activeStroke: s.activeStroke,
        lassoPath: s.lassoPath,
        shapeStartPos: s.shapeStartPos,
        shapeEndPos: s.shapeEndPos,
        recognizedShape: s.recognizedShape,
        selectedElementId: s.selectedElementId,
        currentTool: s.currentTool,
        undoStack: s.undoStack,
        redoStack: s.redoStack,
        symbolLibraries: s.symbolLibraries,
      );
    }));
    // After the select-based subscription decides we should rebuild,
    // pull the full state synchronously for the build body's many
    // canvasState.X reads. ref.read does NOT subscribe.
    final canvasState = ref.read(canvasProvider);

    // Auto-open conflict resolution when conflicts detected
    ref.listen<int>(
      canvasProvider.select((s) => s?.pendingConflicts.length ?? 0),
      (prev, next) {
        if (next > 0 && (prev == null || prev == 0)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ConflictResolutionScreen(),
                ),
              );
            }
          });
        }
      },
    );

    if (canvasState == null) {
      return const Scaffold(body: Center(child: Text('Nessun notebook aperto')));
    }
    final currentPage = canvasState.currentPage;
    if (currentPage == null) {
      // Two distinct null-currentPage cases:
      //  (A) Notebook has zero pages altogether — rare, show plain message.
      //  (B) The PageEntry exists but its PageData is missing (server lost
      //      the file / partial pull / corruption). Offer recovery actions
      //      so the user isn't trapped — previously the canvas silently
      //      fell back to a different page's content, which hid the bug
      //      entirely ("pagine di 1P inv uguali a Control's prima pagina").
      final doc = canvasState.document;
      final isMissing = doc.pages.isNotEmpty &&
          canvasState.currentPageIndex >= 0 &&
          canvasState.currentPageIndex < doc.pages.length;
      final missingCount = ref
          .read(canvasProvider.notifier)
          .missingPageCount();
      return Scaffold(
        appBar: AppBar(
          title: Text(canvasState.metadata.title),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => _onWillPop(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isMissing ? Icons.warning_amber_rounded : Icons.description_outlined,
                  size: 64,
                  color: Colors.orange.shade600,
                ),
                const SizedBox(height: 16),
                Text(
                  isMissing
                      ? 'Dati pagina mancanti'
                      : 'Nessuna pagina',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                if (isMissing) ...[
                  const SizedBox(height: 8),
                  Text(
                    missingCount > 1
                        ? 'Questa pagina e altre ${missingCount - 1} non sono state '
                          'recuperate dal server. I file potrebbero essere '
                          'andati persi durante una sincronizzazione parziale.'
                        : 'Il file di questa pagina non è stato recuperato dal '
                          'server. Potrebbe essere andato perso durante una '
                          'sincronizzazione parziale.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Riprova sync'),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Sincronizzazione in corso…'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.note_add_outlined),
                        label: const Text('Ripristina come pagina vuota'),
                        onPressed: () async {
                          final n = ref.read(canvasProvider.notifier);
                          n.repairMissingPageData(canvasState.currentPageIndex);
                          await n.save();
                        },
                      ),
                      if (missingCount > 1)
                        FilledButton.icon(
                          icon: const Icon(Icons.auto_fix_high),
                          label: Text('Ripristina tutte ($missingCount)'),
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final n = ref.read(canvasProvider.notifier);
                            final repaired = n.repairAllMissingPages();
                            await n.save();
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                    '$repaired pagine ripristinate come vuote'),
                              ),
                            );
                          },
                        ),
                      TextButton.icon(
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Elimina pagina'),
                        onPressed: () {
                          ref.read(canvasProvider.notifier)
                              .deletePage(canvasState.currentPageIndex);
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final palette = HwThemeScope.of(context);
    final notifier = ref.read(canvasProvider.notifier);
    final presetColors = ref.watch(presetColorsProvider);
    final activeColor = Color(canvasState.toolSettings.color);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final shouldPop = await _onWillPop();
        if (shouldPop && mounted) navigator.pop();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: palette.paper1,
          body: Stack(
            children: [
              Column(
                children: [
                  HwEditorTopBar(
                    notebookTitle: canvasState.metadata.title,
                    coverColor: Color(canvasState.metadata.coverColor),
                    currentPage: canvasState.currentPageIndex + 1,
                    totalPages: canvasState.document.pages.length,
                    dirty: canvasState.isDirty,
                    canUndo: notifier.canUndo,
                    canRedo: notifier.canRedo,
                    syncState: canvasState.isDirty
                        ? HwSyncState.pending
                        : HwSyncState.ok,
                    onBack: () async {
                      await _onWillPop();
                    },
                    onUndo: () => notifier.undo(),
                    onRedo: () => notifier.redo(),
                    onPagesTap: () => _showPageManager(canvasState),
                    onSymbolsTap: () =>
                        _showSymbolsDialog(_visibleCenterPagePos(canvasState)),
                    onExportTap: () => _showExportSheet(),
                    onMoreTap: () => _showMoreSheet(canvasState),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        if (_popupOpen) setState(() => _popupOpen = false);
                      },
                      child: _buildCanvas(canvasState, currentPage),
                    ),
                  ),
                  HwBottomPageStrip(
                    chapterLabel: _currentChapterLabel(canvasState),
                    // Only show pages of the active chapter (or all when
                    // no chapter filter is active).
                    pageNumbers: [
                      for (final i in canvasState.filteredPageIndices) i + 1,
                    ],
                    currentPage: canvasState.currentPageIndex + 1,
                    onPageTap: (n) => notifier.goToPage(n - 1),
                    onPageSecondary: (n, pos) =>
                        _showPageStripContextMenu(n, pos),
                    onAllPagesTap: () => _showPageManager(canvasState),
                  ),
                ],
              ),
              // Floating tool dock
              Positioned(
                left: 0,
                right: 0,
                bottom: 110,
                child: Center(
                  child: HwFloatingDock(
                    currentTool: canvasState.currentTool,
                    activeInkColor: activeColor,
                    shapeGuess: canvasState.toolSettings.shapeRecognition,
                    onShapeGuessChanged: (v) {
                      notifier.setToolSettings(canvasState.toolSettings
                          .copyWith(shapeRecognition: v));
                    },
                    onToolChanged: (t) {
                      notifier.setTool(t);
                      // Switching tool never auto-opens the popup —
                      // the user explicitly asks for it by tapping
                      // the active tool again.
                      if (_popupOpen) setState(() => _popupOpen = false);
                    },
                    onActiveTap: () =>
                        setState(() => _popupOpen = !_popupOpen),
                    position: _dockPosition,
                  ),
                ),
              ),
              // Tool option popup
              if (_popupOpen)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 170,
                  child: Center(
                    child: HwToolPopup(
                      tool: canvasState.currentTool,
                      color: activeColor,
                      onColorChanged: (c) {
                        notifier.setToolSettings(canvasState.toolSettings
                            .copyWith(color: c.toARGB32()));
                      },
                      thickness: canvasState.toolSettings.strokeWidth,
                      onThicknessChanged: (v) {
                        notifier.setToolSettings(canvasState.toolSettings
                            .copyWith(strokeWidth: v));
                      },
                      presetColors: presetColors
                          .map((c) => Color(c))
                          .toList(),
                      eraserSize: canvasState.toolSettings.eraserSize,
                      onEraserSizeChanged: (s) {
                        notifier.setToolSettings(
                            canvasState.toolSettings.copyWith(eraserSize: s));
                      },
                      eraserPerStroke:
                          canvasState.currentTool == CanvasTool.eraserStroke,
                      onEraserPerStrokeChanged: (perStroke) {
                        notifier.setTool(perStroke
                            ? CanvasTool.eraserStroke
                            : CanvasTool.eraserStandard);
                      },
                      onClose: () => setState(() => _popupOpen = false),
                    ),
                  ),
                ),
              const RemoteChangesBanner(),
              // Subtle "Sincronizzazione…" pill while a remote pull is in
              // flight — lets the user know the notebook may update shortly
              // so they don't think the app glitched.
              Positioned(
                top: 64,
                right: 12,
                child: ValueListenableBuilder<bool>(
                  valueListenable:
                      ref.read(canvasProvider.notifier).isPullingFromRemote,
                  builder: (_, pulling, __) => AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: pulling ? 1.0 : 0.0,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: ValueListenableBuilder<({int done, int total})>(
                          valueListenable: ref
                              .read(canvasProvider.notifier)
                              .pullProgress,
                          builder: (_, progress, __) {
                            final label = progress.total > 0
                                ? 'Sincronizzazione ${progress.done}/${progress.total}'
                                : 'Sincronizzazione…';
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: progress.total > 0
                                        ? progress.done / progress.total
                                        : null,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            Colors.white),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  label,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildTopBar(CanvasState canvasState) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark
        ? Theme.of(context).colorScheme.onSurface
        : Colors.grey.shade800;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: isDark
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Colors.white,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded, color: fg, size: 18),
            tooltip: 'Torna alla libreria',
            onPressed: () async {
              // _onWillPop handles pop + cleanup internally; it returns false.
              await _onWillPop();
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              canvasState.metadata.title,
              style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canvasState.isDirty)
            Tooltip(
              message: 'Ci sono modifiche non ancora salvate sul server',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text('Non salvato', style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
              ),
            ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Livello di zoom corrente',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isDark
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${(canvasState.zoom * 100).round()}%',
                style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
          ),
          IconButton(
            tooltip: _stylusOnlyDrawing
                ? 'Solo penna attivo — tocca per consentire anche il dito'
                : 'Dito attivo — tocca per accettare solo la penna',
            icon: Icon(
              _stylusOnlyDrawing ? Icons.create_rounded : Icons.touch_app_rounded,
              color: _stylusOnlyDrawing ? Colors.blue : fg,
              size: 20,
            ),
            onPressed: () {
              setState(() => _stylusOnlyDrawing = !_stylusOnlyDrawing);
            },
          ),
          const SizedBox(width: 4),
          // Auto-save indicator
          if (_isSaving)
            const Tooltip(
              message: 'Salvataggio in corso…',
              child: Padding(
                padding: EdgeInsets.only(right: 4),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          IconButton(
            icon: Icon(
              Icons.save_rounded,
              color: canvasState.isDirty
                  ? Colors.blue
                  : Theme.of(context).disabledColor,
              size: 20,
            ),
            tooltip: canvasState.isDirty
                ? 'Salva ora (Ctrl+S)'
                : 'Tutto salvato',
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
                    // ── Live-state read (was the phantom-line bug) ──
                    // `canvasState` from the build closure is intentionally
                    // STALE on pan/zoom/pages — the chrome's select excludes
                    // those fields. _toPageCoords reads state.panOffset and
                    // state.zoom, so feeding it the stale state turned the
                    // very first point of a new stroke into the wrong page
                    // coordinate (it lived in the OLD pan/zoom frame). The
                    // next pointer-move could land in the right frame and
                    // the user saw the new stroke "stretch" from a phantom
                    // start to the real one. Same fix as onPointerSignal
                    // below — always pull live state.
                    final live = ref.read(canvasProvider) ?? canvasState;
                    if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
                      if (live.pendingSymbol != null) {
                        ref.read(canvasProvider.notifier).clearPendingSymbol();
                        return;
                      }
                      _showContextMenu(e.position, e.localPosition, live, canvasSize);
                      return;
                    }
                    _onPointerDown(e, live, canvasSize);
                  },
                  onPointerMove: (e) {
                    final live = ref.read(canvasProvider) ?? canvasState;
                    _onPointerMove(e, live, canvasSize);
                  },
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  onPointerSignal: (event) {
                    // Read live state — `canvasState` from the build
                    // closure is intentionally STALE on pan/zoom/cursor
                    // because the parent's select excludes those fields,
                    // so using it here would feed back the OLD zoom/pan
                    // into every wheel calculation and snap the canvas
                    // back to the centre. ref.read returns current.
                    final live = ref.read(canvasProvider);
                    if (live == null) return;
                    if (event is PointerScrollEvent) {
                      final oldZoom = live.zoom;
                      final zoomDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                      final newZoom = (oldZoom * zoomDelta).clamp(0.3, 5.0);
                      final cursorPos = event.localPosition;
                      final newPan = live.panOffset +
                          (cursorPos - live.panOffset) * (1 - (newZoom / oldZoom));
                      ref
                          .read(canvasProvider.notifier)
                          .setZoomAndPan(newZoom, newPan);
                    } else if (event is PointerScaleEvent) {
                      // Trackpad pinch-to-zoom (may not fire on all platforms)
                      final oldZoom = live.zoom;
                      final newZoom = (oldZoom * event.scale).clamp(0.3, 5.0);
                      final cursorPos = event.localPosition;
                      final newPan = live.panOffset +
                          (cursorPos - live.panOffset) * (1 - (newZoom / oldZoom));
                      ref
                          .read(canvasProvider.notifier)
                          .setZoomAndPan(newZoom, newPan);
                    }
                  },
                  child: GestureDetector(
                    // ── Stroke-break fix ──
                    //
                    // Restrict the inner ScaleGestureRecognizer (and DoubleTap)
                    // to non-stylus pointers. With stylus included, the
                    // recognizer joins Flutter's gesture arena for every pen
                    // pointer; once the cumulative pen movement exceeds the
                    // pan slop (~36 logical px for stylus), the recognizer
                    // resolves `accepted` even with a single pointer, which
                    // sends `PointerCancel(stylus)` to the surrounding
                    // Listener. _onPointerCancel then tears down the active
                    // stroke mid-letter — the user perceives this as the pen
                    // suddenly "lifting" and a new stroke starting at the
                    // same place ("stroke break mid-pen-down" on iPad).
                    //
                    // Pinch-to-zoom on iPad still works (touch+touch), and
                    // trackpad pinch on desktop still works (trackpad). The
                    // _onScale* callbacks already early-return on `_stylusDown`
                    // for safety, but that guard only suppresses the callback
                    // body — not the arena claim. supportedDevices is the
                    // only way to keep the pen out of the arena entirely.
                    // Exclude `mouse` from supportedDevices: middle-
                    // mouse pan is handled directly by the outer
                    // Listener, and including mouse here put every
                    // PointerMoveEvent into the gesture arena. The
                    // ScaleGestureRecognizer holds the move events
                    // until the arena resolves (5–50 ms variable
                    // latency), turning continuous panning into
                    // bursty 6-11 ev/s — the "scattante" the user
                    // reported even with cache hits at 100 %.
                    supportedDevices: const {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.trackpad,
                    },
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    // Double-tap toggles zoom-to-fit <-> default 2.0x zoom.
                    // Only fires for non-drawing tools so a user can't
                    // accidentally zoom while sketching fast.
                    onDoubleTap: (canvasState.currentTool == CanvasTool.pan ||
                            canvasState.currentTool == CanvasTool.image)
                        ? () {
                            // Toggle: if already near fit-zoom, go back to 2.0
                            // default; otherwise fit the full page.
                            final notifier = ref.read(canvasProvider.notifier);
                            if (canvasState.zoom < 1.4) {
                              notifier.resetZoom();
                            } else {
                              notifier.zoomToFit();
                            }
                          }
                        : null,
                    child: ClipRect(
                      child: RepaintBoundary(
                        // ── Inner viewport watch ──
                        // The parent build's `ref.watch` deliberately
                        // EXCLUDES panOffset/zoom so pan/wheel events don't
                        // rebuild the editor chrome. But the painter still
                        // needs them — wrap CustomPaint in a Consumer that
                        // watches just `(zoom, panOffset)` so panning
                        // rebuilds only this CustomPaint subtree (a
                        // ~1-widget tree), and the rest of the UI is
                        // untouched.
                        child: Consumer(
                          builder: (context, ref, _) {
                            // Watch viewport + imageCache + pages so the
                            // painter rebuilds on pan/zoom, when a new
                            // asset image is decoded, AND when the eraser
                            // / draw / undo commits a new pages map. The
                            // chrome's parent select excludes ALL of
                            // those (they tick at 20-120 Hz during
                            // interaction), so this Consumer is the
                            // *only* widget that rebuilds for those
                            // changes.
                            ref.watch(canvasProvider.select((s) =>
                                s == null
                                    ? const (zoom: 1.0, panOffset: Offset.zero)
                                    : (zoom: s.zoom, panOffset: s.panOffset)));
                            ref.watch(canvasProvider.select(
                                (s) => s?.imageCache));
                            ref.watch(canvasProvider.select(
                                (s) => s?.pages));
                            // Read full state fresh — the parent's
                            // canvasState (closure) has stale fields
                            // because parent didn't rebuild for any of
                            // the above. Use `s.currentPage` (computed
                            // from the live `pages` map) as the painter's
                            // pageData; falling back to the parent's
                            // captured `currentPage` only for the very
                            // first paint when ref.read returns null.
                            final s = ref.read(canvasProvider) ?? canvasState;
                            final livePage = s.currentPage ?? currentPage;
                            return CustomPaint(
                              painter: CanvasRenderEngine(
                                pageData: livePage,
                                // Pass nothing as the snapshot — the painter
                                // resolves the active stroke via the getter
                                // every frame so a captured snapshot can
                                // never go stale between widget rebuilds.
                                activeStroke: null,
                                activeStrokeGetter: () {
                                  // Notifier always wins when it has points
                                  // (live drawing). Fall back to Riverpod's
                                  // activeStroke (carries the very first
                                  // point committed via startStroke before
                                  // the first PointerMove). Either may be
                                  // null between strokes.
                                  if (_activeStrokeNotifier.points.isNotEmpty) {
                                    return _activeStrokeNotifier.points;
                                  }
                                  final liveS = ref.read(canvasProvider);
                                  final stroke = liveS?.activeStroke;
                                  if (stroke != null && stroke.isNotEmpty) {
                                    return stroke;
                                  }
                                  return null;
                                },
                                activeToolType: _toolTypeString(s.currentTool),
                                activeColor: s.toolSettings.color,
                                activeWidth: s.toolSettings.strokeWidth,
                                lassoSelection: s.lassoSelection,
                                // Live transform during drag/rotate/scale —
                                // bypasses Riverpod so the page repaints
                                // without rebuilding the widget tree.
                                // ALWAYS pass the callback (it returns
                                // null when no gesture is in flight) —
                                // otherwise the CustomPaint, captured
                                // before _lassoTransformNotifier.begin()
                                // ran, would have a null callback for
                                // the entire gesture and the painter
                                // would fall back to stale Riverpod
                                // state.
                                liveLassoTransform: () =>
                                    _lassoTransformNotifier.isActive
                                        ? _lassoTransformNotifier.snapshot()
                                        : null,
                                liveElementTransform: () => _elementTransformNotifier.isActive
                                    ? (
                                          elementId: _elementTransformNotifier.elementId!,
                                          dragOffset: _elementTransformNotifier.dragOffset,
                                          rotationDelta: _elementTransformNotifier.rotationDelta,
                                          scaleW: _elementTransformNotifier.scaleW,
                                          scaleH: _elementTransformNotifier.scaleH,
                                        )
                                    : null,
                                lassoPath: _lassoPathNotifier.isActive && _lassoPathNotifier.points.isNotEmpty
                                    ? _lassoPathNotifier.points
                                    : (s.lassoPath.isNotEmpty ? s.lassoPath : null),
                                lassoPathGetter: _lassoPathNotifier.isActive
                                    ? () => _lassoPathNotifier.points
                                    : null,
                                laserTrailGetter: () =>
                                    _laserStrokeNotifier.points,
                                shapePreview: (s.shapeStartPos != null && s.shapeEndPos != null)
                                    ? (s.shapeStartPos!, s.shapeEndPos!, s.toolSettings.shapeType)
                                    : null,
                                recognizedShapePreview: s.recognizedShape,
                                zoom: s.zoom,
                                panOffset: s.panOffset,
                                imageCache: s.imageCache,
                                repaintNotifier: _repaintNotifier,
                              ),
                              // willChange: true tells Skia "do NOT
                              // bother rasterizing this layer to a
                              // GPU texture cache between frames" —
                              // ESSENTIAL during pan. With
                              // willChange:false + shouldRepaint=true
                              // (panOffset changes every frame),
                              // Flutter would create+invalidate the
                              // texture cache on every paint, paying
                              // GPU upload cost for nothing. Our
                              // own ui.Picture cache (in render_engine)
                              // already memoises the drawing commands
                              // at the right granularity (per
                              // pageData/zoom-bucket) — Skia's
                              // post-transform raster cache is
                              // counterproductive on a panning canvas.
                              // isComplex:true was hinting Skia to
                              // cache, which doubled down on the same
                              // mistake — also removed.
                              willChange: true,
                              size: canvasSize,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Eraser cursor — wrapped via Positioned.fill + inner
              // Stack so the cursor's `Positioned` (returned by
              // `_buildEraserCursor`) sits directly under a Stack
              // ancestor as required (ParentDataWidget invariant).
              // Without the inner Stack, putting a Positioned inside a
              // bare Consumer breaks the outer Stack's layout and the
              // entire canvas subtree fails to render.
              //
              // The Consumer watches just (currentTool, eraserCursorPos)
              // — the parent's record select intentionally omits
              // eraserCursorPos (would force a chrome rebuild at
              // pointer rate). Without this Consumer the cursor stays
              // frozen and "teleports" only when something else
              // triggers a parent rebuild.
              Positioned.fill(
                child: IgnorePointer(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final eraserState =
                          ref.watch(canvasProvider.select((s) =>
                              s == null
                                  ? null
                                  : (
                                      tool: s.currentTool,
                                      pos: s.eraserCursorPos,
                                    )));
                      if (eraserState == null ||
                          !_isEraserTool(eraserState.tool) ||
                          eraserState.pos == null) {
                        return const SizedBox.shrink();
                      }
                      final fullState = ref.read(canvasProvider);
                      if (fullState == null) {
                        return const SizedBox.shrink();
                      }
                      return Stack(
                        children: [
                          _buildEraserCursor(fullState, canvasSize),
                        ],
                      );
                    },
                  ),
                ),
              ),

              // Transform handles for selected elements + lasso handles.
              // Wrapped in a Consumer that watches (zoom, panOffset) so
              // the handles re-anchor as the viewport pans/zooms — the
              // chrome's parent select EXCLUDES those fields (perf), so
              // without this Consumer the handles would freeze in their
              // build-time screen positions during a pan and only catch
              // up when something else triggered a parent rebuild ("the
              // dashed border stays put but the corner circles move in
              // jumps"). _elementTransformNotifier handles the
              // drag/rotate/resize live values via its own listenable.
              Positioned.fill(
                child: Consumer(
                  builder: (_, ref2, __) {
                    ref2.watch(canvasProvider.select((s) => s == null
                        ? const (zoom: 1.0, panOffset: Offset.zero)
                        : (zoom: s.zoom, panOffset: s.panOffset)));
                    final live = ref2.read(canvasProvider) ?? canvasState;
                    return ListenableBuilder(
                      listenable: _elementTransformNotifier,
                      builder: (_, __) => Stack(
                        children: _buildTransformHandles(live, canvasSize),
                      ),
                    );
                  },
                ),
              ),
              Positioned.fill(
                child: Consumer(
                  builder: (_, ref2, __) {
                    ref2.watch(canvasProvider.select((s) => s == null
                        ? const (zoom: 1.0, panOffset: Offset.zero)
                        : (zoom: s.zoom, panOffset: s.panOffset)));
                    final live = ref2.read(canvasProvider) ?? canvasState;
                    return ListenableBuilder(
                      listenable: _lassoTransformNotifier,
                      builder: (_, __) => Stack(
                        children: [
                          ..._buildLassoHandles(live, canvasSize),
                          if (live.lassoSelection != null)
                            _buildFloatingSelectionActions(live, canvasSize),
                        ],
                      ),
                    );
                  },
                ),
              ),

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
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
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

    // Live override: while the user is dragging / rotating / resizing this
    // very element, _elementTransformNotifier holds the deltas. Apply
    // them so the bounding box and rotation handle stay glued to the
    // moving content instead of snapping at pan-end.
    final liveActive = _elementTransformNotifier.isActive &&
        _elementTransformNotifier.elementId == state.selectedElementId;
    if (liveActive) {
      final dx = _elementTransformNotifier.dragOffset.dx;
      final dy = _elementTransformNotifier.dragOffset.dy;
      final sw = _elementTransformNotifier.scaleW;
      final sh = _elementTransformNotifier.scaleH;
      final newW = pageBounds!.width * sw;
      final newH = pageBounds!.height * sh;
      // Resize keeps the top-left corner fixed (matches handle math),
      // then drag offset is added.
      pageBounds = Rect.fromLTWH(
        pageBounds!.left + dx,
        pageBounds!.top + dy,
        newW,
        newH,
      );
      rotation += _elementTransformNotifier.rotationDelta;
    }

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

    final isFlipped = element.map(
      stroke: (_) => false,
      text: (_) => false,
      image: (e) => e.data.flipHorizontal,
      shape: (_) => false,
    );

    final elementId = state.selectedElementId!;

    return [
      ImageHandleOverlay(
        bounds: screenRect,
        rotation: rotation,
        isLocked: isLocked,
        hasComment: hasComment,
        isFlipped: isFlipped,
        onDragStart: () {
          // Push undo once (Riverpod), then switch to the local notifier
          // for the rest of the gesture so per-frame moves don't fire
          // state updates.
          ref.read(canvasProvider.notifier).startDragElement(elementId);
          _elementTransformNotifier.begin(elementId);
        },
        onDragEnd: () => _commitElementTransform(elementId, state, canvasSize),
        onMove: (delta) {
          final pageDelta = delta / (state.zoom * _getRenderScale(state, canvasSize));
          // Local-only — Riverpod catches up at pan-end via onDragEnd.
          _elementTransformNotifier.translate(pageDelta);
        },
        onResize: (newBounds) {
          // Convert the new screen bounds to a (sw, sh) multiplicative
          // factor relative to the original pageBounds the notifier was
          // started with.
          final origScreenTL = _toScreenCoords(
              pageBounds!.topLeft, state, canvasSize);
          final origScreenBR = _toScreenCoords(
              pageBounds!.bottomRight, state, canvasSize);
          final origScreenRect = Rect.fromPoints(origScreenTL, origScreenBR);
          final sw = (origScreenRect.width <= 0)
              ? 1.0
              : (newBounds.width / origScreenRect.width);
          final sh = (origScreenRect.height <= 0)
              ? 1.0
              : (newBounds.height / origScreenRect.height);
          // Translate the top-left if it moved (e.g. resize from top/left).
          final dx = (newBounds.left - origScreenRect.left) /
              (state.zoom * _getRenderScale(state, canvasSize));
          final dy = (newBounds.top - origScreenRect.top) /
              (state.zoom * _getRenderScale(state, canvasSize));
          _elementTransformNotifier.setScale(sw, sh);
          _elementTransformNotifier.translate(
              Offset(dx - _elementTransformNotifier.dragOffset.dx,
                  dy - _elementTransformNotifier.dragOffset.dy));
        },
        onRotate: (angle) {
          _elementTransformNotifier.rotateBy(angle);
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
        onCopy: isImage ? () {
          ref.read(canvasProvider.notifier).copyElement(elementId);
          // Also push the PNG to the system clipboard so the user can
          // paste it into another app.
          _copyImageElementToSystemClipboard(elementId);
          _toast('Immagine copiata');
        } : null,
        onCut: isImage ? () {
          ref.read(canvasProvider.notifier).cutElement(elementId);
          _toast('Immagine tagliata');
        } : null,
        onFlipHorizontal: isImage ? () {
          ref.read(canvasProvider.notifier).flipImageElement(elementId);
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
      builder: (ctx) => CropDialog(
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
    final originalSel = state.lassoSelection!;
    // Same live-transform override as _buildLassoHandles — keeps the
    // floating action bar attached to the moving selection during a
    // drag/rotate/scale gesture.
    final sel = _lassoTransformNotifier.isActive
        ? originalSel.copyWith(
            dragOffset: _lassoTransformNotifier.dragOffset,
            rotation: _lassoTransformNotifier.rotation,
            scale: _lassoTransformNotifier.scale,
          )
        : originalSel;
    final center = sel.bounds.center;
    final scaledBounds = Rect.fromCenter(
      center: center,
      width: sel.bounds.width * sel.scale,
      height: sel.bounds.height * sel.scale,
    ).translate(sel.dragOffset.dx, sel.dragOffset.dy);

    // Position below the selection
    final screenBottom = _toScreenCoords(scaledBounds.bottomCenter, state, canvasSize);

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
                // If the selection is a single image, also push its PNG
                // to the system clipboard so the user can paste it elsewhere.
                final sel = state.lassoSelection;
                if (sel != null && sel.selectedIds.length == 1) {
                  final page = state.currentPage;
                  final id = sel.selectedIds.first;
                  final el = page?.layers.content.where((e) => e.map(
                    stroke: (s) => s.id, text: (t) => t.id,
                    image: (i) => i.id, shape: (s) => s.id,
                  ) == id).firstOrNull;
                  final isImg = el?.map(
                    stroke: (_) => false, text: (_) => false,
                    image: (_) => true, shape: (_) => false,
                  ) ?? false;
                  if (isImg) _copyImageElementToSystemClipboard(id);
                }
                _toast('Selezione copiata');
              }),
              _FloatingActionBtn(Icons.content_cut_rounded, 'Taglia', () {
                ref.read(canvasProvider.notifier).cutSelection();
                _toast('Selezione tagliata');
              }),
              _FloatingActionBtn(Icons.copy_all_rounded, 'Duplica', () {
                ref.read(canvasProvider.notifier).duplicateSelection();
                _toast('Selezione duplicata');
              }),
              // Quick color picker — restores the workflow from the
              // previous UI (select stroke → tap color to recolor).
              _FloatingActionBtn(Icons.palette_rounded, 'Cambia colore',
                  () => _showSelectionColorPicker()),
              if (state.clipboard != null)
                _FloatingActionBtn(Icons.paste_rounded, 'Incolla', () {
                  ref.read(canvasProvider.notifier).paste();
                }),
              _FloatingActionBtn(Icons.delete_outline, 'Elimina', () {
                ref.read(canvasProvider.notifier).deleteSelection();
              }, color: Colors.red),
              // Less-used actions folded into a "more" menu (Rifletti H/V,
              // Screenshot, Incolla in altro notebook).
              _FloatingActionBtn(Icons.more_horiz, 'Altro',
                  () => _showSelectionMoreMenu(state)),
              _FloatingActionBtn(Icons.close, null, () {
                ref.read(canvasProvider.notifier).clearSelection();
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// Quick color picker for an existing lasso selection — restores the
  /// "select stroke → tap colour to recolour" workflow that the previous
  /// UI had via the toolbar palette.
  Future<void> _showSelectionColorPicker() async {
    final presets = ref.read(presetColorsProvider);
    if (!mounted) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Cambia colore selezione',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final c in presets)
                    GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(c),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: const Color(0x1A000000), width: 1),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      ref.read(canvasProvider.notifier).changeSelectionColor(picked);
    }
  }

  /// "Altro" menu for lass selection — surfaces the less-used actions
  /// (flip H/V, screenshot to clipboard, paste into another notebook).
  Future<void> _showSelectionMoreMenu(CanvasState state) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.flip_rounded),
              title: const Text('Rifletti orizzontalmente'),
              onTap: () {
                Navigator.of(ctx).pop();
                ref.read(canvasProvider.notifier).flipSelectionHorizontal();
              },
            ),
            ListTile(
              leading: Transform.rotate(
                angle: 1.5708,
                child: const Icon(Icons.flip_rounded),
              ),
              title: const Text('Rifletti verticalmente'),
              onTap: () {
                Navigator.of(ctx).pop();
                ref.read(canvasProvider.notifier).flipSelectionVertical();
              },
            ),
            ListTile(
              leading: const Icon(Icons.screenshot_rounded),
              title: const Text('Copia come immagine'),
              onTap: () {
                Navigator.of(ctx).pop();
                _copySelectionAsScreenshot();
              },
            ),
            if (state.clipboard != null)
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('Incolla in un altro taccuino…'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _pasteInAnotherNotebook(context, state.clipboard!);
                },
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildLassoHandles(CanvasState state, Size canvasSize) {
    final originalSel = state.lassoSelection;
    if (originalSel == null) return [];

    // During drag/rotate/scale the local LassoTransformNotifier holds the
    // live values. Riverpod state stays at the *initial* transform until
    // pointer-up, so reading sel.dragOffset/scale/rotation directly here
    // would freeze the handles in place while the canvas content moved
    // underneath — the visible "lag". Override with the live values.
    final sel = _lassoTransformNotifier.isActive
        ? originalSel.copyWith(
            dragOffset: _lassoTransformNotifier.dragOffset,
            rotation: _lassoTransformNotifier.rotation,
            scale: _lassoTransformNotifier.scale,
          )
        : originalSel;

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
              _lassoTransformNotifier.begin(
                dragOffset: sel.dragOffset,
                rotation: sel.rotation,
                scale: sel.scale,
              );
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
                _lassoTransformNotifier.setScale(newScale.clamp(0.1, 10.0));
              }
            },
            onPanEnd: (_) => _commitLassoTransform(),
            onPanCancel: _commitLassoTransform,
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
                onPanStart: (_) {
                  _lassoTransformNotifier.begin(
                    dragOffset: sel.dragOffset,
                    rotation: sel.rotation,
                    scale: sel.scale,
                  );
                },
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
                  _lassoTransformNotifier.rotateBy(deltaAngle);
                },
                onPanEnd: (_) => _commitLassoTransform(),
                onPanCancel: _commitLassoTransform,
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

  /// Commit the locally-tracked element transform back to Riverpod once,
  /// at the end of a drag/rotate/resize gesture. During the gesture
  /// _elementTransformNotifier received every delta; here Riverpod
  /// catches up exactly once.
  void _commitElementTransform(
      String elementId, CanvasState state, Size canvasSize) {
    if (!_elementTransformNotifier.isActive) return;
    final dragOffset = _elementTransformNotifier.dragOffset;
    final rotationDelta = _elementTransformNotifier.rotationDelta;
    final sw = _elementTransformNotifier.scaleW;
    final sh = _elementTransformNotifier.scaleH;
    _elementTransformNotifier.end();

    final notifier = ref.read(canvasProvider.notifier);
    // Resize: derive the new page-bounds from the original element
    // bounds + accumulated drag + scale.
    final page = state.currentPage;
    if (page == null) return;
    final element = page.layers.content.where((e) {
      final id = e.map(
          stroke: (s) => s.id,
          text: (t) => t.id,
          image: (i) => i.id,
          shape: (s) => s.id);
      return id == elementId;
    }).firstOrNull;
    if (element == null) return;
    Rect? origBounds;
    element.map(
      stroke: (_) {},
      text: (t) =>
          origBounds = Rect.fromLTWH(t.data.x, t.data.y, t.data.width, t.data.height),
      image: (i) =>
          origBounds = Rect.fromLTWH(i.data.x, i.data.y, i.data.width, i.data.height),
      shape: (s) => origBounds =
          Rect.fromPoints(Offset(s.data.x1, s.data.y1), Offset(s.data.x2, s.data.y2)),
    );
    if (origBounds == null) return;

    // Apply scale (if any) first, then translate.
    final scaledRect = Rect.fromLTWH(
      origBounds!.left,
      origBounds!.top,
      origBounds!.width * sw,
      origBounds!.height * sh,
    );
    final newBounds = scaledRect.translate(dragOffset.dx, dragOffset.dy);

    // Single Riverpod update for the whole gesture (handle the scale by
    // resizing first if needed, then move + rotate).
    if (sw != 1.0 || sh != 1.0) {
      notifier.resizeElement(elementId, scaledRect);
    }
    if (dragOffset != Offset.zero) {
      notifier.moveElement(elementId, dragOffset);
    }
    if (rotationDelta != 0.0) {
      notifier.rotateElement(elementId, rotationDelta);
    }
    // Suppress unused-var warning in the no-op branch below.
    // ignore: unused_local_variable
    final _ = newBounds;
  }

  /// Snapshot the live transform from [_lassoTransformNotifier] back into
  /// Riverpod and clear the notifier. Called from drag/rotate/scale
  /// onPanEnd / onPanCancel + the drag-selection branch of _onPointerUp.
  /// Riverpod fires exactly once per gesture instead of once per
  /// pointer-move event.
  void _commitLassoTransform() {
    if (!_lassoTransformNotifier.isActive) return;
    final snap = _lassoTransformNotifier.snapshot();
    ref.read(canvasProvider.notifier).commitSelectionTransform(
          dragOffset: snap.dragOffset,
          rotation: snap.rotation,
          scale: snap.scale,
        );
    _lassoTransformNotifier.end();
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
          const PopupMenuItem(value: 'copy_screenshot', child: _MenuRow(Icons.screenshot_rounded, 'Copia come immagine', null)),
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
        const PopupMenuItem(value: 'insert_camera', child: _MenuRow(Icons.camera_alt_rounded, 'Scatta foto', null)),
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
        case 'copy': notifier.copySelection(); _toast('Selezione copiata'); break;
        case 'copy_screenshot': _copySelectionAsScreenshot(); break;
        case 'cut': notifier.cutSelection(); _toast('Selezione tagliata'); break;
        case 'duplicate_sel': notifier.duplicateSelection(); _toast('Selezione duplicata'); break;
        case 'delete_sel': notifier.deleteSelection(); break;
        case 'paste': notifier.paste(at: pagePos); break;
        case 'paste_clipboard_image': _pasteSystemClipboardImageOnly(); break;
        case 'select_all': notifier.selectAll(); break;
        case 'clear_page': _confirmClearPage(); break;
        case 'insert_image': _pickAndInsertImage(pagePos); break;
        case 'insert_camera': _captureAndInsertImage(pagePos); break;
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

  /// Render a single page to a PNG [Uint8List] at the given [scale].
  Future<Uint8List?> _renderPageToPng(PageData page, Map<String, ui.Image> imageCache, {double scale = 2.0}) async {
    final w = page.width;
    final h = page.height;
    final renderW = (w * scale).round();
    final renderH = (h * scale).round();
    if (renderW <= 0 || renderH <= 0) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w * scale, h * scale));
    canvas.scale(scale);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);

    final engine = CanvasRenderEngine(
      pageData: page,
      zoom: 1.0,
      panOffset: Offset.zero,
      imageCache: imageCache,
    );
    engine.paintPage(canvas, Size(w, h), 1.0, Offset.zero);

    final picture = recorder.endRecording();
    final img = await picture.toImage(renderW, renderH);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return byteData?.buffer.asUint8List();
  }

  /// Resolve the chapter the user means by "capitolo corrente". Prefers
  /// the navigator filter ([CanvasState.activeChapterId]) but falls back
  /// to the chapterId of the page currently under the viewport so the
  /// "all pages" view still exports a meaningful chapter.
  Chapter? _resolveActiveChapter(CanvasState state) {
    String? chId = state.activeChapterId;
    if (chId == null) {
      final idx = state.currentPageIndex;
      if (idx >= 0 && idx < state.document.pages.length) {
        chId = state.document.pages[idx].chapterId;
      }
    }
    if (chId == null) return null;
    return state.metadata.chapters
        .cast<Chapter?>()
        .firstWhere((c) => c?.id == chId, orElse: () => null);
  }

  /// Return every [PageEntry] that belongs to [chapter], using the same
  /// OR rule as the collector (PageEntry.chapterId match OR pageIds
  /// membership) so the count shown in the dialog and the pages exported
  /// stay in sync even after a heal pass truncated one side.
  List<PageEntry> _chapterPageEntries(CanvasState state, Chapter chapter) {
    final pageIds = chapter.pageIds.toSet();
    return state.document.pages
        .where((e) =>
            e.chapterId == chapter.id || pageIds.contains(e.pageId))
        .toList();
  }

  /// Sanitise a string for use inside a filename on every platform we
  /// ship on (Windows is the strict one: no `\ / : * ? " < > |` and no
  /// trailing dots or spaces). Returns a non-empty placeholder when
  /// nothing survives the filter.
  String _sanitiseForFilename(String raw) {
    var out = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    while (out.endsWith('.') || out.endsWith(' ')) {
      out = out.substring(0, out.length - 1).trimRight();
    }
    return out.isEmpty ? 'Quaderno' : out;
  }

  /// Build the suggested export filename. For chapter scope we append
  /// ` - <chapter title>` so exports from different chapters don't
  /// collide in the user's downloads folder.
  String _exportFilename(
      CanvasState state, _ExportScope scope, String extension) {
    final base = _sanitiseForFilename(state.metadata.title);
    switch (scope) {
      case _ExportScope.currentPage:
        return '$base - pag. ${state.currentPageIndex + 1}.$extension';
      case _ExportScope.currentChapter:
        final ch = _resolveActiveChapter(state);
        if (ch != null && ch.title.trim().isNotEmpty) {
          final chTitle = _sanitiseForFilename(ch.title);
          return '$base - $chTitle.$extension';
        }
        return '$base.$extension';
      case _ExportScope.entireNotebook:
        return '$base.$extension';
    }
  }

  /// Collect the pages to export based on user-chosen [selection].
  /// For currentChapter, applies the optional 1-based inclusive range.
  /// For entireNotebook with chapterSeparators, see [_collectExportPagesWithSeparators].
  List<PageData> _collectExportPages(
      CanvasState state, _ExportSelection selection) {
    switch (selection.scope) {
      case _ExportScope.currentPage:
        final p = state.currentPage;
        return p != null ? [p] : [];
      case _ExportScope.currentChapter:
        final chapter = _resolveActiveChapter(state);
        if (chapter == null) {
          final p = state.currentPage;
          debugPrint('[Export] currentChapter fallback to currentPage: '
              'no chapter id resolvable');
          return p != null ? [p] : [];
        }
        final entries = _chapterPageEntries(state, chapter);
        final all = entries
            .map((e) => state.pages[e.fileName])
            .whereType<PageData>()
            .toList();
        // Apply range slice if provided (1-based, inclusive on both ends)
        final start = (selection.rangeStart ?? 1).clamp(1, all.length);
        final end = (selection.rangeEnd ?? all.length).clamp(start, all.length);
        final result = all.sublist(start - 1, end);
        debugPrint('[Export] currentChapter ${chapter.id}: '
            'pages=${all.length}, range=$start..$end, exporting=${result.length}');
        return result;
      case _ExportScope.entireNotebook:
        return state.document.pages
            .map((e) => state.pages[e.fileName])
            .whereType<PageData>()
            .toList();
    }
  }

  /// Group every page of the notebook by chapter, in document order.
  /// Returns a list of (chapterTitle, pages) — chapterTitle is null for
  /// pages with no chapter assigned.
  List<({String? chapterTitle, List<PageData> pages})>
      _groupPagesByChapter(CanvasState state) {
    final chaptersById = {
      for (final c in state.metadata.chapters) c.id: c,
    };
    final groups = <({String? chapterTitle, List<PageData> pages})>[];
    String? currentTitle;
    List<PageData> bucket = [];
    void flush() {
      if (bucket.isNotEmpty) {
        groups.add((chapterTitle: currentTitle, pages: bucket));
      }
    }
    for (final entry in state.document.pages) {
      final pageData = state.pages[entry.fileName];
      if (pageData == null) continue;
      final chTitle = chaptersById[entry.chapterId]?.title;
      if (chTitle != currentTitle) {
        flush();
        bucket = [];
        currentTitle = chTitle;
      }
      bucket.add(pageData);
    }
    flush();
    return groups;
  }

  /// Anchor rect for the iPad share-sheet popover. SharePlus rejects a
  /// zero rect with "sharePositionOrigin must be non-zero and within
  /// coordinates of source view". Use a small box at the screen centre.
  Rect _shareOriginRect() {
    final size = MediaQuery.of(context).size;
    final cx = size.width / 2;
    final cy = size.height / 2;
    return Rect.fromCenter(center: Offset(cx, cy), width: 40, height: 40);
  }

  /// Save or share a file cross-platform.
  /// On iOS/macOS, uses the system share sheet (FilePicker.saveFile is broken).
  /// On other platforms, uses FilePicker.saveFile.
  Future<void> _saveOrShare(String fileName, Uint8List data, String mimeType) async {
    if (io.Platform.isIOS || io.Platform.isMacOS) {
      final dir = await io.Directory.systemTemp.createTemp('handwriter_export');
      final file = io.File('${dir.path}/$fileName');
      await file.writeAsBytes(data, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mimeType)],
          subject: fileName,
          // iPad requires a non-zero anchor rect for the share-sheet
          // popover; SharePlus throws "PlatformException(error,
          // sharePositionOrigin must be non-zero...)" otherwise. Use
          // the centre of the screen — it's always within the view.
          sharePositionOrigin: _shareOriginRect(),
        ),
      );
    } else {
      final ext = fileName.split('.').last;
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Salva $fileName',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: [ext],
      );
      if (savePath != null) {
        await io.File(savePath).writeAsBytes(data, flush: true);
      }
    }
  }

  /// Show the export scope picker, then export as PNG (single page) or
  /// a series of PNGs (multi-page → share sheet with multiple files).
  Future<void> _exportAsPng() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;

    final selection = await _showExportScopeDialog(
      singlePageLabel: 'Pagina corrente (PNG)',
      chapterLabel: 'Capitolo corrente',
      notebookLabel: 'Quaderno intero',
    );
    if (selection == null) return;

    final pages = _collectExportPages(state, selection);
    if (pages.isEmpty) return;

    try {
      if (pages.length == 1) {
        final pngBytes = await _renderPageToPng(pages.first, state.imageCache);
        if (pngBytes == null) return;
        final fileName = '${state.metadata.title}_p${state.currentPageIndex + 1}.png';
        await _saveOrShare(fileName, pngBytes, 'image/png');
      } else {
        // Multiple pages → write to temp dir, share all
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Esportazione ${pages.length} pagine...')),
        );
        final dir = await io.Directory.systemTemp.createTemp('handwriter_export');
        final files = <XFile>[];
        for (var i = 0; i < pages.length; i++) {
          final pngBytes = await _renderPageToPng(pages[i], state.imageCache);
          if (pngBytes == null) continue;
          final f = io.File('${dir.path}/${state.metadata.title}_p${i + 1}.png');
          await f.writeAsBytes(pngBytes, flush: true);
          files.add(XFile(f.path, mimeType: 'image/png'));
        }
        if (files.isNotEmpty) {
          if (io.Platform.isIOS || io.Platform.isMacOS) {
            await SharePlus.instance.share(
              ShareParams(
                files: files,
                subject: state.metadata.title,
                sharePositionOrigin: _shareOriginRect(),
              ),
            );
          } else {
            // Desktop: let user pick folder, save all
            final savePath = await FilePicker.platform.getDirectoryPath(
              dialogTitle: 'Scegli cartella per le ${files.length} immagini',
            );
            if (savePath != null) {
              for (final xf in files) {
                final name = xf.path.split('/').last.split('\\').last;
                await io.File('$savePath/$name').writeAsBytes(await xf.readAsBytes());
              }
            }
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PNG esportato (${pages.length} ${pages.length == 1 ? "pagina" : "pagine"})')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore export: $e')));
      }
    }
  }

  Future<void> _exportAsPdf() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;

    final selection = await _showExportScopeDialog(
      singlePageLabel: 'Pagina corrente',
      chapterLabel: 'Capitolo corrente',
      notebookLabel: 'Quaderno intero',
    );
    if (selection == null) return;

    // Build the actual page list. For "entireNotebook + chapterSeparators"
    // we interleave a synthetic separator page before every chapter group.
    final pagePayload = <_PdfPagePayload>[];
    const scale = 2.0;
    int pageCountForSnack = 0;

    if (selection.scope == _ExportScope.entireNotebook &&
        selection.chapterSeparators) {
      final groups = _groupPagesByChapter(state);
      pageCountForSnack = groups.fold(
          0, (sum, g) => sum + g.pages.length + (g.chapterTitle != null ? 1 : 0));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generazione PDF ($pageCountForSnack pagine)...')),
        );
      }

      try {
        for (final group in groups) {
          // Use the FIRST page of the group as the size template
          final w = group.pages.isNotEmpty ? group.pages.first.width : 595.0;
          final h = group.pages.isNotEmpty ? group.pages.first.height : 842.0;
          if (group.chapterTitle != null) {
            final sepPng =
                await _renderChapterSeparatorPng(group.chapterTitle!, w, h, scale);
            if (sepPng != null) {
              pagePayload.add(_PdfPagePayload(
                width: w,
                height: h,
                pngBytes: sepPng,
              ));
            }
          }
          for (final page in group.pages) {
            final pngBytes =
                await _renderPageToPng(page, state.imageCache, scale: scale);
            if (pngBytes == null) continue;
            pagePayload.add(_PdfPagePayload(
              width: page.width,
              height: page.height,
              pngBytes: pngBytes,
            ));
          }
        }
        if (pagePayload.isEmpty) return;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Errore export PDF: $e')));
        }
        return;
      }
    } else {
      final pages = _collectExportPages(state, selection);
      if (pages.isEmpty) return;
      pageCountForSnack = pages.length;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Generazione PDF (${pages.length} ${pages.length == 1 ? "pagina" : "pagine"})...')),
        );
      }

      for (final page in pages) {
        final pngBytes = await _renderPageToPng(page, state.imageCache, scale: scale);
        if (pngBytes == null) continue;
        pagePayload.add(_PdfPagePayload(
          width: page.width,
          height: page.height,
          pngBytes: pngBytes,
        ));
      }
      if (pagePayload.isEmpty) return;
    }

    try {

      final pdfBytes = await compute(_buildPdfOnIsolate, pagePayload);
      final fileName = _exportFilename(state, selection.scope, 'pdf');
      await _saveOrShare(fileName, pdfBytes, 'application/pdf');

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'PDF esportato: $pageCountForSnack ${pageCountForSnack == 1 ? "pagina" : "pagine"}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore export PDF: $e')));
      }
    }
  }

  /// Render a "Capitolo: TITOLO" cover page for a chapter group.
  Future<Uint8List?> _renderChapterSeparatorPng(
      String chapterTitle, double pageWidth, double pageHeight, double scale) async {
    try {
      final renderW = (pageWidth * scale).round();
      final renderH = (pageHeight * scale).round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
          recorder, Rect.fromLTWH(0, 0, renderW.toDouble(), renderH.toDouble()));
      // Soft warm-paper background
      canvas.drawRect(
        Rect.fromLTWH(0, 0, renderW.toDouble(), renderH.toDouble()),
        Paint()..color = const Color(0xFFFAF7F1),
      );
      // Top accent bar
      canvas.drawRect(
        Rect.fromLTWH(0, 0, renderW.toDouble(), 8 * scale),
        Paint()..color = const Color(0xFFB66744),
      );
      // "CAPITOLO" eyebrow
      final eyebrow = TextPainter(
        text: TextSpan(
          text: 'CAPITOLO',
          style: TextStyle(
            color: const Color(0xFF6B6358),
            fontSize: 18 * scale,
            fontWeight: FontWeight.w600,
            letterSpacing: 4 * scale,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      eyebrow.paint(
        canvas,
        Offset(
          (renderW - eyebrow.width) / 2,
          renderH * 0.42,
        ),
      );
      // Chapter title
      final title = TextPainter(
        text: TextSpan(
          text: chapterTitle,
          style: TextStyle(
            color: const Color(0xFF1C1916),
            fontSize: 56 * scale,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            height: 1.15,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 3,
      )..layout(maxWidth: renderW * 0.8);
      title.paint(
        canvas,
        Offset(
          (renderW - title.width) / 2,
          renderH * 0.46,
        ),
      );
      // Decorative underline
      final underlineY = renderH * 0.46 + title.height + 24 * scale;
      final underlineW = 80 * scale;
      canvas.drawRect(
        Rect.fromLTWH(
            (renderW - underlineW) / 2, underlineY, underlineW, 3 * scale),
        Paint()..color = const Color(0xFFB66744),
      );

      final picture = recorder.endRecording();
      final image = await picture.toImage(renderW, renderH);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[Export] Failed to render chapter separator: $e');
      return null;
    }
  }

  /// Copy the current lasso selection as a screenshot to the system clipboard.
  Future<void> _copySelectionAsScreenshot() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final sel = state.lassoSelection;
    final page = state.currentPage;
    if (sel == null || page == null) return;

    try {
      final bounds = sel.bounds;
      if (bounds.isEmpty) return;

      // Render at 2x for retina quality
      const scale = 2.0;
      final renderW = (bounds.width * scale).round();
      final renderH = (bounds.height * scale).round();
      if (renderW <= 0 || renderH <= 0) return;

      // Build a temporary page containing only the selected elements,
      // translated so the selection bounds start at (0,0).
      final selectedElements = page.layers.content
          .where((e) => sel.selectedIds.contains(
                e.map(stroke: (s) => s.id, text: (t) => t.id,
                    image: (i) => i.id, shape: (s) => s.id)))
          .toList();

      final croppedPage = page.copyWith(
        layers: page.layers.copyWith(
          background: const BackgroundLayer(type: 'blank', color: 0xFFFFFFFF),
          content: selectedElements,
        ),
      );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, bounds.width * scale, bounds.height * scale));
      // White background
      canvas.drawRect(
        Rect.fromLTWH(0, 0, bounds.width * scale, bounds.height * scale),
        Paint()..color = Colors.white,
      );
      // Scale then translate so the selection bounds map to (0,0)
      canvas.scale(scale);
      canvas.translate(-bounds.left, -bounds.top);

      // Render only the selected elements via a temporary page
      final engine = CanvasRenderEngine(
        pageData: croppedPage,
        zoom: 1.0,
        panOffset: Offset.zero,
        imageCache: state.imageCache,
      );
      // paintPage applies its own translate(offset)+scale(scale), so pass
      // the negative bounds as offset and 1.0 as scale to avoid double-transform.
      engine.paintPage(
        canvas,
        Size(croppedPage.width, croppedPage.height),
        1.0,
        Offset.zero,
      );

      final picture = recorder.endRecording();
      final img = await picture.toImage(renderW, renderH);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      picture.dispose();
      if (byteData == null) return;

      final item = DataWriterItem();
      item.add(Formats.png(byteData.buffer.asUint8List()));
      await SystemClipboard.instance?.write([item]);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selezione copiata come immagine'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore copia immagine: $e')),
        );
      }
    }
  }

  /// Encode an image element to PNG and push it onto the system clipboard
  /// so it can be pasted into other apps. Fire-and-forget; UI toast is
  /// shown by the caller.
  Future<void> _copyImageElementToSystemClipboard(String elementId) async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final page = state.currentPage;
    if (page == null) return;
    final element = page.layers.content.where((e) {
      return e.map(stroke: (s) => s.id, text: (t) => t.id, image: (i) => i.id, shape: (s) => s.id) == elementId;
    }).firstOrNull;
    if (element == null) return;

    ImageData? imageData;
    element.map(
      stroke: (_) {}, text: (_) {},
      image: (i) => imageData = i.data,
      shape: (_) {},
    );
    if (imageData == null) return;

    final uiImage = state.imageCache[imageData!.assetPath];
    if (uiImage == null) return;
    try {
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return;
      final item = DataWriterItem();
      item.add(Formats.png(byteData.buffer.asUint8List()));
      await clipboard.write([item]);
    } catch (e) {
      debugPrint('[Canvas] System clipboard image write failed: $e');
    }
  }

  /// Small inline confirmation toast. Keeps a short duration so it doesn't
  /// obscure the canvas.
  Future<void> _pasteInAnotherNotebook(BuildContext ctx, CanvasClipboard clip) async {
    // Persist the clipboard globally so the target notebook can pick it up
    ref.read(crossNotebookClipboardProvider.notifier).state = clip;

    // Navigate back to library (pop canvas)
    Navigator.of(ctx).pop();
    // The library will show a banner; user taps a notebook to open it.
    // The cross-notebook clipboard is consumed by _restoreLastPosition.
  }

  void _toast(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Show a dialog for choosing export scope.
  Future<_ExportSelection?> _showExportScopeDialog({
    required String singlePageLabel,
    required String chapterLabel,
    required String notebookLabel,
  }) async {
    final state = ref.read(canvasProvider);
    final hasChapters = state != null && state.metadata.chapters.length > 1;
    final hasMultiplePages = state != null && state.document.pages.length > 1;

    // If only 1 page, skip dialog
    if (!hasMultiplePages) {
      return const _ExportSelection(scope: _ExportScope.currentPage);
    }

    final scope = await showDialog<_ExportScope>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Esporta'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _ExportScope.currentPage),
            child: ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(singlePageLabel),
              subtitle: Text('Pagina ${state.currentPageIndex + 1}'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          if (hasChapters)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, _ExportScope.currentChapter),
              child: ListTile(
                leading: const Icon(Icons.bookmark_outline),
                title: Text(chapterLabel),
                subtitle: Text(_currentChapterLabel(state)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _ExportScope.entireNotebook),
            child: ListTile(
              leading: const Icon(Icons.menu_book_rounded),
              title: Text(notebookLabel),
              subtitle: Text('${state.document.pages.length} pagine'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
    if (scope == null) return null;

    // Scope-specific extra prompts
    switch (scope) {
      case _ExportScope.currentPage:
        return const _ExportSelection(scope: _ExportScope.currentPage);

      case _ExportScope.currentChapter:
        // Ask range start/end if the chapter has more than 1 page
        final chapter = _resolveActiveChapter(state);
        final chPagesCount = chapter == null
            ? 1
            : _chapterPageEntries(state, chapter).length;
        if (chPagesCount <= 1) {
          return const _ExportSelection(scope: _ExportScope.currentChapter);
        }
        if (!mounted) return null;
        final range = await _promptPageRange(
          title: 'Esporta capitolo',
          subtitle: chapter?.title ?? 'Capitolo corrente',
          totalPages: chPagesCount,
        );
        if (range == null) return null;
        return _ExportSelection(
          scope: _ExportScope.currentChapter,
          rangeStart: range.$1,
          rangeEnd: range.$2,
        );

      case _ExportScope.entireNotebook:
        // If the notebook actually has chapters, offer the separator toggle
        if (!hasChapters) {
          return const _ExportSelection(scope: _ExportScope.entireNotebook);
        }
        if (!mounted) return null;
        final addSep = await _promptYesNo(
          title: 'Esporta quaderno intero',
          message: 'Inserire una pagina separatore prima di ogni capitolo?',
          yesLabel: 'Sì, con separatori',
          noLabel: 'No, solo le pagine',
          initialValue: true,
        );
        if (addSep == null) return null;
        return _ExportSelection(
          scope: _ExportScope.entireNotebook,
          chapterSeparators: addSep,
        );
    }
  }

  /// Page-range picker dialog: returns (start, end) inclusive 1-based or null.
  Future<(int, int)?> _promptPageRange({
    required String title,
    String? subtitle,
    required int totalPages,
  }) async {
    int start = 1;
    int end = totalPages;
    return showDialog<(int, int)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null) ...[
                  Text(subtitle, style: Theme.of(ctx).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                ],
                Text('Pagine totali: $totalPages',
                    style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 16),
                Text('Da pagina: $start',
                    style: Theme.of(ctx).textTheme.bodyMedium),
                Slider(
                  value: start.toDouble(),
                  min: 1,
                  max: totalPages.toDouble(),
                  divisions: totalPages - 1,
                  label: '$start',
                  onChanged: (v) => setSt(() {
                    start = v.round();
                    if (start > end) end = start;
                  }),
                ),
                Text('A pagina: $end',
                    style: Theme.of(ctx).textTheme.bodyMedium),
                Slider(
                  value: end.toDouble(),
                  min: 1,
                  max: totalPages.toDouble(),
                  divisions: totalPages - 1,
                  label: '$end',
                  onChanged: (v) => setSt(() {
                    end = v.round();
                    if (end < start) start = end;
                  }),
                ),
                const SizedBox(height: 8),
                Text('Saranno esportate ${end - start + 1} pagine ($start–$end)',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Annulla')),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, (start, end)),
                child: const Text('Esporta'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Yes/No picker — returns true/false or null on cancel.
  Future<bool?> _promptYesNo({
    required String title,
    required String message,
    required String yesLabel,
    required String noLabel,
    bool initialValue = true,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(noLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yesLabel),
          ),
        ],
      ),
    );
  }

  String _currentChapterLabel(CanvasState state) {
    // Resolve with the same fallback the collector uses so the dialog
    // count stays in sync with the number of pages the PDF will contain
    // (and so "all pages" view still shows a chapter name).
    final ch = _resolveActiveChapter(state);
    if (ch == null) return '';
    final count = _chapterPageEntries(state, ch).length;
    return '${ch.title} ($count ${count == 1 ? "pagina" : "pagine"})';
  }

  // ignore: unused_element
  Widget _buildPageNav(CanvasState canvasState) {
    final filteredPos = canvasState.currentFilteredIndex;
    final filteredCount = canvasState.filteredPageCount;
    final hasChapters = canvasState.metadata.chapters.isNotEmpty;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark
        ? Theme.of(context).colorScheme.surfaceContainer
        : Colors.grey.shade50;
    final navBorder = Theme.of(context).dividerColor;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Chapter tabs (only if chapters exist) ──
        if (hasChapters)
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: navBg,
              border: Border(top: BorderSide(color: navBorder, width: 0.5)),
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
                    // Tapping the active chapter must NOT deselect — always
                    // keep one chapter active so the bottom bar never falls
                    // into an empty state.
                    onSelected: (_) {
                      if (isActive) return;
                      ref.read(canvasProvider.notifier).setActiveChapter(chapter.id);
                    },
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
            color: isDark
                ? Theme.of(context).colorScheme.surfaceContainerHigh
                : Colors.white,
            border: Border(top: BorderSide(color: navBorder, width: 0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.view_carousel_outlined,
                    color: isDark ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.grey.shade700, size: 20),
                onPressed: () => _showPageManager(canvasState),
                tooltip: 'Gestione pagine',
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.chevron_left_rounded,
                    color: isDark ? Theme.of(context).colorScheme.onSurface : Colors.grey.shade800, size: 22),
                tooltip: 'Pagina precedente',
                onPressed: filteredPos > 0
                    ? () => ref.read(canvasProvider.notifier).prevPage()
                    : null,
                splashRadius: 18,
              ),
              Tooltip(
                message: 'Apri gestione pagine',
                child: GestureDetector(
                  onTap: () => _showPageManager(canvasState),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Theme.of(context).colorScheme.surfaceContainerHighest
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      filteredCount > 0 && filteredPos >= 0
                          ? '${filteredPos + 1} / $filteredCount'
                          : '— / $filteredCount',
                      style: TextStyle(
                          color: isDark ? Theme.of(context).colorScheme.onSurface : Colors.grey.shade800,
                          fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.chevron_right_rounded,
                    color: isDark ? Theme.of(context).colorScheme.onSurface : Colors.grey.shade800, size: 22),
                tooltip: 'Pagina successiva',
                onPressed: filteredPos >= 0 && filteredPos < filteredCount - 1
                    ? () => ref.read(canvasProvider.notifier).nextPage()
                    : null,
                splashRadius: 18,
              ),
              const Spacer(),
              // Zoom indicator — tap to reset to 200%
              Tooltip(
                message: 'Tocca per azzerare lo zoom (Ctrl+0)',
                child: GestureDetector(
                  onTap: () {
                    ref.read(canvasProvider.notifier).resetZoom();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: canvasState.zoom != 2.0
                          ? (isDark ? Colors.blue.shade900.withValues(alpha: 0.4) : Colors.blue.shade50)
                          : (isDark ? Theme.of(context).colorScheme.surfaceContainerHighest : Colors.grey.shade100),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${(canvasState.zoom * 100).round()}%',
                      style: TextStyle(
                        color: canvasState.zoom != 2.0
                            ? (isDark ? Colors.blue.shade200 : Colors.blue.shade700)
                            : (isDark ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.grey.shade600),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'v${AppConfig.appVersion}',
                style: TextStyle(
                  color: Theme.of(context).disabledColor,
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

  /// Right-click / long-press on a thumbnail in the bottom strip.
  /// Anchored at [pos] (global), shows quick actions on that page.
  void _showPageStripContextMenu(int pageNumber, Offset pos) async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    final pageIndex = pageNumber - 1;
    if (pageIndex < 0 || pageIndex >= state.document.pages.length) return;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        const PopupMenuItem(
          value: 'goto',
          child: Row(children: [
            Icon(Icons.open_in_new_rounded, size: 18),
            SizedBox(width: 12),
            Text('Vai alla pagina'),
          ]),
        ),
        const PopupMenuItem(
          value: 'duplicate',
          child: Row(children: [
            Icon(Icons.content_copy_rounded, size: 18),
            SizedBox(width: 12),
            Text('Duplica pagina'),
          ]),
        ),
        const PopupMenuItem(
          value: 'add_after',
          child: Row(children: [
            Icon(Icons.add_circle_outline_rounded, size: 18),
            SizedBox(width: 12),
            Text('Nuova pagina dopo'),
          ]),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline_rounded,
                size: 18, color: Colors.red.shade700),
            const SizedBox(width: 12),
            Text('Elimina pagina',
                style: TextStyle(color: Colors.red.shade700)),
          ]),
        ),
      ],
    );

    if (!mounted || action == null) return;
    final notifier = ref.read(canvasProvider.notifier);
    switch (action) {
      case 'goto':
        notifier.goToPage(pageIndex);
        break;
      case 'duplicate':
        notifier.duplicatePage(pageIndex);
        break;
      case 'add_after':
        notifier.goToPage(pageIndex);
        notifier.addPage();
        break;
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Eliminare la pagina?'),
            content: Text(
                'La pagina $pageNumber e tutto il suo contenuto verranno eliminati.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annulla')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Elimina'),
              ),
            ],
          ),
        );
        if (ok == true) notifier.deletePage(pageIndex);
        break;
    }
  }

  void _showPageManager(CanvasState canvasState) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => PageManagerSheet(initialState: canvasState),
    );
  }

  /// Center of the visible viewport mapped to page coordinates.
  Offset _visibleCenterPagePos(CanvasState state) {
    final size = MediaQuery.of(context).size;
    final center = Offset(size.width / 2, size.height / 2);
    final p = _toPageCoords(center, state, size);
    final pageW = state.currentPage?.width ?? 595;
    final pageH = state.currentPage?.height ?? 842;
    return Offset(p.dx.clamp(50, pageW - 50), p.dy.clamp(50, pageH - 50));
  }

  /// Export bottom sheet with PDF / PNG choices.
  void _showExportSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: HwThemeScope.of(context).paper0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('Esporta',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('Esporta come PDF'),
              onTap: () {
                Navigator.of(ctx).pop();
                _exportAsPdf();
              },
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Esporta come PNG'),
              onTap: () {
                Navigator.of(ctx).pop();
                _exportAsPng();
              },
            ),
            const Divider(height: 8),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Esporta come .ncnote (nativo)'),
              subtitle: const Text(
                  'Formato nativo, qualità vettoriale piena (per backup o trasferimento)'),
              onTap: () {
                Navigator.of(ctx).pop();
                _exportAsNcnote();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Native export: rebuild the .ncnote ZIP from current state and save it.
  /// Lossless — preserves vector strokes, text, shapes, images, symbols
  /// exactly as they're stored in memory.
  Future<void> _exportAsNcnote() async {
    final state = ref.read(canvasProvider);
    if (state == null) return;
    try {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Generazione .ncnote in corso…')),
        );
      }
      final bytes = sync_svc.SyncService.buildPackageBytes(
        metadata: state.metadata,
        document: state.document,
        pages: state.pages,
        assets: state.assetBytes.isNotEmpty ? state.assetBytes : null,
        symbolLibraries: state.symbolLibraries.isNotEmpty
            ? state.symbolLibraries.map((l) => l.toJson()).toList()
            : null,
      );
      final fileName =
          '${_sanitiseForFilename(state.metadata.title)}.ncnote';
      await _saveOrShare(fileName, bytes, 'application/zip');
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                '.ncnote esportato (${(bytes.length / 1024).toStringAsFixed(1)} KB)'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore export .ncnote: $e')));
      }
    }
  }

  /// Misc actions: insert image / change paper / save now.
  void _showMoreSheet(CanvasState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: HwThemeScope.of(context).paper0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('Altro',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Inserisci immagine…'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickAndInsertImage(_visibleCenterPagePos(state));
              },
            ),
            ListTile(
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('Cambia tipo di carta'),
              subtitle: Text(paperTypeLabel(state.currentPaperType)),
              onTap: () {
                Navigator.of(ctx).pop();
                _showPaperTypePicker(state);
              },
            ),
            if (state.isDirty)
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: const Text('Salva ora'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _save();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showPaperTypePicker(CanvasState state) {
    showModalBottomSheet(
      context: context,
      backgroundColor: HwThemeScope.of(context).paper0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('Tipo di carta',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final t in PaperType.values)
              ListTile(
                leading: Icon(
                  state.currentPaperType == t
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: state.currentPaperType == t
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(paperTypeLabel(t)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  ref.read(canvasProvider.notifier).setPaperType(t);
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
      case CanvasTool.calligraphy: return 'calligraphy';
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
    final iconWidget = Icon(icon, size: 20, color: c);
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
              iconWidget,
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

/// Group of keyboard-shortcut rows shown in the help dialog. Kept const so
/// the list of (combo, description) pairs can be declared inline without
/// per-build allocations.
class _ShortcutGroup extends StatelessWidget {
  final String title;
  final List<(String, String)> entries;
  const _ShortcutGroup(this.title, this.entries);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: Colors.blueGrey,
          ),
        ),
        const SizedBox(height: 6),
        ...entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade300, width: 0.5),
                    ),
                    child: Text(
                      e.$1,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(e.$2, style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PDF export — isolate payload
// ═══════════════════════════════════════════════════════════════

/// Payload passed to the background isolate that assembles the PDF.
///
/// Kept intentionally simple (only primitives + Uint8List) so it serializes
/// cleanly across the isolate boundary.
class _PdfPagePayload {
  final double width;
  final double height;
  final Uint8List pngBytes;
  const _PdfPagePayload({
    required this.width,
    required this.height,
    required this.pngBytes,
  });
}

/// Top-level entry point for [compute]: builds a PDF document from the
/// pre-rendered PNGs and returns the encoded bytes. Runs off the UI isolate.
Future<Uint8List> _buildPdfOnIsolate(List<_PdfPagePayload> payloads) async {
  final doc = pw.Document();
  for (final p in payloads) {
    final img = pw.MemoryImage(p.pngBytes);
    doc.addPage(
      pw.Page(
        pageFormat: pw_pdf.PdfPageFormat(
          p.width * pw_pdf.PdfPageFormat.point,
          p.height * pw_pdf.PdfPageFormat.point,
        ),
        margin: pw.EdgeInsets.zero,
        build: (ctx) => pw.Image(img, fit: pw.BoxFit.fill),
      ),
    );
  }
  return Uint8List.fromList(await doc.save());
}
