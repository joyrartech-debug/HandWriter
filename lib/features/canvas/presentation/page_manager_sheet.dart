// ═══════════════════════════════════════════════════════════════
//  page_manager_sheet.dart
//
//  Page Manager bottom sheet, reorderable thumbnail grid, and
//  multi-select action bar.  Extracted from canvas_screen.dart.
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/page_clipboard_provider.dart';
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

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
  const PageManagerSheet({super.key, required this.initialState});

  @override
  ConsumerState<PageManagerSheet> createState() => _PageManagerSheetState();
}

class _PageManagerSheetState extends ConsumerState<PageManagerSheet> {
  /// Document indices of currently selected pages.
  final Set<int> _selected = {};

  bool get _isSelecting => _selected.isNotEmpty;

  void _toggleSelect(int docIdx) {
    setState(() {
      if (_selected.contains(docIdx)) {
        _selected.remove(docIdx);
      } else {
        _selected.add(docIdx);
      }
    });
  }

  void _clearSelection() => setState(() => _selected.clear());

  void _selectAll(List<int> visibleIndices) =>
      setState(() => _selected.addAll(visibleIndices));

  // ── Multi-page actions ──

  Future<void> _assignSelectedToChapter(CanvasState s) async {
    if (s.metadata.chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crea prima almeno un capitolo.')),
      );
      return;
    }
    const removeChapter = '__remove__';
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('Assegna capitolo (${_selected.length} pagine)'),
          ),
          ListTile(
            leading: const Icon(Icons.clear),
            title: const Text('Nessuno'),
            onTap: () => Navigator.of(ctx).pop(removeChapter),
          ),
          ...s.metadata.chapters.map((chapter) => ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(chapter.title),
                onTap: () => Navigator.of(ctx).pop(chapter.id),
              )),
        ],
      ),
    );
    if (selectedId == removeChapter) {
      ref.read(canvasProvider.notifier).assignPagesToChapter(_selected.toList(), null);
    } else if (selectedId != null) {
      ref.read(canvasProvider.notifier).assignPagesToChapter(_selected.toList(), selectedId);
    }
    _clearSelection();
  }

  void _deleteSelected() {
    ref.read(canvasProvider.notifier).deletePages(_selected.toList());
    _clearSelection();
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
    ScaffoldMessenger.of(context).showSnackBar(
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
        return Column(
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
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
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _selectAll(visibleIndices),
                          child: const Text('Tutte'),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Annulla selezione',
                          onPressed: _clearSelection,
                        ),
                      ] else ...[
                        const Text('Pagine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.checklist_rounded),
                          tooltip: 'Seleziona pagine',
                          color: Colors.grey.shade700,
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Tieni premuto su una pagina per selezionarla.'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                        // Paste pages from clipboard if available
                        if (ref.watch(pageClipboardProvider) != null)
                          IconButton(
                            icon: const Icon(Icons.content_paste_rounded, color: Colors.orange),
                            tooltip: 'Incolla pagine',
                            onPressed: () {
                              final clip = ref.read(pageClipboardProvider);
                              if (clip == null) return;
                              ref.read(canvasProvider.notifier).pastePages(
                                pages: clip.pages,
                                entries: clip.entries,
                              );
                              ref.read(pageClipboardProvider.notifier).state = null;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('${clip.pages.length} pagine incollate.'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.add_rounded, color: Colors.blue),
                          onPressed: () => ref.read(canvasProvider.notifier).addPage(),
                          tooltip: 'Aggiungi pagina',
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
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
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                            decoration: TextDecoration.none,
                                            color: Colors.blue,
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
                      ref.read(canvasProvider.notifier).deletePage(docIndex);
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
        );
      },
    );
  }

  // ── Local helpers ──────────────────────────────────────────────────────────

  Future<void> _showChapterPickerForPage(
      BuildContext ctx, CanvasState s, int pageIndex) async {
    if (s.metadata.chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crea prima almeno un capitolo.')),
      );
      return;
    }
    const removeChapter = '__remove__';
    final selectedId = await showModalBottomSheet<String>(
      context: ctx,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (shCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Assegna capitolo')),
          ListTile(
            leading: const Icon(Icons.clear),
            title: const Text('Nessuno'),
            onTap: () => Navigator.of(shCtx).pop(removeChapter),
          ),
          ...s.metadata.chapters.map((chapter) => ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(chapter.title),
                selected: s.document.pages[pageIndex].chapterId == chapter.id,
                onTap: () => Navigator.of(shCtx).pop(chapter.id),
              )),
        ],
      ),
    );
    if (selectedId == removeChapter) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, null);
    } else if (selectedId != null) {
      ref.read(canvasProvider.notifier).assignPageToChapter(pageIndex, selectedId);
    }
  }

  Future<void> _showChapterEditMenuLocal(BuildContext ctx, Chapter chapter) async {
    final action = await showModalBottomSheet<String>(
      context: ctx,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (shCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rinomina'),
              onTap: () => Navigator.pop(shCtx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title: const Text('Elimina', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(shCtx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      final newTitle = await _promptForTextLocal(ctx, 'Rinomina capitolo', 'Nome capitolo',
          initial: chapter.title);
      if (newTitle != null && newTitle.trim().isNotEmpty) {
        ref.read(canvasProvider.notifier).renameChapter(chapter.id, newTitle.trim());
      }
    } else if (action == 'delete') {
      ref.read(canvasProvider.notifier).deleteChapter(chapter.id);
    }
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
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
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Spacer(),
              SelectionActionBarButton(
                icon: Icons.folder_outlined,
                label: 'Capitolo',
                color: Colors.blue,
                onTap: onMoveToChapter,
              ),
              const SizedBox(width: 4),
              SelectionActionBarButton(
                icon: Icons.content_cut_rounded,
                label: 'Taglia',
                color: Colors.orange,
                onTap: onCut,
              ),
              const SizedBox(width: 4),
              SelectionActionBarButton(
                icon: Icons.delete_outline_rounded,
                label: 'Elimina',
                color: Colors.red,
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
  final IconData icon;
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
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
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
class PageGridReorderable extends StatefulWidget {
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
  State<PageGridReorderable> createState() => _PageGridReorderableState();
}

class _PageGridReorderableState extends State<PageGridReorderable> {
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
    final borderColor = isSelected
        ? Colors.blue
        : isDragOver
            ? Colors.blue.shade300
            : isCurrentPage
                ? Colors.blue
                : Colors.grey.shade300;
    final borderWidth = isSelected ? 2.5 : isCurrentPage ? 2.5 : isDragOver ? 2.0 : 1.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: isSelected ? Colors.blue.withValues(alpha: 0.07) : null,
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
                          color: isSelected ? Colors.blue : Colors.white,
                          border: Border.all(
                            color: isSelected ? Colors.blue : Colors.grey.shade400,
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
                            ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
                            : null,
                      ),
                    )
                  else
                    // Normal mode: 3-dot menu button
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
          ),
          const SizedBox(height: 4),
          Text(
            chapterName != null ? '${visIdx + 1} • $chapterName' : '${visIdx + 1}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: isCurrentPage ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? Colors.blue
                  : isCurrentPage
                      ? Colors.blue
                      : Colors.grey.shade700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(
    int docIndex, bool isCurrentPage, PageData? page, CanvasState state, {
    bool overrideBorder = true,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: overrideBorder
            ? Border.all(
                color: isCurrentPage ? Colors.blue : Colors.grey.shade300,
                width: isCurrentPage ? 2.5 : 1,
              )
            : null,
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
