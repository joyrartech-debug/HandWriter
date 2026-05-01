import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/app_settings_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/ui/screens/settings_screen.dart';
import 'package:handwriter/ui/services/notebook_opener.dart';
import 'package:handwriter/ui/theme/hw_icons.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';
import 'package:handwriter/ui/primitives/hw_button.dart';
import 'package:handwriter/ui/primitives/sync_badge.dart';

/// HandWriter library screen, "warm paper" redesign.
class LibraryScreenV2 extends ConsumerStatefulWidget {
  const LibraryScreenV2({super.key});

  @override
  ConsumerState<LibraryScreenV2> createState() => _LibraryScreenV2State();
}

class _LibraryScreenV2State extends ConsumerState<LibraryScreenV2> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _gridView = true;
  Timer? _bgSyncTimer;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      ref.read(notebookListProvider.notifier).refresh();
      // Best-effort retry of pending uploads on cold boot.
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        await ref.read(notebookListProvider.notifier).retryPendingUploads();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _bgSyncTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    final settings = ref.watch(appSettingsProvider);
    final asyncList = ref.watch(notebookListProvider);

    final entries = asyncList.valueOrNull ?? const <NotebookEntry>[];
    final filtered = _filterAndSort(entries, settings, _query);

    return Scaffold(
      backgroundColor: p.paper1,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              searchController: _searchCtrl,
              onSearchChanged: (v) => setState(() => _query = v),
              gridView: _gridView,
              onViewToggle: (v) => setState(() => _gridView = v),
              onSortTap: _showSortSheet,
              onSettingsTap: _openSettings,
              sortLabel: settings.sortMode.label,
            ),
            Expanded(
              child: asyncList.when(
                data: (_) => _Body(
                  entries: filtered,
                  gridView: _gridView,
                  favoriteIds: settings.favoriteNotebookIds,
                  onOpen: _openNotebook,
                  onCreate: _createNotebook,
                  onLongPress: _showNotebookMenu,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                    child: Text('Errore: $e',
                        style: TextStyle(color: p.ink2))),
              ),
            ),
            _FooterBar(),
          ],
        ),
      ),
    );
  }

  List<NotebookEntry> _filterAndSort(
      List<NotebookEntry> all, AppSettings s, String query) {
    var list = query.isEmpty
        ? List<NotebookEntry>.from(all)
        : all
            .where((n) =>
                n.metadata.title.toLowerCase().contains(query.toLowerCase()))
            .toList();

    int compare(NotebookEntry a, NotebookEntry b) {
      switch (s.sortMode) {
        case LibrarySortMode.modifiedDesc:
          return b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt);
        case LibrarySortMode.modifiedAsc:
          return a.metadata.modifiedAt.compareTo(b.metadata.modifiedAt);
        case LibrarySortMode.titleAsc:
          return a.metadata.title.compareTo(b.metadata.title);
        case LibrarySortMode.titleDesc:
          return b.metadata.title.compareTo(a.metadata.title);
        case LibrarySortMode.createdDesc:
          return b.metadata.createdAt.compareTo(a.metadata.createdAt);
        case LibrarySortMode.createdAsc:
          return a.metadata.createdAt.compareTo(b.metadata.createdAt);
        case LibrarySortMode.colorGroup:
          return a.metadata.coverColor.compareTo(b.metadata.coverColor);
      }
    }

    list.sort((a, b) {
      if (s.favoritesFirst) {
        final fa = s.favoriteNotebookIds.contains(a.metadata.id);
        final fb = s.favoriteNotebookIds.contains(b.metadata.id);
        if (fa != fb) return fa ? -1 : 1;
      }
      return compare(a, b);
    });
    return list;
  }

  void _openNotebook(NotebookEntry entry) async {
    ref.read(appSettingsProvider.notifier).markOpened(entry.metadata.id);
    await openNotebookAndNavigate(context, ref, entry);
    if (mounted) ref.read(notebookListProvider.notifier).refresh();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const SettingsScreenV2(),
    ));
  }

  Future<void> _createNotebook() async {
    final res = await showDialog<_NewNotebookResult>(
      context: context,
      builder: (_) => const _NewNotebookDialog(),
    );
    if (res == null) return;
    try {
      final argb = (res.coverColor.a * 255).round() << 24 |
          (res.coverColor.r * 255).round() << 16 |
          (res.coverColor.g * 255).round() << 8 |
          (res.coverColor.b * 255).round();
      final entry =
          await ref.read(notebookListProvider.notifier).createNotebook(
                title: res.title,
                paperType: res.paperType,
                coverColor: argb,
              );
      if (mounted) _openNotebook(entry);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore creazione: $e')),
      );
    }
  }

  void _showNotebookMenu(NotebookEntry entry) async {
    final settings = ref.read(appSettingsProvider);
    final isFav = settings.favoriteNotebookIds.contains(entry.metadata.id);

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = HwThemeScope.of(ctx);
        return Container(
          decoration: BoxDecoration(
            color: p.paper0,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.paper3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(entry.metadata.title,
                  style: TextStyle(
                      color: p.ink0,
                      fontWeight: FontWeight.w600,
                      fontSize: 16)),
              const SizedBox(height: 16),
              _menuItem(ctx, 'star',
                  isFav ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
                  'fav'),
              _menuItem(ctx, 'pen', 'Rinomina', 'rename'),
              _menuItem(ctx, 'trash', 'Elimina', 'delete', danger: true),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'fav':
        ref
            .read(appSettingsProvider.notifier)
            .toggleFavorite(entry.metadata.id);
        break;
      case 'rename':
        final t = await _renameDialog(entry.metadata.title);
        if (t != null && t.isNotEmpty) {
          await ref
              .read(notebookListProvider.notifier)
              .renameNotebook(entry, t);
        }
        break;
      case 'delete':
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Eliminare il taccuino?'),
            content: const Text(
                'Verrà spostato nel cestino. Potrai ripristinarlo da Impostazioni > Spazio.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Annulla')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Elimina')),
            ],
          ),
        );
        if (confirm == true) {
          await ref.read(notebookListProvider.notifier).deleteNotebook(entry);
        }
        break;
    }
  }

  Widget _menuItem(BuildContext ctx, String icon, String label, String action,
      {bool danger = false}) {
    final p = HwThemeScope.of(ctx);
    return InkWell(
      onTap: () => Navigator.of(ctx).pop(action),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(
          children: [
            HwIcon(icon,
                size: 18, color: danger ? HwTheme.syncConflict : p.ink1),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    color: danger ? HwTheme.syncConflict : p.ink0,
                    fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Future<String?> _renameDialog(String old) async {
    final ctrl = TextEditingController(text: old);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rinomina taccuino'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Salva')),
        ],
      ),
    );
  }

  void _showSortSheet() async {
    final current = ref.read(appSettingsProvider).sortMode;
    final p = HwThemeScope.of(context);
    final picked = await showModalBottomSheet<LibrarySortMode>(
      context: context,
      backgroundColor: p.paper0,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Text('Ordinamento',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: p.ink0)),
              const SizedBox(height: 8),
              for (final m in LibrarySortMode.values)
                ListTile(
                  leading:
                      Icon(m.icon, size: 18, color: p.ink2),
                  title: Text(m.label,
                      style: TextStyle(color: p.ink0, fontSize: 14)),
                  trailing:
                      m == current ? HwIcon('check', size: 16, color: p.accent) : null,
                  onTap: () => Navigator.of(ctx).pop(m),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      ref.read(appSettingsProvider.notifier).setSortMode(picked);
    }
  }
}

