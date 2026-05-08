import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/app_settings_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/ui/theme/hw_icons.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';
import 'package:handwriter/ui/primitives/hw_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Redesigned settings screen — left rail of sections + content panel.
class SettingsScreenV2 extends ConsumerStatefulWidget {
  const SettingsScreenV2({super.key});

  @override
  ConsumerState<SettingsScreenV2> createState() => _SettingsScreenV2State();
}

class _SettingsScreenV2State extends ConsumerState<SettingsScreenV2> {
  String _section = 'general';

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Scaffold(
      backgroundColor: p.paper1,
      body: SafeArea(
        child: Row(
          children: [
            _Rail(
              section: _section,
              onSelect: (s) => setState(() => _section = s),
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(48, 40, 48, 80),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: switch (_section) {
                    'general' => _GeneralSection(),
                    'input' => _InputSection(),
                    'sync' => _SyncSection(),
                    'shortcuts' => _ShortcutsSection(),
                    'storage' => _StorageSection(),
                    'advanced' => const _AdvancedSection(),
                    'about' => _AboutSection(),
                    _ => _GeneralSection(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final String section;
  final ValueChanged<String> onSelect;
  final VoidCallback onClose;
  const _Rail({
    required this.section,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    const items = [
      ('general', 'Generale', 'settings'),
      ('input', 'Stylus & input', 'pen'),
      ('sync', 'Sincronia', 'cloud'),
      ('storage', 'Spazio', 'pages'),
      ('shortcuts', 'Scorciatoie', 'keyboard'),
      ('advanced', 'Avanzate', 'arrow'),
      ('about', 'Informazioni', 'help'),
    ];
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: p.paper0,
        border: Border(right: BorderSide(color: p.paper3)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HwButton(
            leading: const HwIcon('chevron-left', size: 16),
            label: 'Libreria',
            onPressed: onClose,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Impostazioni',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                  color: p.ink2),
            ),
          ),
          for (final item in items)
            _RailItem(
              id: item.$1,
              label: item.$2,
              icon: item.$3,
              selected: section == item.$1,
              onTap: () => onSelect(item.$1),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final String id, label, icon;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({
    required this.id,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? p.paper2 : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              HwIcon(icon, size: 14, color: selected ? p.ink0 : p.ink1),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? p.ink0 : p.ink1,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Text(title,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: p.ink0,
          )),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String? sub;
  final Widget control;
  const _Row({required this.title, this.sub, required this.control});
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.paper2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14, color: p.ink0, fontWeight: FontWeight.w500)),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(sub!,
                      style: TextStyle(
                          fontSize: 12, color: p.ink2, height: 1.5)),
                ],
              ],
            ),
          ),
          control,
        ],
      ),
    );
  }
}

class _GeneralSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HwThemeScope.of(context);
    final settings = ref.watch(appSettingsProvider);
    final variant = HwThemeScope.variantOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Generale'),
        Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tema',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.6,
                      color: p.ink2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final t in const [
                    ('light', 'Chiaro', 'sun', HwThemeVariant.light),
                    ('paper', 'Carta', 'pages', HwThemeVariant.paper),
                    ('dark', 'Scuro', 'moon', HwThemeVariant.dark),
                  ]) ...[
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          // Map our variant onto Flutter's ThemeMode for
                          // persistence; the wrapper picks the actual palette.
                          ref.read(appSettingsProvider.notifier).setThemeMode(
                                t.$4 == HwThemeVariant.dark
                                    ? ThemeMode.dark
                                    : t.$4 == HwThemeVariant.paper
                                        ? ThemeMode.system
                                        : ThemeMode.light,
                              );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 20),
                          margin: const EdgeInsets.only(right: 12),
                          decoration: BoxDecoration(
                            color: variant == t.$4
                                ? p.accentSoft
                                : p.paper0,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: variant == t.$4
                                  ? p.accent
                                  : p.paper3,
                              width: variant == t.$4 ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              HwIcon(t.$3, size: 20, color: p.ink0),
                              const SizedBox(height: 8),
                              Text(t.$2,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: p.ink0,
                                      fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        _Row(
            title: 'Lingua',
            sub: "Lingua dell'interfaccia",
            control: HwButton(
              label: 'Italiano',
              trailing: const HwIcon('chevron-down', size: 12),
              style: HwButtonStyle.solid,
              onPressed: () {},
            )),
        _Row(
            title: 'Preferiti per primi',
            sub: 'Mostra i taccuini preferiti in cima alla libreria',
            control: HwSwitch(
              value: settings.favoritesFirst,
              onChanged: (v) =>
                  ref.read(appSettingsProvider.notifier).setFavoritesFirst(v),
            )),
      ],
    );
  }
}

