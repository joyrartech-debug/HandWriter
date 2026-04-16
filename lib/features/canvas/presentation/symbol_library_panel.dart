import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';

/// Full-featured symbol library side panel.
/// Shows libraries in a left column, symbols in a grid on the right.
/// Supports: multiple libraries, previews, insert on tap, rename/delete.
class SymbolLibraryPanel extends ConsumerStatefulWidget {
  final Offset insertPos;
  final VoidCallback onClose;

  const SymbolLibraryPanel({
    super.key,
    required this.insertPos,
    required this.onClose,
  });

  @override
  ConsumerState<SymbolLibraryPanel> createState() => _SymbolLibraryPanelState();
}

class _SymbolLibraryPanelState extends ConsumerState<SymbolLibraryPanel> {
  String? _selectedLibId;
  final _previewCache = <String, ui.Image>{};

  @override
  void initState() {
    super.initState();
    // Select first library by default
    final libs = ref.read(canvasProvider)?.symbolLibraries ?? [];
    _selectedLibId = libs.isNotEmpty ? libs.first.id : null;
  }

  @override
  void dispose() {
    for (final img in _previewCache.values) {
      img.dispose();
    }
    super.dispose();
  }

  void _ensurePreviewsFor(SymbolLibrary lib, Map<String, ui.Image> imageCache) {
    for (final sym in lib.symbols) {
      if (!_previewCache.containsKey(sym.id)) {
        _renderSymbolPreview(sym, imageCache);
      }
    }
  }