// ─── Top bar ─────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final bool gridView;
  final ValueChanged<bool> onViewToggle;
  final VoidCallback onSortTap;
  final VoidCallback onSettingsTap;
  final String sortLabel;

  const _TopBar({
    required this.searchController,
    required this.onSearchChanged,
    required this.gridView,
    required this.onViewToggle,
    required this.onSortTap,
    required this.onSettingsTap,
    required this.sortLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 16),
      decoration: BoxDecoration(
        color: p.paper0,
        border: Border(bottom: BorderSide(color: p.paper3)),
      ),
      child: Row(
        children: [
          Text('HandWriter',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: p.ink0,
              )),
          const Spacer(),
          HwTextField(
            controller: searchController,
            hint: 'Cerca taccuini…',
            leading: const HwIcon('search', size: 16),
            onChanged: onSearchChanged,
            width: 240,
          ),
          const SizedBox(width: 12),
          const HwDivider(),
          const SizedBox(width: 12),
          // View toggle
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: p.paper2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                _SegBtn(
                    icon: 'grid',
                    selected: gridView,
                    onTap: () => onViewToggle(true)),
                _SegBtn(
                    icon: 'list',
                    selected: !gridView,
                    onTap: () => onViewToggle(false)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          HwButton(
            leading: const HwIcon('sort', size: 16),
            label: sortLabel,
            onPressed: onSortTap,
          ),
          const SizedBox(width: 12),
          const HwDivider(),
          const SizedBox(width: 12),
          HwButton.icon(
              icon: const HwIcon('settings', size: 16),
              tooltip: 'Impostazioni',
              onPressed: onSettingsTap),
        ],
      ),
    );
  }
}

