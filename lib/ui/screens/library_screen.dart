import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/app_settings_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/ui/screens/settings_screen.dart';
import 'package:handwriter/ui/services/notebook_opener.dart';
import 'package:handwriter/ui/theme/hw_icons.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';
import 'package:handwriter/ui/primitives/hw_button.dart';
import 'package:handwriter/ui/primitives/sync_badge.dart';
import 'package:uuid/uuid.dart';

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

    final notebookNotifier = ref.read(notebookListProvider.notifier);
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
              onImportTap: _importNcnote,
              sortLabel: settings.sortMode.label,
            ),
            // Sync-in-progress banner — visible during any background
            // refresh, including the cold-start fetch on a fresh device
            // (where `entries` is empty and the body just shows the
            // "Nuovo taccuino" tile). Without this, a new-device user
            // saw the empty body and had no clue notebooks were
            // streaming in. The earlier banner-fix landed on the legacy
            // LibraryScreen (lib/features/library/library_screen.dart)
            // which main.dart no longer renders — this is the
            // production screen.
            _SyncBanner(notifier: notebookNotifier),
            Expanded(
              child: asyncList.when(
                data: (_) => _Body(
                  entries: filtered,
                  gridView: _gridView,
                  favoriteIds: settings.favoriteNotebookIds,
                  onOpen: _openNotebook,
                  onCreate: _createNotebook,
                  onLongPress: _showNotebookMenu,
                  onToggleFavorite: _toggleFavorite,
                ),
                loading: () => _LoadingState(notifier: notebookNotifier),
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

  /// Import a .ncnote archive from disk: validates, optionally renames on
  /// title collision, registers a new notebook and refreshes the library.
  Future<void> _importNcnote() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ncnote', 'zip'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _toast('Impossibile leggere il file');
      return;
    }
    if (!mounted) return;

    // Show progress
    final ctx = context;
    showDialog(
      // ignore: use_build_context_synchronously
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Importazione in corso…'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // Validate ZIP integrity first
      SyncService.validateNcnoteArchive(bytes,
          context: 'import ${file.name}');

      final syncService = ref.read(syncServiceProvider);
      final fileService = ref.read(fileServiceProvider);
      if (syncService == null) {
        throw Exception('Servizio non disponibile');
      }

      // Parse to read metadata, document, pages, assets, symbols
      final parsed = syncService.parseNcnoteMetadata(bytes);
      final pages = syncService.extractAllPages(bytes);
      final assets = syncService.extractAllAssets(bytes);
      final symbols = syncService.extractSymbolLibraries(bytes);

      // Always assign a fresh ID so two devices/users importing the same
      // .ncnote don't end up sharing/colliding the notebook id (and so
      // the importer can keep their original alongside).
      final newId = const Uuid().v4();
      final originalTitle = parsed.metadata.title;
      // If a notebook with the same title already exists locally, mark
      // the import with a "(importato)" suffix so they're distinguishable
      // in the library list.
      final existingTitles = (ref.read(notebookListProvider).valueOrNull ?? const [])
          .map((e) => e.metadata.title.toLowerCase())
          .toSet();
      String newTitle = originalTitle;
      if (existingTitles.contains(originalTitle.toLowerCase())) {
        newTitle = '$originalTitle (importato)';
      }

      final newMeta = parsed.metadata.copyWith(
        id: newId,
        title: newTitle,
        modifiedAt: DateTime.now(),
      );

      // Re-pack with the new id/title so the on-disk file matches the
      // library entry. We reuse the existing builder to keep zip layout
      // identical to the rest of the app.
      final repacked = SyncService.buildPackageBytes(
        metadata: newMeta,
        document: parsed.document,
        pages: pages,
        assets: assets.isNotEmpty ? assets : null,
        symbolLibraries: symbols.isNotEmpty ? symbols : null,
      );

      // Build a remote path so subsequent sync can upload it.
      final safeName = newTitle
          .replaceAll(RegExp(r'[^\w\s\-]'), '')
          .replaceAll(RegExp(r'\s+'), '_')
          .toLowerCase();
      final remotePath =
          '${AppConfig.defaultRemotePath}${safeName}_$newId${AppConfig.fileExtension}';

      await fileService.saveNotebookFile(newId, repacked);
      await fileService.upsertNotebookMeta(
        id: newId,
        title: newTitle,
        remotePath: remotePath,
        localModifiedAt: newMeta.modifiedAt,
        // 'modified' so the next background sync uploads it.
        syncStatus: 'modified',
        fileSize: repacked.length,
        coverColor: newMeta.coverColor,
        paperType: newMeta.paperType,
        pageCount: newMeta.pageCount,
        createdAt: newMeta.createdAt,
      );

      if (!mounted) return;
      // ignore: use_build_context_synchronously
      Navigator.of(ctx).pop(); // dismiss spinner
      ref.read(notebookListProvider.notifier).refresh();
      _toast(
          'Importato: "$newTitle" (${pages.length} ${pages.length == 1 ? "pagina" : "pagine"})');
    } catch (e) {
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      Navigator.of(ctx).pop();
      _toast('Errore importazione: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  /// One-click favorite toggle from the cover star overlay. Avoids the
  /// long-press → bottom-sheet → tap → close round-trip for what is
  /// almost always the single most frequent library action.
  void _toggleFavorite(NotebookEntry entry) {
    HapticFeedback.selectionClick();
    ref.read(appSettingsProvider.notifier).toggleFavorite(entry.metadata.id);
  }

  void _showNotebookMenu(NotebookEntry entry) async {
    // Long-press is a hidden affordance; the bottom sheet feels more
    // intentional with a confirmatory haptic.
    HapticFeedback.lightImpact();
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
              _menuItem(ctx, 'palette', 'Cambia copertina', 'cover'),
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
      case 'cover':
        final newColor = await _pickCoverColor(
            initial: Color(entry.metadata.coverColor));
        if (newColor != null) {
          final argb = (newColor.a * 255).round() << 24 |
              (newColor.r * 255).round() << 16 |
              (newColor.g * 255).round() << 8 |
              (newColor.b * 255).round();
          await ref
              .read(notebookListProvider.notifier)
              .updateNotebookCover(entry, argb);
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

  /// Bottom sheet to pick one of the 8 preset cover colours.
  Future<Color?> _pickCoverColor({Color? initial}) async {
    return showModalBottomSheet<Color>(
      context: context,
      backgroundColor: HwThemeScope.of(context).paper0,
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
              const Text('Cambia copertina',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in HwTheme.covers)
                    GestureDetector(
                      onTap: () => Navigator.of(ctx).pop(c),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: c,
                          borderRadius: BorderRadius.circular(8),
                          border: initial?.toARGB32() == c.toARGB32()
                              ? Border.all(
                                  color:
                                      HwThemeScope.of(context).ink0,
                                  width: 2)
                              : null,
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
  final VoidCallback onImportTap;
  final String sortLabel;

  const _TopBar({
    required this.searchController,
    required this.onSearchChanged,
    required this.gridView,
    required this.onViewToggle,
    required this.onSortTap,
    required this.onSettingsTap,
    required this.onImportTap,
    required this.sortLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return LayoutBuilder(builder: (ctx, c) {
      final isCompact = c.maxWidth < 720;
      final hPad = isCompact ? 16.0 : 32.0;
      return Container(
        padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 14),
        decoration: BoxDecoration(
          color: p.paper0,
          border: Border(bottom: BorderSide(color: p.paper3)),
        ),
        child: Row(
          children: [
            Text('HandWriter',
                style: TextStyle(
                  fontSize: isCompact ? 18 : 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: p.ink0,
                )),
            const Spacer(),
            // Search field — full width on phone, fixed 240 on wide.
            if (isCompact)
              Expanded(
                child: HwTextField(
                  controller: searchController,
                  hint: 'Cerca…',
                  leading: const HwIcon('search', size: 16),
                  onChanged: onSearchChanged,
                  width: double.infinity,
                ),
              )
            else
              HwTextField(
                controller: searchController,
                hint: 'Cerca taccuini…',
                leading: const HwIcon('search', size: 16),
                onChanged: onSearchChanged,
                width: 240,
              ),
            const SizedBox(width: 8),
            // Wide-only: view toggle, sort label, divider, big "Importa".
            if (!isCompact) ...[
              const HwDivider(),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: p.paper2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  _SegBtn(
                      icon: 'grid',
                      selected: gridView,
                      onTap: () => onViewToggle(true)),
                  _SegBtn(
                      icon: 'list',
                      selected: !gridView,
                      onTap: () => onViewToggle(false)),
                ]),
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
              HwButton(
                leading: const HwIcon('export', size: 16),
                label: 'Importa',
                tooltip: 'Importa un file .ncnote',
                onPressed: onImportTap,
              ),
              const SizedBox(width: 4),
              HwButton.icon(
                  icon: const HwIcon('settings', size: 16),
                  tooltip: 'Impostazioni',
                  onPressed: onSettingsTap),
            ] else ...[
              // Compact: collapse view toggle / sort / import / settings
              // into a single overflow menu. Saves ~360px of bar width.
              HwButton.icon(
                icon: const HwIcon('more', size: 16),
                tooltip: 'Altro',
                onPressed: () => _compactMenu(ctx),
              ),
            ],
          ],
        ),
      );
    });
  }

  void _compactMenu(BuildContext context) async {
    final p = HwThemeScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.paper0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: HwIcon(gridView ? 'list' : 'grid', size: 18),
              title: Text(gridView ? 'Vista a lista' : 'Vista a griglia'),
              onTap: () {
                Navigator.of(ctx).pop();
                onViewToggle(!gridView);
              },
            ),
            ListTile(
              leading: const HwIcon('sort', size: 18),
              title: Text('Ordinamento: $sortLabel'),
              onTap: () {
                Navigator.of(ctx).pop();
                onSortTap();
              },
            ),
            const Divider(),
            ListTile(
              leading: const HwIcon('export', size: 18),
              title: const Text('Importa .ncnote…'),
              onTap: () {
                Navigator.of(ctx).pop();
                onImportTap();
              },
            ),
            ListTile(
              leading: const HwIcon('settings', size: 18),
              title: const Text('Impostazioni'),
              onTap: () {
                Navigator.of(ctx).pop();
                onSettingsTap();
              },
            ),
          ],
        ),
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
  final ValueChanged<NotebookEntry> onToggleFavorite;

  const _Body({
    required this.entries,
    required this.gridView,
    required this.favoriteIds,
    required this.onOpen,
    required this.onCreate,
    required this.onLongPress,
    required this.onToggleFavorite,
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
                    onToggleFavorite: () => onToggleFavorite(e),
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
  final VoidCallback onToggleFavorite;
  const _CoverTile({
    required this.entry,
    required this.favorite,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleFavorite,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Star overlay sits ABOVE the cover via Stack so its tap can be
        // intercepted before NotebookCover's onTap fires (the cover-wide
        // InkWell would otherwise swallow it). One-tap favorite was a
        // three-tap action via the long-press sheet pre-fix.
        SizedBox(
          width: 200,
          height: 260,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onLongPress: onLongPress,
                  behavior: HitTestBehavior.translucent,
                  child: NotebookCover(
                    color: Color(entry.metadata.coverColor),
                    title: entry.metadata.title,
                    // Hide the cover's built-in star — we render our own
                    // tappable one above.
                    favorite: false,
                    texture: _textureFor(entry.metadata.paperType),
                    width: 200,
                    height: 260,
                    onTap: onTap,
                  ),
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: onToggleFavorite,
                    customBorder: const CircleBorder(),
                    child: Tooltip(
                      message: favorite ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti',
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: HwIcon(
                          favorite ? 'star-filled' : 'star',
                          size: 18,
                          color: favorite
                              ? const Color(0xFFFFC857)
                              : const Color(0xCCFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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

/// Slim progress banner shown while a background sync with the server is
/// running. Returns [SizedBox.shrink] when idle so it costs no layout space.
class _SyncBanner extends StatelessWidget {
  final NotebookListNotifier notifier;
  const _SyncBanner({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: notifier.isSyncing,
      builder: (_, syncing, __) {
        if (!syncing) return const SizedBox.shrink();
        return Material(
          color: p.paper2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
            child: ValueListenableBuilder<({int done, int total})>(
              valueListenable: notifier.syncProgress,
              builder: (_, progress, __) {
                final label = progress.total == 0
                    ? 'Sincronizzazione con il server…'
                    : 'Scaricamento ${progress.done}/${progress.total} taccuini…';
                return Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.total == 0
                            ? null
                            : progress.done / progress.total,
                        color: p.ink0,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(fontSize: 13, color: p.ink1),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Loading view shown while [notebookListProvider] is still in
/// `AsyncValue.loading` (i.e. before the very first `_loadFromLocalDb`
/// returns). On a fresh install this is the brief window between app boot
/// and the DB-read completing; afterwards the body itself takes over with
/// the [_SyncBanner] above. If sync is already in flight (rare but possible
/// on fast SSDs where DB read races sync kickoff), show progress text so
/// the user sees the work happening immediately.
class _LoadingState extends StatelessWidget {
  final NotebookListNotifier notifier;
  const _LoadingState({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: notifier.isSyncing,
      builder: (_, syncing, __) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<({int done, int total})>(
                valueListenable: notifier.syncProgress,
                builder: (_, progress, __) {
                  return SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                      value: progress.total == 0
                          ? null
                          : progress.done / progress.total,
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<({int done, int total})>(
                valueListenable: notifier.syncProgress,
                builder: (_, progress, __) {
                  final label = !syncing
                      ? 'Caricamento taccuini…'
                      : progress.total == 0
                          ? 'Caricamento taccuini dal server…'
                          : 'Scaricamento ${progress.done}/${progress.total} taccuini…';
                  return Text(label, style: TextStyle(color: p.ink2));
                },
              ),
            ],
          ),
        );
      },
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
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

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
