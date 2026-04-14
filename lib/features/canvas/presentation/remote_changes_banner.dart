import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';

/// A slim animated banner that slides in from the top when remote changes
/// are detected. Tapping it opens a detail sheet; the user can accept
/// or dismiss the incoming edits.
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
                    label: 'Accetta',
                    color: const Color(0xFF22C55E),
                    onTap: () {
                      ref.read(canvasProvider.notifier).acceptRemoteChanges();
                    },
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
    return Container(
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
              const Expanded(
                child: Text(
                  'Modifiche in arrivo',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // ── Change list ──
          if (pending.modifiedPageCount > 0)
            _ChangeRow(
              icon: Icons.edit_note,
              iconColor: const Color(0xFFFBBF24),
              label: pending.modifiedPageCount == 1
                  ? '1 pagina modificata'
                  : '${pending.modifiedPageCount} pagine modificate',
            ),
          if (pending.newPageCount > 0)
            _ChangeRow(
              icon: Icons.add_circle_outline,
              iconColor: const Color(0xFF22C55E),
              label: pending.newPageCount == 1
                  ? '1 nuova pagina'
                  : '${pending.newPageCount} nuove pagine',
            ),
          if (pending.deletedPageCount > 0)
            _ChangeRow(
              icon: Icons.remove_circle_outline,
              iconColor: const Color(0xFFEF4444),
              label: pending.deletedPageCount == 1
                  ? '1 pagina rimossa'
                  : '${pending.deletedPageCount} pagine rimosse',
            ),
          if (pending.newAssetCount > 0)
            _ChangeRow(
              icon: Icons.image_outlined,
              iconColor: const Color(0xFF8B5CF6),
              label: pending.newAssetCount == 1
                  ? '1 nuova immagine'
                  : '${pending.newAssetCount} nuove immagini',
            ),

          // ── Affected pages ──
          if (pending.changedPageNames.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                pending.changedPageNames.join(', '),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],

          const SizedBox(height: 24),

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
                  label: const Text('Applica'),
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

class _ChangeRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;

  const _ChangeRow({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 10),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

String _buildSummaryText(PendingRemoteChanges p) {
  final parts = <String>[];
  if (p.modifiedPageCount > 0) {
    parts.add('${p.modifiedPageCount} modificat${p.modifiedPageCount == 1 ? 'a' : 'e'}');
  }
  if (p.newPageCount > 0) {
    parts.add('${p.newPageCount} nuov${p.newPageCount == 1 ? 'a' : 'e'}');
  }
  if (p.newAssetCount > 0) {
    parts.add('${p.newAssetCount} immagin${p.newAssetCount == 1 ? 'e' : 'i'}');
  }
  return parts.isEmpty ? 'Cambiamenti rilevati' : parts.join(' · ');
}