class _SegBtn extends StatelessWidget {
  final String icon;
  final bool selected;
  final VoidCallback onTap;
  const _SegBtn(
      {required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? p.paper0 : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected ? hwShadow1(p.brightness) : null,
          ),
          child: HwIcon(icon, size: 16, color: selected ? p.ink0 : p.ink2),
        ),
      ),
    );
  }
}

// ─── Body ─────────────────────────────────────────────────────────
class _Body extends StatelessWidget {
  final List<NotebookEntry> entries;
  final bool gridView;
  final Set<String> favoriteIds;
  final ValueChanged<NotebookEntry> onOpen;
  final VoidCallback onCreate;
  final ValueChanged<NotebookEntry> onLongPress;

  const _Body({
    required this.entries,
    required this.gridView,
    required this.favoriteIds,
    required this.onOpen,
    required this.onCreate,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('I tuoi taccuini',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: p.ink0,
                    )),
                const SizedBox(width: 12),
                Text('${entries.length} elementi',
                    style: TextStyle(fontSize: 13, color: p.ink2)),
                const Spacer(),
                HwButton(
                  leading: const HwIcon('plus', size: 16),
                  label: 'Nuovo taccuino',
                  style: HwButtonStyle.primary,
                  onPressed: onCreate,
                ),
              ],
            ),
          ),
        ),
        if (gridView)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 232,
                mainAxisExtent: 320,
                crossAxisSpacing: 32,
                mainAxisSpacing: 40,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  if (i == 0) return _NewTile(onTap: onCreate);
                  final e = entries[i - 1];
                  return _CoverTile(
                    entry: e,
                    favorite: favoriteIds.contains(e.metadata.id),
                    onTap: () => onOpen(e),
                    onLongPress: () => onLongPress(e),
                  );
                },
                childCount: entries.length + 1,
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            sliver: SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (_, i) => _ListRow(
                entry: entries[i],
                favorite: favoriteIds.contains(entries[i].metadata.id),
                onTap: () => onOpen(entries[i]),
                onLongPress: () => onLongPress(entries[i]),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

class _NewTile extends StatelessWidget {
  final VoidCallback onTap;
  const _NewTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 200,
          height: 260,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                bottomLeft: Radius.circular(4),
                topRight: Radius.circular(10),
                bottomRight: Radius.circular(10),
              ),
              child: DottedBorderBox(
                color: p.paperEdge,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    HwIcon('plus', size: 28, color: p.ink2),
                    const SizedBox(height: 8),
                    Text('Nuovo',
                        style: TextStyle(
                            fontSize: 13,
                            color: p.ink2,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class DottedBorderBox extends StatelessWidget {
  final Color color;
  final Widget child;
  const DottedBorderBox({super.key, required this.color, required this.child});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DottedBorderPainter(color),
      child: child,
    );
  }
}

class _DottedBorderPainter extends CustomPainter {
  final Color color;
  _DottedBorderPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final r = const BorderRadius.only(
      topLeft: Radius.circular(4),
      bottomLeft: Radius.circular(4),
      topRight: Radius.circular(10),
      bottomRight: Radius.circular(10),
    ).toRRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(r);
    final metric = path.computeMetrics().first;
    const dash = 6.0, gap = 5.0;
    var dist = 0.0;
    while (dist < metric.length) {
      final next = (dist + dash).clamp(0, metric.length).toDouble();
      canvas.drawPath(metric.extractPath(dist, next), paint);
      dist += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DottedBorderPainter old) => old.color != color;
}

class _CoverTile extends StatelessWidget {
  final NotebookEntry entry;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _CoverTile({
    required this.entry,
    required this.favorite,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: onLongPress,
          child: NotebookCover(
            color: Color(entry.metadata.coverColor),
            title: entry.metadata.title,
            favorite: favorite,
            texture: _textureFor(entry.metadata.paperType),
            width: 200,
            height: 260,
            onTap: onTap,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 200,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(entry.metadata.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: p.ink0,
                    )),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text('${entry.metadata.pageCount} pag.',
                        style: TextStyle(fontSize: 12, color: p.ink2)),
                    Text(' · ',
                        style: TextStyle(fontSize: 12, color: p.ink3)),
                    Expanded(
                      child: Text(
                        _relativeTime(entry.metadata.modifiedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: p.ink2),
                      ),
                    ),
                    SyncBadge(state: _syncStateOf(entry)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ListRow extends StatelessWidget {
  final NotebookEntry entry;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _ListRow({
    required this.entry,
    required this.favorite,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 42,
                decoration: BoxDecoration(
                  color: Color(entry.metadata.coverColor),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(2),
                    bottomLeft: Radius.circular(2),
                    topRight: Radius.circular(4),
                    bottomRight: Radius.circular(4),
                  ),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x33000000),
                        offset: Offset(3, 0),
                        blurRadius: 0,
                        spreadRadius: -3),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.metadata.title,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: p.ink0)),
                    Text('${entry.metadata.pageCount} pagine',
                        style: TextStyle(fontSize: 12, color: p.ink2)),
                  ],
                ),
              ),
              SizedBox(
                width: 120,
                child: Text(_relativeTime(entry.metadata.modifiedAt),
                    style: TextStyle(fontSize: 12, color: p.ink2)),
              ),
              SyncBadge(state: _syncStateOf(entry)),
              if (favorite) ...[
                const SizedBox(width: 8),
                HwIcon('star-filled', size: 14, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FooterBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
      decoration: BoxDecoration(
        color: p.paper0,
        border: Border(top: BorderSide(color: p.paper3)),
      ),
      child: Row(
        children: [
          HwIcon('cloud-check', size: 14, color: p.ink2),
          const SizedBox(width: 6),
          Text('WebDAV',
              style: TextStyle(fontSize: 13, color: p.ink2)),
          const Spacer(),
          Text('App locale-first',
              style: TextStyle(fontSize: 13, color: p.ink2)),
        ],
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────
HwSyncState _syncStateOf(NotebookEntry e) {
  if (e.isLocal) return HwSyncState.pending;
  return HwSyncState.ok;
}

BackgroundTexture _textureFor(String paperType) {
  switch (paperType) {
    case 'lined':
      return BackgroundTexture.lines;
    case 'grid':
      return BackgroundTexture.grid;
    case 'dotted':
      return BackgroundTexture.dots;
    case 'cornell':
      return BackgroundTexture.cornell;
    default:
      return BackgroundTexture.blank;
  }
}

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'ora';
  if (diff.inHours < 1) return '${diff.inMinutes} min fa';
  if (diff.inHours < 24) return '${diff.inHours} ${diff.inHours == 1 ? "ora" : "ore"} fa';
  if (diff.inDays < 7) return '${diff.inDays} g fa';
  if (diff.inDays < 30) return '${(diff.inDays / 7).floor()} sett. fa';
  if (diff.inDays < 365) return '${(diff.inDays / 30).floor()} mesi fa';
  return '${(diff.inDays / 365).floor()} anni fa';
}

// ─── New notebook dialog ──────────────────────────────────────────
class _NewNotebookResult {
  final String title;
  final Color coverColor;
  final String paperType;
  _NewNotebookResult(this.title, this.coverColor, this.paperType);
}

class _NewNotebookDialog extends StatefulWidget {
  const _NewNotebookDialog();
  @override
  State<_NewNotebookDialog> createState() => _NewNotebookDialogState();
}

class _NewNotebookDialogState extends State<_NewNotebookDialog> {
  final _titleCtrl = TextEditingController();
  Color _color = HwTheme.cover1;
  String _paper = 'lined';

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return AlertDialog(
      backgroundColor: p.paper0,
      title: const Text('Nuovo taccuino'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Titolo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text('Copertina',
                style: TextStyle(
                    fontSize: 11,
                    color: p.ink2,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: HwTheme.covers
                  .map((c) => GestureDetector(
                        onTap: () => setState(() => _color = c),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: c,
                            borderRadius: BorderRadius.circular(6),
                            border: _color == c
                                ? Border.all(color: p.ink0, width: 2)
                                : null,
                          ),
                        ),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 20),
            Text('Carta',
                style: TextStyle(
                    fontSize: 11,
                    color: p.ink2,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                _paperChip('Bianco', 'blank'),
                _paperChip('Righe', 'lined'),
                _paperChip('Griglia', 'grid'),
                _paperChip('Puntinato', 'dotted'),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () {
            final t = _titleCtrl.text.trim();
            if (t.isEmpty) return;
            Navigator.of(context).pop(_NewNotebookResult(t, _color, _paper));
          },
          child: const Text('Crea'),
        ),
      ],
    );
  }

  Widget _paperChip(String label, String type) {
    final p = HwThemeScope.of(context);
    final selected = _paper == type;
    return GestureDetector(
      onTap: () => setState(() => _paper = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.ink0 : p.paper2,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? p.paper0 : p.ink0, fontSize: 13)),
      ),
    );
  }
}
