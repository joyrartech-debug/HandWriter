import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/features/canvas/data/render_engine.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

/// Full-screen conflict resolver showing local vs remote pages
/// side-by-side with rendered previews. User picks per-page.
class ConflictResolutionScreen extends ConsumerStatefulWidget {
  const ConflictResolutionScreen({super.key});

  @override
  ConsumerState<ConflictResolutionScreen> createState() =>
      _ConflictResolutionScreenState();
}

class _ConflictResolutionScreenState
    extends ConsumerState<ConflictResolutionScreen> {
  /// Per-page choice: true = keep local, false = accept remote, null = undecided
  final Map<String, bool> _choices = {};
  int _currentConflictIndex = 0;

  @override
  Widget build(BuildContext context) {
    final conflicts = ref.watch(
      canvasProvider.select((s) => s?.pendingConflicts ?? []),
    );
    if (conflicts.isEmpty) {
      // Conflicts were resolved/dismissed externally — show nothing.
      // The explicit Navigator.pop() in _applyChoices / _confirmDismiss
      // handles navigation; no auto-pop here to avoid double-pop.
      return const SizedBox.shrink();
    }

    final conflict = conflicts[_currentConflictIndex];
    final choice = _choices[conflict.fileName];

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        // Tooltip + a11y label make it clear this is "decide later", not
        // "discard everything" — bare close icon on a dark conflict screen
        // is easy to misread as a destructive cancel.
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          tooltip: 'Decidi più tardi',
          onPressed: () => _confirmDismiss(context, conflicts),
        ),
        title: Text(
          conflict.isDeletion
              ? 'Pagina ${conflict.pageNumber} eliminata altrove'
              : 'Conflitto — Pagina ${conflict.pageNumber}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          if (conflicts.length > 1)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '${_currentConflictIndex + 1}/${conflicts.length}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Chapter / page header ──
          if (conflict.chapterName != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              color: const Color(0xFF1E293B),
              child: Text(
                conflict.chapterName!,
                style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 12),
              ),
            ),

          // ── Element count diff bar (only meaningful for edit-vs-edit) ──
          if (!conflict.isDeletion) _DiffSummaryBar(conflict: conflict),

          // ── Deletion-conflict explainer banner ──
          if (conflict.isDeletion)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Color(0xFFFBBF24), size: 18),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Hai modificato questa pagina, ma un altro dispositivo '
                      "l'ha eliminata. Vuoi mantenerla o eliminarla?",
                      style: TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),

          // ── Choice cards ──
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  // KEEP (local) — shows the user's actual page
                  Expanded(
                    child: _VersionCard(
                      label: conflict.isDeletion
                          ? 'Mantieni la pagina'
                          : 'Locale (tuo)',
                      sublabel: _modifiedLabel(conflict.localPage.modifiedAt),
                      page: conflict.localPage,
                      imageCache: conflict.localImageCache,
                      selected: choice == true,
                      accentColor: const Color(0xFF3B82F6),
                      onTap: () => setState(() {
                        _choices[conflict.fileName] = true;
                      }),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // REMOTE / DELETE
                  Expanded(
                    child: conflict.isDeletion
                        ? _DeleteCard(
                            selected: choice == false,
                            onTap: () => setState(() {
                              _choices[conflict.fileName] = false;
                            }),
                          )
                        : _VersionCard(
                            label: 'Remoto (altro dispositivo)',
                            sublabel:
                                _modifiedLabel(conflict.remotePage.modifiedAt),
                            page: conflict.remotePage,
                            imageCache: conflict.remoteImageCache,
                            selected: choice == false,
                            accentColor: const Color(0xFF22C55E),
                            onTap: () => setState(() {
                              _choices[conflict.fileName] = false;
                            }),
                          ),
                  ),
                ],
              ),
            ),
          ),

          // ── Navigation + confirm buttons ──
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Bulk action buttons (for many conflicts)
                  if (conflicts.length > 3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.phone_android, size: 15),
                              label: const Text('Tieni tutti locali', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF3B82F6),
                                side: const BorderSide(color: Color(0xFF3B82F6), width: 0.5),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                              onPressed: () => setState(() {
                                for (final c in conflicts) {
                                  _choices[c.fileName] = true;
                                }
                              }),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.cloud_outlined, size: 15),
                              label: const Text('Accetta tutti remoti', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF22C55E),
                                side: const BorderSide(color: Color(0xFF22C55E), width: 0.5),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                              onPressed: () => setState(() {
                                for (final c in conflicts) {
                                  _choices[c.fileName] = false;
                                }
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Page navigation
                  if (conflicts.length > 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left, color: Colors.white54),
                          onPressed: _currentConflictIndex > 0
                              ? () => setState(() => _currentConflictIndex--)
                              : null,
                        ),
                        // Compact indicator: number + progress instead of individual dots
                        GestureDetector(
                          onTap: () => _showJumpToDialog(context, conflicts),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              '${_currentConflictIndex + 1} / ${conflicts.length}  '
                              '(${_choices.length} decis${_choices.length == 1 ? 'o' : 'i'})',
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, color: Colors.white54),
                          onPressed: _currentConflictIndex < conflicts.length - 1
                              ? () => setState(() => _currentConflictIndex++)
                              : null,
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  // Confirm button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _allDecided(conflicts)
                          ? () => _applyChoices(conflicts)
                          : null,
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(
                        _allDecided(conflicts)
                            ? 'Applica scelte'
                            : '${_choices.length}/${conflicts.length} decis${conflicts.length == 1 ? 'o' : 'i'}',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF22C55E),
                        disabledBackgroundColor: Colors.white12,
                        foregroundColor: Colors.white,
                        disabledForegroundColor: Colors.white38,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _allDecided(List<PageConflict> conflicts) =>
      _choices.length == conflicts.length;

  /// Jump-to dialog: scrollable list of all conflicts for quick navigation.
  void _showJumpToDialog(BuildContext ctx, List<PageConflict> conflicts) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Text('Vai al conflitto',
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${_choices.length}/${conflicts.length} decisi',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.4,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: conflicts.length,
                itemBuilder: (_, i) {
                  final c = conflicts[i];
                  final decided = _choices.containsKey(c.fileName);
                  final choice = _choices[c.fileName];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      decided
                          ? (choice == true ? Icons.phone_android : Icons.cloud_done)
                          : Icons.help_outline,
                      color: decided
                          ? (choice == true ? const Color(0xFF3B82F6) : const Color(0xFF22C55E))
                          : Colors.white24,
                      size: 20,
                    ),
                    title: Text(
                      'Pag. ${c.pageNumber}${c.chapterName != null ? ' — ${c.chapterName}' : ''}',
                      style: TextStyle(
                        color: i == _currentConflictIndex ? Colors.white : Colors.white70,
                        fontSize: 13,
                        fontWeight: i == _currentConflictIndex ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: i == _currentConflictIndex
                        ? const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14)
                        : null,
                    onTap: () {
                      setState(() => _currentConflictIndex = i);
                      Navigator.of(ctx).pop();
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _applyChoices(List<PageConflict> conflicts) {
    final resolutions = <String, bool>{};
    for (final c in conflicts) {
      resolutions[c.fileName] = _choices[c.fileName] ?? true; // default local
    }
    ref.read(canvasProvider.notifier).resolveConflicts(resolutions);
    Navigator.of(context).pop();
  }

  void _confirmDismiss(BuildContext ctx, List<PageConflict> conflicts) {
    if (_choices.isEmpty) {
      // No choices made — keep local for all
      ref.read(canvasProvider.notifier).dismissConflicts();
      Navigator.of(ctx).pop();
      return;
    }
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Annullare?',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          'Le scelte non applicate verranno perse. La versione locale verrà mantenuta.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Continua'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(canvasProvider.notifier).dismissConflicts();
              Navigator.of(context).pop();
            },
            child: const Text('Annulla', style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
  }

  String _modifiedLabel(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Adesso';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min fa';
    if (diff.inHours < 24) return '${diff.inHours} ore fa';
    return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════════
//  DIFF SUMMARY BAR
// ═══════════════════════════════════════════════════════════════

class _DiffSummaryBar extends StatelessWidget {
  final PageConflict conflict;
  const _DiffSummaryBar({required this.conflict});

  @override
  Widget build(BuildContext context) {
    final localCounts = _countElements(conflict.localPage);
    final remoteCounts = _countElements(conflict.remotePage);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: const Color(0xFF1E293B).withValues(alpha: 0.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _DiffChip(Icons.gesture, 'Tratti', localCounts.strokes, remoteCounts.strokes),
          const SizedBox(width: 16),
          _DiffChip(Icons.image_outlined, 'Immagini', localCounts.images, remoteCounts.images),
          const SizedBox(width: 16),
          _DiffChip(Icons.crop_square, 'Forme', localCounts.shapes, remoteCounts.shapes),
          const SizedBox(width: 16),
          _DiffChip(Icons.text_fields, 'Testi', localCounts.texts, remoteCounts.texts),
        ],
      ),
    );
  }

  _ElementCounts _countElements(PageData page) {
    var s = 0, i = 0, sh = 0, t = 0;
    for (final el in page.layers.content) {
      el.map(stroke: (_) => s++, image: (_) => i++, shape: (_) => sh++, text: (_) => t++);
    }
    return _ElementCounts(s, i, sh, t);
  }
}

class _ElementCounts {
  final int strokes, images, shapes, texts;
  const _ElementCounts(this.strokes, this.images, this.shapes, this.texts);
}

class _DiffChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int localCount;
  final int remoteCount;

  const _DiffChip(this.icon, this.label, this.localCount, this.remoteCount);

  @override
  Widget build(BuildContext context) {
    final diff = remoteCount - localCount;
    final color = diff == 0
        ? Colors.white38
        : diff > 0
            ? const Color(0xFF22C55E)
            : const Color(0xFFEF4444);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white38, size: 14),
        const SizedBox(width: 4),
        Text(
          '$localCount',
          style: const TextStyle(color: Color(0xFF3B82F6), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const Text(' / ', style: TextStyle(color: Colors.white24, fontSize: 11)),
        Text(
          '$remoteCount',
          style: const TextStyle(color: Color(0xFF22C55E), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        if (diff != 0) ...[
          const SizedBox(width: 2),
          Text(
            diff > 0 ? '+$diff' : '$diff',
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  VERSION CARD — renders one side (local or remote)
// ═══════════════════════════════════════════════════════════════

class _VersionCard extends StatelessWidget {
  final String label;
  final String sublabel;
  final PageData page;
  final Map<String, ui.Image> imageCache;
  final bool selected;
  final Color accentColor;
  final VoidCallback onTap;

  const _VersionCard({
    required this.label,
    required this.sublabel,
    required this.page,
    required this.imageCache,
    required this.selected,
    required this.accentColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? accentColor : Colors.white12,
            width: selected ? 2.5 : 1,
          ),
          color: selected
              ? accentColor.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.03),
        ),
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? accentColor.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
              ),
              child: Row(
                children: [
                  if (selected)
                    Icon(Icons.check_circle, color: accentColor, size: 18)
                  else
                    const Icon(Icons.radio_button_off, color: Colors.white30, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: selected ? accentColor : Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (sublabel.isNotEmpty)
                          Text(
                            sublabel,
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Rendered page preview
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(13)),
                child: _PagePreview(page: page, imageCache: imageCache),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  DELETE CARD — the "accept the remote deletion" choice
// ═══════════════════════════════════════════════════════════════

class _DeleteCard extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _DeleteCard({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFEF4444);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? red : Colors.white12,
            width: selected ? 2.5 : 1,
          ),
          color: selected
              ? red.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.03),
        ),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? red.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(13)),
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? Icons.check_circle : Icons.radio_button_off,
                    color: selected ? red : Colors.white30,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Elimina la pagina',
                      style: TextStyle(
                        color: selected ? red : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.delete_outline, color: Colors.white24, size: 44),
                    SizedBox(height: 8),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'Come sull\'altro dispositivo',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PAGE PREVIEW — renders page using CanvasRenderEngine
// ═══════════════════════════════════════════════════════════════

class _PagePreview extends StatelessWidget {
  final PageData page;
  final Map<String, ui.Image> imageCache;

  const _PagePreview({required this.page, required this.imageCache});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: CanvasRenderEngine(
            pageData: page,
            zoom: 1.0,
            panOffset: Offset.zero,
            imageCache: imageCache,
          ),
        );
      },
    );
  }
}
