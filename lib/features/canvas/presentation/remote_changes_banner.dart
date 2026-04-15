import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';

/// A slim animated banner that slides in from the top when remote changes
/// are detected. Tapping it opens a detail sheet where the user can see
/// per-page diffs and navigate directly to changed pages.
class RemoteChangesBanner extends ConsumerWidget {
  const RemoteChangesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(
      canvasProvider.select((s) => s?.pendingRemoteChanges),
    );
    if (pending == null) return const SizedBox.shrink();

    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: _AnimatedBanner(pending: pending),
    );
  }
}

class _AnimatedBanner extends ConsumerStatefulWidget {
  final PendingRemoteChanges pending;
  const _AnimatedBanner({required this.pending});

  @override
  ConsumerState<_AnimatedBanner> createState() => _AnimatedBannerState();
}

class _AnimatedBannerState extends ConsumerState<_AnimatedBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showDetails() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _RemoteChangesSheet(pending: widget.pending, ref: ref),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    final summary = _buildSummaryText(p);

    return SlideTransition(
      position: _slideAnim,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF1E293B),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _showDetails,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.sync, color: Colors.white70, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Modifiche da un altro dispositivo',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ActionChip(
                    label: 'Vedi dettagli',
                    color: const Color(0xFF3B82F6),
                    onTap: _showDetails,
                  ),
                  const SizedBox(width: 6),
                  _ActionChip(
                    label: 'Ignora',
                    color: Colors.white24,
                    onTap: () {
                      ref.read(canvasProvider.notifier).dismissRemoteChanges();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─── Detail Bottom Sheet ──────────────────────────────────────

class _RemoteChangesSheet extends StatelessWidget {
  final PendingRemoteChanges pending;
  final WidgetRef ref;

  const _RemoteChangesSheet({required this.pending, required this.ref});

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.65;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Handle bar ──
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // ── Header ──
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.devices, color: Color(0xFF3B82F6), size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Modifiche in arrivo',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tocca una pagina per applicare e andare lì',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Summary counts ──
          if (pending.newAssetCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const Icon(Icons.image_outlined, color: Color(0xFF8B5CF6), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    pending.newAssetCount == 1
                        ? '1 nuova immagine'
                        : '${pending.newAssetCount} nuove immagini',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),

          // ── Per-page change list ──
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: pending.changedPages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final detail = pending.changedPages[index];
                return _PageChangeCard(
                  detail: detail,
                  onTap: () {
                    ref.read(canvasProvider.notifier).acceptAndGoToPage(detail.pageIndex);
                    Navigator.of(context).pop();
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 20),

          // ── Action buttons ──
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    ref.read(canvasProvider.notifier).dismissRemoteChanges();
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Mantieni i miei'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    ref.read(canvasProvider.notifier).acceptRemoteChanges();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Applica tutto'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF22C55E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Per-page change card ─────────────────────────────────────

class _PageChangeCard extends StatelessWidget {
  final PageChangeDetail detail;
  final VoidCallback onTap;

  const _PageChangeCard({required this.detail, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isNew = detail.changeType == PageChangeType.added;
    final badgeColor = isNew ? const Color(0xFF22C55E) : const Color(0xFFFBBF24);
    final badgeLabel = isNew ? 'NUOVA' : 'MODIFICATA';
    final badgeIcon = isNew ? Icons.add_circle_outline : Icons.edit_note;

    return Material(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // Page number square
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${detail.pageNumber}',
                  style: TextStyle(
                    color: badgeColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Page info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title row: "Pagina 3" + chapter badge
                    Row(
                      children: [
                        Text(
                          'Pagina ${detail.pageNumber}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (detail.chapterName != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3B82F6).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              detail.chapterName!,
                              style: const TextStyle(
                                color: Color(0xFF93C5FD),
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),

                    // Element diff summary
                    if (detail.hasElementDiff)
                      _ElementDiffRow(detail: detail)
                    else
                      Row(
                        children: [
                          Icon(badgeIcon, color: badgeColor, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            badgeLabel,
                            style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              // Navigate arrow
              const Icon(Icons.chevron_right, color: Colors.white30, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Element diff summary for a page ──────────────────────────

class _ElementDiffRow extends StatelessWidget {
  final PageChangeDetail detail;
  const _ElementDiffRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    final diffs = <Widget>[];

    void addDiff(IconData icon, int local, int remote) {
      final delta = remote - local;
      if (delta == 0) return;
      final color = delta > 0 ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
      final sign = delta > 0 ? '+' : '';
      diffs.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white38, size: 13),
            const SizedBox(width: 2),
            Text(
              '$sign$delta',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    }

    addDiff(Icons.gesture, detail.localStrokeCount, detail.remoteStrokeCount);
    addDiff(Icons.image_outlined, detail.localImageCount, detail.remoteImageCount);
    addDiff(Icons.crop_square, detail.localShapeCount, detail.remoteShapeCount);
    addDiff(Icons.text_fields, detail.localTextCount, detail.remoteTextCount);

    if (diffs.isEmpty) {
      return const Text(
        'Contenuto aggiornato',
        style: TextStyle(color: Colors.white38, fontSize: 11),
      );
    }

    return Wrap(
      spacing: 10,
      children: diffs,
    );
  }
}

String _buildSummaryText(PendingRemoteChanges p) {
  final parts = <String>[];
  if (p.modifiedPageCount > 0) {
    parts.add('${p.modifiedPageCount} pag. modificat${p.modifiedPageCount == 1 ? 'a' : 'e'}');
  }
  if (p.newPageCount > 0) {
    parts.add('${p.newPageCount} nuov${p.newPageCount == 1 ? 'a' : 'e'}');
  }
  if (p.newAssetCount > 0) {
    parts.add('${p.newAssetCount} immagin${p.newAssetCount == 1 ? 'e' : 'i'}');
  }
  return parts.isEmpty ? 'Cambiamenti rilevati' : parts.join(' · ');
}