class _InputSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Stylus & input'),
        _Row(
            title: 'Solo stylus',
            sub:
                'Ignora il tocco del dito durante la scrittura. Pinch e pan continuano a funzionare con due dita.',
            control: HwSwitch(value: true, onChanged: (_) {})),
        _Row(
            title: 'Palm rejection',
            sub: 'Riconoscimento automatico del palmo appoggiato',
            control: HwSwitch(value: true, onChanged: (_) {})),
        _Row(
            title: 'Pressione → spessore',
            sub: 'Modulazione di tratto in base alla pressione dello stylus',
            control: HwSwitch(value: true, onChanged: (_) {})),
        _Row(
            title: 'Tilt → calligrafia',
            sub:
                "L'inclinazione dello stylus altera larghezza e angolo del tratto",
            control: HwSwitch(value: true, onChanged: (_) {})),
        _Row(
            title: 'Continuazione tratto',
            sub: 'Compensa brevi interruzioni del sensore (es. punto della i)',
            control: HwSwitch(value: true, onChanged: (_) {})),
      ],
    );
  }
}

class _SyncSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Sincronia'),
        Text(
          'I tuoi taccuini sono salvati in locale. Sincronizza con un server WebDAV per accedervi da più dispositivi.',
          style: TextStyle(fontSize: 14, color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.paper0,
            border: Border.all(color: p.paper3),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: HwTheme.syncOk.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Center(
                    child: HwIcon('cloud-check',
                        size: 20, color: HwTheme.syncOk)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('WebDAV',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: p.ink0)),
                    const SizedBox(height: 2),
                    Text('Connesso · sync ogni 90s in libreria, 2s nell\'editor',
                        style: TextStyle(fontSize: 12, color: p.ink2)),
                  ],
                ),
              ),
              HwButton(
                  label: 'Disconnetti',
                  style: HwButtonStyle.solid,
                  onPressed: () {}),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _Row(
            title: 'Sincronia automatica',
            control: HwSwitch(value: true, onChanged: (_) {})),
        _Row(
            title: 'Sincronia delta',
            sub: 'Trasmette solo le pagine modificate',
            control: HwSwitch(value: true, onChanged: (_) {})),
      ],
    );
  }
}

class _ShortcutsSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    const shortcuts = [
      ('Penna', 'P'),
      ('Annulla', '⌘ Z'),
      ('Pennello', 'B'),
      ('Ripeti', '⌘ ⇧ Z'),
      ('Gomma', 'E'),
      ('Seleziona tutto', '⌘ A'),
      ('Lasso', 'L'),
      ('Copia', '⌘ C'),
      ('Mano', 'H'),
      ('Taglia', '⌘ X'),
      ('Testo', 'T'),
      ('Incolla', '⌘ V'),
      ('Forma', 'S'),
      ('Duplica', '⌘ D'),
      ('Cambia pagina', '↑ ↓'),
      ('Salva', '⌘ S'),
      ('Adatta', '⌘ 0'),
      ('Cheat sheet', '?'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Scorciatoie da tastiera'),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 0,
            crossAxisSpacing: 32,
            mainAxisExtent: 40,
          ),
          itemCount: shortcuts.length,
          itemBuilder: (_, i) {
            final s = shortcuts[i];
            return Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.paper2)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.$1, style: TextStyle(fontSize: 13, color: p.ink0)),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: p.paper2,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(s.$2,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: HwTheme.fontMono,
                          color: p.ink1,
                        )),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _StorageSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Spazio'),
        _Row(
            title: 'Pulisci cache',
            sub: 'Rimuove i file temporanei. I taccuini non vengono toccati.',
            control: HwButton(
                label: 'Pulisci',
                style: HwButtonStyle.solid,
                onPressed: () {})),
        _Row(
            title: 'Cestino',
            sub: 'Taccuini eliminati, ripristinabili',
            control: HwButton(
                label: 'Apri cestino',
                style: HwButtonStyle.solid,
                onPressed: () {})),
      ],
    );
  }
}

