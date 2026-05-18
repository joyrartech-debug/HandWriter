// ═══════════════════════════════════════════════════════════════
//  page_manager_sheet.dart
//
//  Page Manager bottom sheet, reorderable thumbnail grid, and
//  multi-select action bar.  Extracted from canvas_screen.dart.
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/page_clipboard_provider.dart';
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:handwriter/ui/primitives/hw_button.dart';
import 'package:handwriter/ui/theme/hw_icons.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';

/// Single-line popup-menu entry — keeps menus compact and visually
/// aligned with HwTheme (HwIcon + ink color instead of Material's
/// 56-px-tall ListTile). Shared between the page 3-dot menu and the
/// chapter long-press menu.
Widget _hwMenuRow(HwPalette p, String icon, String label, {Color? color}) {
  final c = color ?? p.ink0;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      HwIcon(icon, size: 16, color: c),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(fontSize: 13, color: c)),
    ],
  );
}

/// Sentinel returned by [_pickChapter] when the user picks "Nessuno"
/// (i.e. remove chapter assignment).
const String _kRemoveChapter = '__remove__';

/// Themed chapter picker bottom sheet — replaces the previous
/// ListTile + Material-icon variants with HwIcon rows so the sheet
/// matches the rest of the page manager.
Future<String?> _pickChapter(
  BuildContext ctx,
  CanvasState s, {
  required String title,
  String? selectedChapterId,
}) {
  return showModalBottomSheet<String>(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (shCtx) {
      final p = HwThemeScope.of(shCtx);
      Widget row({
        required String icon,
        required String label,
        required VoidCallback onTap,
        bool selected = false,
        Color? color,
      }) {
        final c = color ?? p.ink0;
        return InkWell(
          onTap: onTap,
          child: Container(
            color: selected ? p.accentSoft : null,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                HwIcon(icon, size: 18, color: c),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: c,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (selected) HwIcon('check', size: 16, color: p.accent),
              ],
            ),
          ),
        );
      }

      return SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: p.paper0,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(HwTheme.rLg)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: p.paper3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  title,
                  style: TextStyle(
                    color: p.ink1,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              row(
                icon: 'x',
                label: 'Nessuno',
                color: p.ink2,
                onTap: () => Navigator.of(shCtx).pop(_kRemoveChapter),
              ),
              ...s.metadata.chapters.map((chapter) => row(
                    icon: 'chapter',
                    label: chapter.title,
                    selected: selectedChapterId == chapter.id,
                    onTap: () => Navigator.of(shCtx).pop(chapter.id),
                  )),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────
//  PageManagerSheet
// ─────────────────────────────────────────────────────────────

/// Modal bottom sheet for page management.
///
/// Owns the multi-page selection state so that the [SelectionActionBar]
/// can appear outside the scrollable grid area while reacting to the
/// same state updates.
class PageManagerSheet extends ConsumerStatefulWidget {
  final CanvasState initialState;
  /// Messenger captured from the canvas screen so SnackBars survive the
  /// bottom sheet route's lifecycle. On iPad, `ScaffoldMessenger.of(context)`
  /// resolved inside the sheet could resolve to a messenger that gets torn
  /// down with the sheet — leaving a "deleted" snackbar pinned to the
  /// bottom until the app is restarted.
  final ScaffoldMessengerState? parentMessenger;
  const PageManagerSheet({
    super.key,
    required this.initialState,
    this.parentMessenger,
  });

  @override
  ConsumerState<PageManagerSheet> createState() => _PageManagerSheetState();
}

class _PageManagerSheetState extends ConsumerState<PageManagerSheet> {
  /// Resolves the messenger to use for SnackBars. Prefers the parent
  /// messenger (captured before the sheet was opened) so the snackbar lives
  /// in the canvas screen's scope and respects its own duration timer even
  /// if the sheet is dismissed quickly.
  ScaffoldMessengerState get _messenger =>
      widget.parentMessenger ?? ScaffoldMessenger.of(context);

  @override
  void dispose() {
    // Clear any pending snackbars when the sheet closes — guards against
    // the iPad bug where a delete-page snackbar lingered past its 5s
    // duration and could only be cleared by restarting the app.
    widget.parentMessenger?.clearSnackBars();
    super.dispose();
  }

  /// Document indices of currently selected pages.
  final Set<int> _selected = {};

  /// Sticky selection mode — activated by tapping the checklist button.
  /// When true the grid is in selection mode even with zero pages
  /// selected (so the user can pick the first page with a single tap
  /// instead of having to long-press first).
  bool _selectionModeActive = false;

  bool get _isSelecting => _selectionModeActive || _selected.isNotEmpty;

  void _toggleSelectionMode() {
    setState(() {
      if (_selectionModeActive || _selected.isNotEmpty) {
        _selectionModeActive = false;
        _selected.clear();
      } else {
        _selectionModeActive = true;
      }
    });
  }

  void _toggleSelect(int docIdx) {
    setState(() {
      if (_selected.contains(docIdx)) {
        _selected.remove(docIdx);
      } else {
        _selected.add(docIdx);
      }
    });
  }

  void _clearSelection() => setState(() {
        _selected.clear();
        _selectionModeActive = false;
      });

  void _selectAll(List<int> visibleIndices) =>
      setState(() => _selected.addAll(visibleIndices));

  // ── Multi-page actions ──

  Future<void> _assignSelectedToChapter(CanvasState s) async {
    if (s.metadata.chapters.isEmpty) {
      _messenger.showSnackBar(
        const SnackBar(content: Text('Crea prima almeno un capitolo.')),
      );
      return;
    }
    final selectedId = await _pickChapter(
      context,
      s,
      title: 'Assegna capitolo (${_selected.length} pag.)',
    );
    if (selectedId == _kRemoveChapter) {
      ref.read(canvasProvider.notifier).assignPagesToChapter(_selected.toList(), null);
    } else if (selectedId != null) {
      ref.read(canvasProvider.notifier).assignPagesToChapter(_selected.toList(), selectedId);
    }
    _clearSelection();
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final ok = await _confirmDelete(
      context,
      count == 1
          ? 'Eliminare 1 pagina?'
          : 'Eliminare $count pagine?',
      'Questa azione non può essere annullata.',
    );
    if (!ok) return;
    ref.read(canvasProvider.notifier).deletePages(_selected.toList());
    _clearSelection();
  }

  /// Confirm destructive page actions with a simple AlertDialog.
  Future<bool> _confirmDelete(BuildContext ctx, String title, String body) async {
    final result = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: HwTheme.syncConflict),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _cutSelected(CanvasState s) {
    final pages = <PageData>[];
    final entries = <PageEntry>[];
    final sortedIdxs = _selected.toList()..sort();
    for (final idx in sortedIdxs) {
      if (idx < s.document.pages.length) {
        final entry = s.document.pages[idx];
        final page = s.pages[entry.fileName];
        if (page != null) {
          entries.add(entry);
          pages.add(page);
        }
      }
    }
    if (pages.isEmpty) return;
    ref.read(pageClipboardProvider.notifier).state = PageClipboard(
      pages: pages,
      entries: entries,
      sourceNotebookId: s.metadata.id,
    );
    ref.read(canvasProvider.notifier).deletePages(_selected.toList());
    _clearSelection();
    _messenger.showSnackBar(
      SnackBar(
        content: Text('${pages.length} pagine tagliate — aprire il notebook di destinazione per incollare.'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final liveState = ref.watch(canvasProvider) ?? widget.initialState;

    // Prune selected indices that no longer exist (after external deletions)
    final validIndices = liveState.document.pages.length;
    _selected.removeWhere((i) => i >= validIndices);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
      builder: (ctx, scrollController) {
        final visibleIndices = liveState.filteredPageIndices;
        final p = HwThemeScope.of(ctx);
        return Container(
          color: p.paper0,
          child: Column(
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                decoration: BoxDecoration(
                  color: p.paper3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_isSelecting) ...[
                        Text(
                          '${_selected.length} selezionate',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: p.ink0),
                        ),
                        const Spacer(),
                        HwButton(
                          label: 'Tutte',
                          onPressed: () => _selectAll(visibleIndices),
                        ),
                        const SizedBox(width: 4),
                        HwButton.icon(
                          icon: const HwIcon('x', size: 18),
                          tooltip: 'Annulla selezione',
                          onPressed: _clearSelection,
                        ),
                      ] else ...[
                        Text(
                          visibleIndices.length == liveState.pageCount
                              ? 'Pagine (${liveState.pageCount})'
                              : 'Pagine (${visibleIndices.length}/${liveState.pageCount})',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: p.ink0),
                        ),
                        const Spacer(),
                        // Jump to page by number
                        if (liveState.pageCount > 1)
                          HwButton.icon(
                            icon: const HwIcon('search', size: 18),
                            tooltip: 'Vai alla pagina…',
                            onPressed: () => _promptJumpToPage(ctx, liveState),
                          ),
                        HwButton.icon(
                          icon: HwIcon(
                            'check',
                            size: 18,
                            color: _selectionModeActive ? p.accent : null,
                          ),
                          tooltip: _selectionModeActive
                              ? 'Esci dalla selezione'
                              : 'Seleziona pagine',
                          onPressed: _toggleSelectionMode,
                        ),
                        // Paste pages from clipboard if available
                        if (ref.watch(pageClipboardProvider) != null)
                          HwButton.icon(
                            icon: HwIcon('copy', size: 18, color: p.accent),
                            tooltip: 'Incolla pagine',
                            onPressed: () {
                              final clip = ref.read(pageClipboardProvider);
                              if (clip == null) return;
                              ref.read(canvasProvider.notifier).pastePages(
                                pages: clip.pages,
                                entries: clip.entries,
                              );
                              ref.read(pageClipboardProvider.notifier).state = null;
                              _messenger.showSnackBar(
                                SnackBar(
                                  content: Text('${clip.pages.length} pagine incollate.'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        HwButton.icon(
                          icon: HwIcon('plus', size: 18, color: p.accent),
                          onPressed: () => ref.read(canvasProvider.notifier).addPage(),
                          tooltip: 'Aggiungi pagina',
                        ),
                        HwButton.icon(
                          icon: const HwIcon('x', size: 18),
                          tooltip: 'Chiudi',
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Chapter filter chips — drag to reorder (hidden during selection)
                  if (!_isSelecting && liveState.metadata.chapters.isNotEmpty)
                    SizedBox(
                      height: 38,
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(ctx).copyWith(
                          dragDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                          },
                        ),
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
                                // Tapping the active chapter no longer
                                // deselects it — leaving the user in the
                                // "no chapter" state was reachable only
                                // by accident and produced confusing
                                // page-strip / page-numbering behaviour
                                // (active filter empty, but document
                                // still scoped to the previous chapter).
                                // To switch chapters, the user picks a
                                // different one directly.
                                onSelected: isActive
                                    ? null
                                    : (_) => ref
                                        .read(canvasProvider.notifier)
                                        .setActiveChapter(chapter.id),
                                visualDensity: VisualDensity.compact,
                              );
                              return DragTarget<int>(
                                onWillAcceptWithDetails: (details) => details.data != chapIdx,
                                onAcceptWithDetails: (details) {
                                  ref.read(canvasProvider.notifier).reorderChapters(details.data, chapIdx);
                                },
                                builder: (ctx2, accepted, rejected) {
                                  return LongPressDraggable<int>(
                                    data: chapIdx,
                                    axis: Axis.horizontal,
                                    delay: const Duration(milliseconds: 200),
                                    feedback: Material(
                                      elevation: 4,
                                      borderRadius: BorderRadius.circular(20),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        child: Text(
                                          chapter.title,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            decoration: TextDecoration.none,
                                            color: p.accent,
                                          ),
                                        ),
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.3,
                                      child: Padding(
                                        padding: const EdgeInsets.only(right: 6),
                                        child: chip,
                                      ),
                                    ),
                                    onDragCompleted: () {},
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: GestureDetector(
                                        onSecondaryTap: () => _showChapterEditMenuLocal(ctx2, chapter),
                                        // Long-press = secondary on touch
                                        // devices (iPad has no right
                                        // click). Opens the same
                                        // rename / delete menu.
                                        onLongPress: () => _showChapterEditMenuLocal(ctx2, chapter),
                                        child: accepted.isNotEmpty
                                            ? Container(
                                                decoration: BoxDecoration(
                                                  border: Border.all(color: p.accent, width: 2),
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
                                  final title = await _promptForTextLocal(ctx, 'Nuovo capitolo', 'Nome capitolo');
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
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Page grid with thumbnails — drag to reorder
            Expanded(
              child: PageGridReorderable(
                scrollController: scrollController,
                liveState: liveState,
                visibleIndices: visibleIndices,
                selectedDocIndices: _isSelecting ? _selected : null,
                onToggleSelect: _toggleSelect,
                onLongPressToSelect: (docIdx) {
                  // Light haptic on entering selection mode — long-press is
                  // a hidden gesture and the visual change (checkboxes
                  // appearing) is easy to miss in peripheral vision.
                  HapticFeedback.lightImpact();
                  setState(() => _selected.add(docIdx));
                },
                onReorder: (oldVisIdx, newVisIdx) {
                  if (oldVisIdx == newVisIdx) return;
                  final oldDocIdx = visibleIndices[oldVisIdx];
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
                      _showChapterPickerForPage(ctx, liveState, docIndex);
                      break;
                    case 'delete':
                      // One-click delete with SnackBar undo — was a
                      // two-tap confirm dialog. deletePage already
                      // pushes an undo entry, so the Annulla button
                      // can roll it back without per-call bookkeeping.
                      ref.read(canvasProvider.notifier).deletePage(docIndex);
                      HapticFeedback.mediumImpact();
                      _messenger.hideCurrentSnackBar();
                      _messenger.showSnackBar(
                        SnackBar(
                          content: Text('Pagina ${docIndex + 1} eliminata'),
                          duration: const Duration(seconds: 5),
                          action: SnackBarAction(
                            label: 'Annulla',
                            onPressed: () =>
                                ref.read(canvasProvider.notifier).undo(),
                          ),
                        ),
                      );
                      break;
                  }
                },
              ),
            ),
            // ── Multi-select action bar ──
            if (_isSelecting)
              SelectionActionBar(
                count: _selected.length,
                onMoveToChapter: () => _assignSelectedToChapter(liveState),
                onDelete: _deleteSelected,
                onCut: () => _cutSelected(liveState),
              ),
          ],
        ),
        );
      },
    );
  }

  // ── Local helpers ──────────────────────────────────────────────────────────

  Future<void> _showChapterPickerForPage(
      BuildContext ctx, CanvasState s, int pageIndex) async {
    if (s.metadata.chapters.isEmpty) {
      _messenger.showSnackBar(
        const SnackBar(content: Text('Crea prima almeno un capitolo.')),
      );
      return;
    }
    final currentId = s.document.pages[pageIndex].chapterId;
    final selectedId = await _pickChapter(
      ctx,
      s,
      title: 'Assegna capitolo',
      selectedChapterId: currentId,
    );
    if (selectedId == _kRemoveChapter) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, null);
    } else if (selectedId != null) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, selectedId);
    }
  }

  Future<void> _showChapterEditMenuLocal(BuildContext ctx, Chapter chapter) async {
    // Replaced a full-screen modal bottom sheet with a contextual popup
    // anchored to the chip — saves a fullscreen render, opens beside the
    // finger instead of from the bottom, and the user only needs ONE tap
    // to pick instead of (open sheet → tap option).
    final box = ctx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay);
    final p = HwThemeScope.of(ctx);
    final action = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(value: 'rename', child: _hwMenuRow(p, 'pen', 'Rinomina')),
        PopupMenuItem(
          value: 'delete',
          child: _hwMenuRow(p, 'trash', 'Elimina',
              color: HwTheme.syncConflict),
        ),
      ],
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      final newTitle = await _promptForTextLocal(ctx, 'Rinomina capitolo', 'Nome capitolo',
          initial: chapter.title);
      if (newTitle != null && newTitle.trim().isNotEmpty) {
        ref.read(canvasProvider.notifier).renameChapter(chapter.id, newTitle.trim());
      }
    } else if (action == 'delete') {
      // Distructive action: ask for confirmation so a stray tap on the
      // overflow menu doesn't wipe the user's chapter structure. The pages
      // themselves are preserved (they just become unassigned), but users
      // reasonably expect a safety net on anything named "Elimina".
      if (!ctx.mounted) return;
      final confirm = await showDialog<bool>(
        context: ctx,
        builder: (dCtx) => AlertDialog(
          title: const Text('Elimina capitolo'),
          content: Text(
            'Eliminare "${chapter.title}"? '
            'Le pagine al suo interno resteranno ma senza capitolo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Elimina'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        ref.read(canvasProvider.notifier).deleteChapter(chapter.id);
      }
    }
  }

  Future<void> _promptJumpToPage(BuildContext ctx, CanvasState s) async {
    // Respect chapter filter: when a chapter is active, the user types a
    // number 1..filtered.length and we remap to the absolute page index.
    final filtered = s.filteredPageIndices;
    final maxN = filtered.isEmpty ? s.pageCount : filtered.length;
    if (maxN <= 0) return;
    final controller = TextEditingController();
    final result = await showDialog<int>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: const Text('Vai alla pagina'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '1–$maxN',
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v);
            Navigator.pop(dCtx, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, int.tryParse(controller.text)),
            child: const Text('Vai'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    final clamped = (result - 1).clamp(0, maxN - 1);
    final target = filtered.isEmpty ? clamped : filtered[clamped];
    ref.read(canvasProvider.notifier).goToPage(target);
    if (ctx.mounted) Navigator.pop(ctx);
  }

  Future<String?> _promptForTextLocal(
    BuildContext ctx, String title, String hint, {String? initial}) async {
    String value = initial ?? '';
    return showDialog<String>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          autofocus: true,
          initialValue: value,
          decoration: InputDecoration(hintText: hint),
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) => Navigator.pop(dCtx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, value),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  SelectionActionBar
// ─────────────────────────────────────────────────────────────

/// Bottom action bar shown when one or more pages are selected.
class SelectionActionBar extends StatelessWidget {
  final int count;
  final VoidCallback onMoveToChapter;
  final VoidCallback onDelete;
  final VoidCallback onCut;

  const SelectionActionBar({
    super.key,
    required this.count,
    required this.onMoveToChapter,
    required this.onDelete,
    required this.onCut,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.paper0,
        border: Border(top: BorderSide(color: p.paper3)),
        boxShadow: hwShadow1(p.brightness),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '$count pag.',
                  style: TextStyle(
                    fontSize: 13,
                    color: p.ink2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Spacer(),
              SelectionActionBarButton(
                icon: 'chapter',
                label: 'Capitolo',
                color: p.accent,
                onTap: onMoveToChapter,
              ),
              const SizedBox(width: 4),
              SelectionActionBarButton(
                icon: 'cut',
                label: 'Taglia',
                color: p.ink1,
                onTap: onCut,
              ),
              const SizedBox(width: 4),
              SelectionActionBarButton(
                icon: 'trash',
                label: 'Elimina',
                color: HwTheme.syncConflict,
                onTap: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  SelectionActionBarButton
// ─────────────────────────────────────────────────────────────

class SelectionActionBarButton extends StatelessWidget {
  final String icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const SelectionActionBarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(HwTheme.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HwIcon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  PageGridReorderable
// ─────────────────────────────────────────────────────────────

/// Reorderable grid of page thumbnails with drag-and-drop support.
class PageGridReorderable extends ConsumerStatefulWidget {
  final ScrollController scrollController;
  final CanvasState liveState;
  final List<int> visibleIndices;
  final void Function(int oldVisIdx, int newVisIdx) onReorder;
  final void Function(int docIndex) onTapPage;
  final void Function(int docIndex, int visIdx, String action) onPageAction;

  /// When non-null, the grid is in selection mode.
  final Set<int>? selectedDocIndices;

  /// Callback to toggle a page's selection (only used in selection mode).
  final void Function(int docIdx)? onToggleSelect;

  /// Called when the user long-presses a page while NOT in selection mode,
  /// to enter selection mode with that page pre-selected.
  final void Function(int docIdx)? onLongPressToSelect;

  const PageGridReorderable({
    super.key,
    required this.scrollController,
    required this.liveState,
    required this.visibleIndices,
    required this.onReorder,
    required this.onTapPage,
    required this.onPageAction,
    this.selectedDocIndices,
    this.onToggleSelect,
    this.onLongPressToSelect,
  });

  @override
  ConsumerState<PageGridReorderable> createState() => _PageGridReorderableState();
}

class _PageGridReorderableState extends ConsumerState<PageGridReorderable> {
  int? _dragFromVisIdx;
  int? _dragOverVisIdx;
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentPage());
  }

  /// Jump the grid to the row containing the current page.
  void _scrollToCurrentPage() {
    if (_didInitialScroll || !mounted) return;
    final curDocIdx = widget.liveState.currentPageIndex;
    final curVisIdx = widget.visibleIndices.indexOf(curDocIdx);
    if (curVisIdx < 0) return;

    final controller = widget.scrollController;
    if (!controller.hasClients) return;

    const crossAxisCount = 3;
    const crossAxisSpacing = 10.0;
    const mainAxisSpacing = 10.0;
    const childAspectRatio = 0.60;
    const padding = 12.0;

    final viewportWidth = controller.position.viewportDimension == 0
        ? MediaQuery.of(context).size.width
        : context.size?.width ?? MediaQuery.of(context).size.width;
    final tileWidth =
        (viewportWidth - padding * 2 - crossAxisSpacing * (crossAxisCount - 1)) /
            crossAxisCount;
    final tileHeight = tileWidth / childAspectRatio;
    final rowIdx = curVisIdx ~/ crossAxisCount;
    final target = padding + rowIdx * (tileHeight + mainAxisSpacing);
    final clamped =
        target.clamp(0.0, controller.position.maxScrollExtent).toDouble();

    controller.jumpTo(clamped);
    _didInitialScroll = true;
  }

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

        final isSelecting = widget.selectedDocIndices != null;
        final isSelected = isSelecting && widget.selectedDocIndices!.contains(index);

        final tile = _buildTile(
          ctx, visIdx, index, isCurrentPage, entry, page, chapterName,
          isDragOver, isSelecting, isSelected,
        );

        // In selection mode: tap = toggle; no drag
        if (isSelecting) {
          return GestureDetector(
            onTap: () => widget.onToggleSelect?.call(index),
            child: tile,
          );
        }

        // Normal mode: tap = navigate, long-press = enter select mode / drag
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
          builder: (ctx2, accepted, rejected) {
            return LongPressDraggable<int>(
              data: visIdx,
              delay: const Duration(milliseconds: 400),
              hapticFeedbackOnStart: true,
              onDragStarted: () => setState(() => _dragFromVisIdx = visIdx),
              onDragEnd: (_) {
                setState(() { _dragFromVisIdx = null; _dragOverVisIdx = null; });
              },
              onDraggableCanceled: (_, __) {
                setState(() { _dragFromVisIdx = null; _dragOverVisIdx = null; });
              },
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
              child: GestureDetector(
                onTap: () => widget.onTapPage(index),
                onLongPress: () => widget.onLongPressToSelect?.call(index),
                child: tile,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTile(
    BuildContext ctx, int visIdx, int index, bool isCurrentPage,
    PageEntry entry, PageData? page, String? chapterName, bool isDragOver,
    bool isSelecting, bool isSelected,
  ) {
    final p = HwThemeScope.of(ctx);
    final borderColor = isSelected
        ? p.accent
        : isDragOver
            ? p.accentSoft
            : isCurrentPage
                ? p.accent
                : p.paperEdge;
    final borderWidth = isSelected ? 2.5 : isCurrentPage ? 2.5 : isDragOver ? 2.0 : 1.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HwTheme.rMd),
        color: isSelected ? p.accentSoft.withValues(alpha: 0.55) : null,
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _buildThumbnail(index, isCurrentPage, page, widget.liveState,
                        overrideBorder: false),
                  ),
                  // Selection mode: show checkbox overlay
                  if (isSelecting)
                    Positioned(
                      top: 4, left: 4,
                      child: Container(
                        width: 22, height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected ? p.accent : p.paper0,
                          border: Border.all(
                            color: isSelected ? p.accent : p.paperEdge,
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 3,
                            ),
                          ],
                        ),
                        child: isSelected
                            ? HwIcon('check', size: 14, color: p.paper0)
                            : null,
                      ),
                    )
                  else
                    // Normal mode: 3-dot menu button. "Vai a pagina" omitted
                    // — a plain tap on the thumbnail already navigates there,
                    // so listing it in the menu was an extra click for the
                    // same destination.
                    Positioned(
                      top: 2, right: 2,
                      child: PopupMenuButton<String>(
                        icon: HwIcon('more', size: 18, color: p.ink2),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'insert_before', child: _pageMenuRow(p, 'plus', 'Inserisci prima')),
                          PopupMenuItem(value: 'insert_after', child: _pageMenuRow(p, 'plus', 'Inserisci dopo')),
                          PopupMenuItem(value: 'duplicate', child: _pageMenuRow(p, 'duplicate', 'Duplica')),
                          PopupMenuItem(value: 'chapter', child: _pageMenuRow(p, 'chapter', 'Capitolo…')),
                          if (widget.liveState.pageCount > 1)
                            PopupMenuItem(
                              value: 'delete',
                              child: _pageMenuRow(p, 'trash', 'Elimina',
                                  color: HwTheme.syncConflict),
                            ),
                        ],
                        onSelected: (action) => widget.onPageAction(index, visIdx, action),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            chapterName != null ? '${visIdx + 1} • $chapterName' : '${visIdx + 1}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: isCurrentPage ? FontWeight.w700 : FontWeight.w500,
              color: isSelected || isCurrentPage ? p.accentDeep : p.ink2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _pageMenuRow(HwPalette p, String icon, String label, {Color? color}) =>
      _hwMenuRow(p, icon, label, color: color);

  Widget _buildThumbnail(
    int docIndex, bool isCurrentPage, PageData? page, CanvasState state, {
    bool overrideBorder = true,
  }) {
    // Lazy-decode image assets for THIS visible thumbnail. Eagerly
    // decoding all assets on notebook open is fine for small notebooks
    // but a 200-page document with image-heavy chapters would burn
    // seconds of CPU + ~hundred-MB of texture RAM. The page manager's
    // grid only builds visible thumbnails, so doing the decode here
    // naturally bounds the work to "what the user can actually see".
    // Already-cached and already-queued assets short-circuit on the
    // notifier side, so no per-frame waste.
    if (page != null) {
      bool hasMissing = false;
      for (final el in page.layers.content) {
        if (el is ImageElement) {
          final path = el.data.assetPath;
          if (!state.imageCache.containsKey(path)) {
            hasMissing = true;
            break;
          }
        }
      }
      if (hasMissing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final notifier = ref.read(canvasProvider.notifier);
          for (final el in page.layers.content) {
            if (el is ImageElement) {
              notifier.ensureAssetDecodedForThumbnail(el.data.assetPath);
            }
          }
        });
      }
    }
    // Detect corrupt-asset indicator: any image element on this page
    // whose asset has been flagged as un-decodable (typically due to
    // the historic 1024-aligned server-truncation bug). Also detect
    // loading-asset (lazy-fetch in flight) so the thumbnail shows a
    // distinct "image is on its way" spinner instead of either nothing
    // or the alarming broken-image badge.
    bool hasCorruptAsset = false;
    bool hasLoadingAsset = false;
    final notifier = ref.read(canvasProvider.notifier);
    final corruptAssetIds =
        page != null ? notifier.corruptAssetIds : const <String>{};
    final loadingAssetIds =
        page != null ? notifier.loadingAssetIds : const <String>{};
    if (page != null &&
        (corruptAssetIds.isNotEmpty || loadingAssetIds.isNotEmpty)) {
      for (final el in page.layers.content) {
        if (el is ImageElement) {
          final ap = el.data.assetPath;
          if (corruptAssetIds.contains(ap)) {
            hasCorruptAsset = true;
            break;
          }
          if (loadingAssetIds.contains(ap)) {
            hasLoadingAsset = true;
          }
        }
      }
    }
    return Builder(builder: (ctx) {
      final outline = Theme.of(ctx).colorScheme.outlineVariant;
      final shadowColor = Theme.of(ctx).colorScheme.shadow;
      return Container(
        decoration: BoxDecoration(
          // Paper-simulate background — CanvasRenderEngine renders page paper
          // over this, so keep white to match the paper color even in dark mode.
          color: Colors.white,
          border: overrideBorder
              ? Border.all(
                  color: isCurrentPage ? Colors.blue : outline,
                  width: isCurrentPage ? 2.5 : 1,
                )
              : null,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: shadowColor.withValues(alpha: 0.08),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: page != null
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: CanvasRenderEngine(
                        pageData: page,
                        zoom: 1.0,
                        panOffset: Offset.zero,
                        imageCache: state.imageCache,
                        // Without this, the picture cache stays
                        // disabled forever for thumbnails of pages
                        // that have any corrupt asset → the grid
                        // pays the full re-record cost on every thumb
                        // repaint while scrolling.
                        corruptAssetIds: corruptAssetIds,
                      ),
                      size: Size.infinite,
                    ),
                    if (hasCorruptAsset)
                      const Positioned(
                        top: 4,
                        right: 4,
                        child: Tooltip(
                          message:
                              "Asset corrotto sul server (troncato) — "
                              'ri-importa il PDF originale per recuperare',
                          child: Icon(
                            Icons.broken_image_rounded,
                            color: Color(0xFFE65100),
                            size: 18,
                          ),
                        ),
                      )
                    else if (hasLoadingAsset)
                      const Positioned(
                        top: 6,
                        right: 6,
                        child: Tooltip(
                          message: 'Caricamento immagine dal server…',
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                  Color(0xFF1976D2)),
                            ),
                          ),
                        ),
                      ),
                  ],
                )
              : Center(child: Icon(Icons.description_outlined, color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
        ),
      );
    });
  }
}