  Future<void> _renderSymbolPreview(ReusableSymbol symbol, Map<String, ui.Image> imageCache) async {
    const previewSize = 64.0;
    if (symbol.bounds.width <= 0 || symbol.bounds.height <= 0) return;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Fill white background
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, previewSize, previewSize),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    final scaleX = (previewSize - 8) / symbol.bounds.width;
    final scaleY = (previewSize - 8) / symbol.bounds.height;
    final scale = min(scaleX, scaleY);
    final dx = 4.0 - symbol.bounds.left * scale + (previewSize - 8 - symbol.bounds.width * scale) / 2;
    final dy = 4.0 - symbol.bounds.top * scale + (previewSize - 8 - symbol.bounds.height * scale) / 2;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale);

    for (final element in symbol.elements) {
      element.map(
        stroke: (e) {
          if (e.data.points.length < 2) return;
          final paint = Paint()
            ..color = Color(e.data.color)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (e.data.baseWidth * 0.6).clamp(0.5, 4.0)
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true;
          final path = Path()
            ..moveTo(e.data.points.first.x, e.data.points.first.y);
          for (int i = 1; i < e.data.points.length; i++) {
            path.lineTo(e.data.points[i].x, e.data.points[i].y);
          }
          canvas.drawPath(path, paint);
        },
        shape: (e) {
          final d = e.data;
          final paint = Paint()
            ..color = Color(d.strokeColor)
            ..style = PaintingStyle.stroke
            ..strokeWidth = (d.strokeWidth * 0.6).clamp(0.5, 3.0)
            ..isAntiAlias = true;
          switch (d.shapeType) {
            case 'rectangle':
              canvas.drawRect(Rect.fromLTRB(d.x1, d.y1, d.x2, d.y2), paint);
              break;
            case 'circle':
              final cx = (d.x1 + d.x2) / 2;
              final cy = (d.y1 + d.y2) / 2;
              final r = Offset(d.x2 - d.x1, d.y2 - d.y1).distance / 2;
              canvas.drawCircle(Offset(cx, cy), r, paint);
              break;
            case 'line':
            case 'arrow':
              canvas.drawLine(Offset(d.x1, d.y1), Offset(d.x2, d.y2), paint);
              break;
            case 'triangle':
              final path = Path()
                ..moveTo((d.x1 + d.x2) / 2, d.y1)
                ..lineTo(d.x1, d.y2)
                ..lineTo(d.x2, d.y2)
                ..close();
              canvas.drawPath(path, paint);
              break;
          }
        },
        text: (e) {
          final tp = TextPainter(
            text: TextSpan(
              text: e.data.content,
              style: TextStyle(fontSize: 8, color: Color(e.data.color)),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(e.data.x, e.data.y));
        },
        image: (_) {},
      );
    }
    canvas.restore();

    final picture = recorder.endRecording();
    final img = await picture.toImage(previewSize.toInt(), previewSize.toInt());
    if (mounted) {
      setState(() => _previewCache[symbol.id] = img);
    }
  }

  void _createLibrary() async {
    final name = await _promptName(context, 'Nuova libreria', 'Inserisci il nome della libreria');
    if (name == null || name.trim().isEmpty) return;
    ref.read(canvasProvider.notifier).createSymbolLibrary(name.trim());
    final libs = ref.read(canvasProvider)?.symbolLibraries ?? [];
    if (libs.isNotEmpty && mounted) setState(() => _selectedLibId = libs.last.id);
  }

  void _renameLibrary(SymbolLibrary lib) async {
    final name = await _promptName(context, 'Rinomina libreria', 'Nuovo nome', initial: lib.name);
    if (name == null || name.trim().isEmpty) return;
    ref.read(canvasProvider.notifier).renameSymbolLibrary(lib.id, name.trim());
  }

  void _deleteLibrary(SymbolLibrary lib) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina libreria'),
        content: Text('Elimina "${lib.name}" e tutti i suoi simboli?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(canvasProvider.notifier).deleteSymbolLibrary(lib.id);
    if (mounted) setState(() => _selectedLibId = null);
  }

  void _deleteSymbol(String libId, String symId) {
    ref.read(canvasProvider.notifier).deleteSymbolFromLibrary(libId, symId);
    setState(() => _previewCache.remove(symId));
  }

  void _renameSymbol(String libId, ReusableSymbol sym) async {
    final name = await _promptName(context, 'Rinomina simbolo', 'Nuovo nome', initial: sym.name);
    if (name == null || name.trim().isEmpty) return;
    ref.read(canvasProvider.notifier).renameSymbol(libId, sym.id, name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(canvasProvider);
    if (state == null) return const SizedBox.shrink();

    final libs = state.symbolLibraries;
    final selLib = libs.where((l) => l.id == _selectedLibId).firstOrNull;
    if (selLib != null) _ensurePreviewsFor(selLib, state.imageCache);

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 560,
        height: 440,
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9FA),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            // ── Title bar ──
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.library_books_rounded, size: 18, color: Colors.blue),
                  const SizedBox(width: 8),
                  const Text('Librerie simboli',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
            // ── Body: libs list + symbols grid ──
            Expanded(
              child: Row(
                children: [
                  // Library list
                  SizedBox(
                    width: 150,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(right: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: libs.isEmpty
                                ? const Center(
                                    child: Text('Nessuna libreria',
                                        style: TextStyle(fontSize: 11, color: Colors.grey),
                                        textAlign: TextAlign.center),
                                  )
                                : ListView.builder(
                                    itemCount: libs.length,
                                    itemBuilder: (ctx, i) {
                                      final lib = libs[i];
                                      final sel = lib.id == _selectedLibId;
                                      return GestureDetector(
                                        onTap: () => setState(() => _selectedLibId = lib.id),
                                        onSecondaryTapDown: (_) => _showLibContextMenu(context, lib),
                                        child: Container(
                                          color: sel ? const Color(0xFFE3F2FD) : Colors.transparent,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                          child: Row(
                                            children: [
                                              Icon(Icons.folder_rounded, size: 15,
                                                  color: sel ? Colors.blue : Colors.grey.shade500),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(lib.name,
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                                                      color: sel ? Colors.blue.shade800 : Colors.black87,
                                                    ),
                                                    overflow: TextOverflow.ellipsis),
                                              ),
                                              Text('${lib.symbols.length}',
                                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.add, size: 14),
                                label: const Text('Nuova', style: TextStyle(fontSize: 12)),
                                onPressed: _createLibrary,
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Symbols grid
                  Expanded(
                    child: selLib == null
                        ? const Center(
                            child: Text('Seleziona una libreria',
                                style: TextStyle(color: Colors.grey, fontSize: 13)),
                          )
                        : selLib.symbols.isEmpty
                            ? const Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star_border_rounded, size: 40, color: Colors.grey),
                                    SizedBox(height: 8),
                                    Text('Nessun simbolo\nSeleziona elementi con il lazo e premi ✚',
                                        style: TextStyle(color: Colors.grey, fontSize: 12),
                                        textAlign: TextAlign.center),
                                  ],
                                ),
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.all(12),
                                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 90,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 0.75,
                                ),
                                itemCount: selLib.symbols.length,
                                itemBuilder: (ctx, i) {
                                  final sym = selLib.symbols[i];
                                  return _SymbolTile(
                                    symbol: sym,
                                    preview: _previewCache[sym.id],
                                    onInsert: () {
                                      ref.read(canvasProvider.notifier).setPendingSymbol(sym);
                                      widget.onClose();
                                    },
                                    onDelete: () => _deleteSymbol(selLib.id, sym.id),
                                    onRename: () => _renameSymbol(selLib.id, sym),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
            // ── Bottom bar: add symbol from selection hint ──
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Text(
                    'Seleziona elementi con il lazo → ✚ per salvare nella libreria attiva',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLibContextMenu(BuildContext context, SymbolLibrary lib) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu(
      context: context,
      position: RelativeRect.fromSize(
        const Rect.fromLTWH(150, 100, 0, 0), overlay.size),
      items: [
        PopupMenuItem(
          onTap: () => _renameLibrary(lib),
          child: const Row(children: [Icon(Icons.edit, size: 16), SizedBox(width: 8), Text('Rinomina')]),
        ),
        PopupMenuItem(
          onTap: () => _deleteLibrary(lib),
          child: Row(children: [
            Icon(Icons.delete_outline, size: 16, color: Colors.red.shade400),
            const SizedBox(width: 8),
            Text('Elimina', style: TextStyle(color: Colors.red.shade400)),
          ]),
        ),
      ],
    );
  }
}

class _SymbolTile extends StatelessWidget {
  final ReusableSymbol symbol;
  final ui.Image? preview;
  final VoidCallback onInsert;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  const _SymbolTile({
    required this.symbol,
    required this.preview,
    required this.onInsert,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onInsert,
      onSecondaryTapDown: (_) => _showContextMenu(context),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: preview != null
                    ? RawImage(image: preview, fit: BoxFit.contain)
                    : const Center(child: SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 1.5))),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            symbol.name,
            style: const TextStyle(fontSize: 10, color: Colors.black87),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            maxLines: 1,
          ),
        ],
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    showMenu(
      context: context,
      position: const RelativeRect.fromLTRB(200, 200, 0, 0),
      items: [
        PopupMenuItem(
          onTap: onInsert,
          child: const Row(children: [Icon(Icons.add_circle_outline, size: 16), SizedBox(width: 8), Text('Inserisci')]),
        ),
        PopupMenuItem(
          onTap: onRename,
          child: const Row(children: [Icon(Icons.edit, size: 16), SizedBox(width: 8), Text('Rinomina')]),
        ),
        PopupMenuItem(
          onTap: onDelete,
          child: Row(children: [
            Icon(Icons.delete_outline, size: 16, color: Colors.red.shade400),
            const SizedBox(width: 8),
            Text('Elimina', style: TextStyle(color: Colors.red.shade400)),
          ]),
        ),
      ],
    );
  }
}

Future<String?> _promptName(BuildContext context, String title, String hint, {String initial = ''}) async {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