/// Manual heal/recovery actions for the rare case where a notebook gets
/// stuck in a sync loop because of durable server-side corruption that
/// the verified upload/download paths can no longer prevent (i.e. bytes
/// that were already poisoned before the verifications shipped).
class _AdvancedSection extends ConsumerWidget {
  const _AdvancedSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HwThemeScope.of(context);
    final notebooksAsync = ref.watch(notebookListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Avanzate'),
        Text(
          'Strumenti di recupero per casi rari di taccuino bloccato in '
          'sincronia. Usali solo se il sync continua a fallire dopo un '
          'normale "Forza sync" dalla libreria.',
          style: TextStyle(fontSize: 14, color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Forza ricarica taccuino dal server',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: p.ink0),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            'Riscarica tutto il contenuto del taccuino dalla cartella '
            'delta del server e sovrascrive la copia locale. Utile se il '
            'count pagine sembra sbagliato o il taccuino non si apre. '
            'Non perde dati lato server.',
            style: TextStyle(fontSize: 12, color: p.ink2, height: 1.5),
          ),
        ),
        notebooksAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Text('Errore: $e',
              style: TextStyle(fontSize: 12, color: p.ink2)),
          data: (entries) => Column(
            children: [
              for (final entry in entries)
                _Row(
                  title: entry.metadata.title,
                  sub: '${entry.metadata.pageCount} pagine',
                  control: HwButton(
                    label: 'Ricarica',
                    style: HwButtonStyle.solid,
                    onPressed: () =>
                        _forceReload(context, ref, entry.metadata.id,
                            entry.metadata.title, entry.remotePath),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _forceReload(BuildContext context, WidgetRef ref,
      String notebookId, String title, String remotePath) async {
    // Block reload of the currently-open notebook — replacing its on-disk
    // bytes while the canvas holds an older state in memory leads to
    // a save-after-reload that re-publishes the stale state.
    final canvas = ref.read(canvasProvider);
    if (canvas != null && canvas.metadata.id == notebookId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Chiudi il taccuino prima di ricaricarlo dal server.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Ricaricare "$title"?'),
        content: const Text(
          'Riscarica metadata, document, pagine e asset dalla cartella '
          'delta del server. La copia locale viene sostituita.\n\n'
          'Modifiche locali non ancora sincronizzate verranno perse. '
          'Continuare?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ricarica')),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
        content: Text('Ricarica "$title" in corso…'),
        duration: const Duration(seconds: 30)));

    try {
      final syncService = ref.read(syncServiceProvider);
      final fileService = ref.read(fileServiceProvider);
      if (syncService == null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(const SnackBar(
            content: Text('Non connesso a un server WebDAV.')));
        return;
      }

      final result = await syncService.downloadExplodedFull(notebookId);
      final bytes = SyncService.buildPackageBytes(
        metadata: result.metadata,
        document: result.document,
        pages: result.pages,
        assets: result.assets,
        symbolLibraries: result.symbolLibraries,
      );
      await fileService.saveNotebookFile(notebookId, bytes);
      await fileService.upsertNotebookMeta(
        id: notebookId,
        title: result.metadata.title,
        remotePath: remotePath,
        localModifiedAt: result.metadata.modifiedAt,
        syncStatus: 'synced',
        fileSize: bytes.length,
        coverColor: result.metadata.coverColor,
        paperType: result.metadata.paperType,
        pageCount: result.metadata.pageCount,
        createdAt: result.metadata.createdAt,
      );

      // Wipe the per-notebook sync caches so the next open re-runs the
      // delta diff from a clean slate (no stale ETags blocking refresh).
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('delta_meta_etag_$notebookId');
      await prefs.remove('last_page_etags_$notebookId');

      // Refresh the library card to reflect the new pageCount immediately.
      await ref.read(notebookListProvider.notifier).refresh();

      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text(
              '"$title" ricaricato — ${result.metadata.pageCount} pagine.')));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
          content: Text('Ricarica fallita: $e'),
          duration: const Duration(seconds: 6)));
    }
  }
}

class _AboutSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Informazioni'),
        Text('HandWriter',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600, color: p.ink0)),
        const SizedBox(height: 8),
        Text('App di scrittura a mano, local-first.',
            style: TextStyle(fontSize: 14, color: p.ink1, height: 1.7)),
        const SizedBox(height: 4),
        Text('Funziona offline; la sincronia con WebDAV è facoltativa.',
            style: TextStyle(fontSize: 14, color: p.ink1, height: 1.7)),
      ],
    );
  }
}
