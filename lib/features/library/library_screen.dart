import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/features/canvas/presentation/canvas_screen.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(notebookListProvider.notifier).refresh());
  }

  Future<void> _createNotebook() async {
    final titleController = TextEditingController();
    String paperType = 'lined_wide';
    int coverColor = 0xFF1565C0;

    final coverColors = [
      (0xFF1565C0, 'Blu'),
      (0xFFC62828, 'Rosso'),
      (0xFF2E7D32, 'Verde'),
      (0xFFF57F17, 'Giallo'),
      (0xFF6A1B9A, 'Viola'),
      (0xFF00838F, 'Teal'),
      (0xFFEF6C00, 'Arancio'),
      (0xFF424242, 'Grigio'),
      (0xFF37474F, 'Antracite'),
      (0xFF4E342E, 'Marrone'),
    ];

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.note_add_rounded, color: Colors.blue.shade600, size: 24),
              ),
              const SizedBox(width: 12),
              const Text('Nuovo Notebook'),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: 'Titolo',
                    hintText: 'Il mio notebook',
                    prefixIcon: const Icon(Icons.title),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                  ),
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 20),
                Text('Tipo di carta', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PaperChip(label: 'Bianco', icon: Icons.rectangle_outlined, value: 'blank', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Righe strette', icon: Icons.density_small, value: 'lined_narrow', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Righe larghe', icon: Icons.density_large, value: 'lined_wide', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Quadretti', icon: Icons.grid_on, value: 'grid', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Puntinato', icon: Icons.more_horiz, value: 'dotted', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                  ],
                ),
                const SizedBox(height: 20),
                Text('Colore copertina', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: coverColors.map((c) {
                    final isSelected = coverColor == c.$1;
                    return GestureDetector(
                      onTap: () => setDialogState(() => coverColor = c.$1),
                      child: Tooltip(
                        message: c.$2,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: Color(c.$1),
                            shape: BoxShape.circle,
                            border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
                            boxShadow: [
                              if (isSelected)
                                BoxShadow(color: Color(c.$1).withOpacity(0.5), blurRadius: 10, spreadRadius: 1),
                              BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, 2)),
                            ],
                          ),
                          child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Crea'),
            ),
          ],
        ),
      ),
    );

    if (result != true || titleController.text.trim().isEmpty) return;

    try {
      final entry = await ref.read(notebookListProvider.notifier).createNotebook(
        title: titleController.text.trim(),
        paperType: paperType,
        coverColor: coverColor,
      );
      if (mounted) _openNotebook(entry);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
    }
  }

  Future<void> _openNotebook(NotebookEntry entry) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20)],
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Apertura notebook...', style: TextStyle(fontSize: 14, decoration: TextDecoration.none, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );

    try {
      final syncService = ref.read(syncServiceProvider);
      if (syncService == null) return;

      final result = await syncService.downloadNotebookFull(entry.remotePath);
      ref.read(canvasProvider.notifier).openNotebook(
        metadata: result.metadata,
        document: result.document,
        pages: result.pages,
        remotePath: entry.remotePath,
        assets: result.assets,
        symbolLibraries: result.symbolLibraries.isNotEmpty
            ? result.symbolLibraries.map((j) => SymbolLibrary.fromJson(j)).toList()
            : null,
      );

      if (mounted) {
        Navigator.pop(context);
        Navigator.push(context, MaterialPageRoute(builder: (_) => const CanvasScreen()));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore apertura: $e')));
      }
    }
  }

  void _showNotebookMenu(NotebookEntry entry) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rinomina'),
              onTap: () { Navigator.pop(ctx); _renameNotebook(entry); },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
              title: Text('Elimina', style: TextStyle(color: Colors.red.shade400)),
              onTap: () { Navigator.pop(ctx); _deleteNotebook(entry); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameNotebook(NotebookEntry entry) async {
    final controller = TextEditingController(text: entry.metadata.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Rinomina'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.grey.shade50,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Salva')),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != entry.metadata.title) {
      try {
        await ref.read(notebookListProvider.notifier).renameNotebook(entry, result);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore rinomina: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteNotebook(NotebookEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Elimina notebook'),
        content: Text('Eliminare "${entry.metadata.title}"? L\'azione è irreversibile.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await ref.read(notebookListProvider.notifier).deleteNotebook(entry);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('"${entry.metadata.title}" eliminato')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore eliminazione: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notebooks = ref.watch(notebookListProvider);
    final creds = ref.watch(credentialsProvider);
    final screenWidth = MediaQuery.of(context).size.width;

    int crossAxisCount;
    if (screenWidth > 1200) crossAxisCount = 5;
    else if (screenWidth > 900) crossAxisCount = 4;
    else if (screenWidth > 600) crossAxisCount = 3;
    else crossAxisCount = 2;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF0277BD)]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit_note_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            const Text('HandWriter', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: Colors.grey.shade700),
            onPressed: () => ref.read(notebookListProvider.notifier).refresh(),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.account_circle_rounded, color: Colors.grey.shade700, size: 28),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              if (value == 'logout') ref.read(credentialsProvider.notifier).logout();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(creds?.username ?? '', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
                    Text(creds?.serverUrl ?? '', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout_rounded, size: 18),
                  SizedBox(width: 8),
                  Text('Disconnetti'),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNotebook,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuovo', style: TextStyle(fontWeight: FontWeight.w600)),
        elevation: 2,
      ),
      body: notebooks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text('Impossibile caricare i notebook', style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
              Text('$e', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => ref.read(notebookListProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Riprova'),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.note_add_rounded, size: 48, color: Colors.blue.shade300),
                  ),
                  const SizedBox(height: 20),
                  Text('Nessun notebook', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                  const SizedBox(height: 8),
                  Text('Crea il tuo primo notebook premendo il bottone +', style: TextStyle(color: Colors.grey.shade500)),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(notebookListProvider.notifier).refresh(),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 0.72,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                itemCount: list.length,
                itemBuilder: (_, index) => _NotebookCard(
                  entry: list[index],
                  onTap: () => _openNotebook(list[index]),
                  onLongPress: () => _showNotebookMenu(list[index]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  WIDGETS
// ═══════════════════════════════════════════════════════════════

class _NotebookCard extends StatelessWidget {
  final NotebookEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _NotebookCard({required this.entry, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final meta = entry.metadata;
    final coverColor = Color(meta.coverColor);
    final paperLabel = _paperLabel(meta.paperType);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapUp: (details) {
        onLongPress();
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cover
              Expanded(
                flex: 3,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [coverColor, coverColor.withOpacity(0.8)],
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Notebook lines decoration
                      Positioned(
                        left: 16,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 1.5, color: Colors.white.withOpacity(0.15)),
                      ),
                      Positioned(
                        left: 20,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 0.5, color: Colors.white.withOpacity(0.1)),
                      ),
                      // Title on cover
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 16, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              meta.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            const Spacer(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '${meta.pageCount} pag.',
                                    style: const TextStyle(color: Colors.white, fontSize: 11),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: onLongPress,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(Icons.more_vert, color: Colors.white, size: 18),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Info bar
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.grid_on, size: 11, color: Colors.grey.shade500),
                        const SizedBox(width: 3),
                        Text(paperLabel, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                        const Spacer(),
                        Text(
                          _formatDate(meta.modifiedAt),
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _paperLabel(String type) {
    switch (type) {
      case 'lined_narrow': return 'Righe strette';
      case 'lined_wide': case 'lined': return 'Righe larghe';
      case 'grid': return 'Quadretti';
      case 'dotted': return 'Puntinato';
      default: return 'Bianco';
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Adesso';
    if (diff.inHours < 1) return '${diff.inMinutes} min fa';
    if (diff.inDays < 1) return '${diff.inHours}h fa';
    if (diff.inDays < 7) return '${diff.inDays}g fa';
    return '${date.day}/${date.month}/${date.year}';
  }
}

class _PaperChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final String value;
  final String selected;
  final ValueChanged<String> onTap;

  const _PaperChip({
    required this.label,
    required this.icon,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = value == selected;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isSelected ? Colors.blue.shade50 : Colors.grey.shade100,
          border: Border.all(color: isSelected ? Colors.blue.shade300 : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isSelected ? Colors.blue.shade600 : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? Colors.blue.shade700 : Colors.grey.shade700,
            )),
          ],
        ),
      ),
    );
  }
}
