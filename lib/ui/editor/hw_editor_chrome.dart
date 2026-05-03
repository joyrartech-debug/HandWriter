import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:handwriter/core/providers/canvas_state.dart';
import 'package:handwriter/ui/primitives/hw_button.dart';
import 'package:handwriter/ui/primitives/sync_badge.dart';
import 'package:handwriter/ui/theme/hw_icons.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';

/// Top bar for the editor: Library back button, notebook title (with cover
/// chip + sync badge), undo/redo, page indicator, symbols, export, more.
class HwEditorTopBar extends StatelessWidget {
  final String notebookTitle;
  final Color coverColor;
  final int currentPage;
  final int totalPages;
  final bool dirty;
  final bool canUndo;
  final bool canRedo;
  final HwSyncState syncState;
  final VoidCallback? onBack;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback? onPagesTap;
  final VoidCallback? onSymbolsTap;
  final VoidCallback? onExportTap;
  final VoidCallback? onMoreTap;

  const HwEditorTopBar({
    super.key,
    required this.notebookTitle,
    required this.coverColor,
    required this.currentPage,
    required this.totalPages,
    required this.dirty,
    required this.canUndo,
    required this.canRedo,
    required this.syncState,
    this.onBack,
    this.onUndo,
    this.onRedo,
    this.onPagesTap,
    this.onSymbolsTap,
    this.onExportTap,
    this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return LayoutBuilder(builder: (ctx, c) {
      final isCompact = c.maxWidth < 720;
      return Container(
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: isCompact ? 6 : 12),
        decoration: BoxDecoration(
          color: p.paper0,
          border: Border(bottom: BorderSide(color: p.paper3)),
        ),
        child: Row(
          children: [
            // Back button — icon-only on compact to save space.
            if (isCompact)
              HwButton.icon(
                icon: const HwIcon('chevron-left', size: 16),
                tooltip: 'Torna alla libreria',
                onPressed: onBack,
              )
            else
              HwButton(
                leading: const HwIcon('chevron-left', size: 16),
                label: 'Libreria',
                onPressed: onBack,
                tooltip: 'Torna alla libreria',
              ),
            const SizedBox(width: 4),
            const HwDivider(),
            const SizedBox(width: 8),
            // Cover chip + title
            Container(
              width: 14,
              height: 18,
              decoration: BoxDecoration(
                color: coverColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(1),
                  bottomLeft: Radius.circular(1),
                  topRight: Radius.circular(3),
                  bottomRight: Radius.circular(3),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                notebookTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.ink0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SyncBadge(state: syncState),
            if (dirty && !isCompact) ...[
              const SizedBox(width: 8),
              const HwPill(
                label: 'Non salvato',
                background: Color(0x33B68A2D),
                foreground: Color(0xFF7C5E1F),
              ),
            ],
            const Spacer(),
            // Always-visible essentials
            HwButton.icon(
              icon: const HwIcon('undo', size: 16),
              tooltip: 'Annulla',
              onPressed: canUndo ? onUndo : null,
            ),
            HwButton.icon(
              icon: const HwIcon('redo', size: 16),
              tooltip: 'Ripeti',
              onPressed: canRedo ? onRedo : null,
            ),
            const SizedBox(width: 4),
            const HwDivider(),
            const SizedBox(width: 4),
            // Page indicator: show with label on wide, icon-only on compact.
            if (isCompact)
              HwButton.icon(
                icon: const HwIcon('pages', size: 16),
                tooltip: 'Tutte le pagine',
                onPressed: onPagesTap,
              )
            else
              HwButton(
                leading: const HwIcon('pages', size: 16),
                label:
                    '${currentPage.toString().padLeft(2, '0')} / $totalPages',
                onPressed: onPagesTap,
                tooltip: 'Tutte le pagine',
              ),
            // Secondary actions: keep visible on wide, fold into the
            // overflow menu on compact.
            if (!isCompact) ...[
              const SizedBox(width: 4),
              const HwDivider(),
              const SizedBox(width: 4),
              HwButton.icon(
                  icon: const HwIcon('symbol', size: 16),
                  tooltip: 'Simboli',
                  onPressed: onSymbolsTap),
              HwButton.icon(
                  icon: const HwIcon('export', size: 16),
                  tooltip: 'Esporta',
                  onPressed: onExportTap),
            ],
            HwButton.icon(
              icon: const HwIcon('more', size: 16),
              tooltip: 'Altro',
              onPressed: isCompact
                  ? () => _showCompactOverflow(
                        ctx,
                        onSymbolsTap: onSymbolsTap,
                        onExportTap: onExportTap,
                        onMoreTap: onMoreTap,
                      )
                  : onMoreTap,
            ),
          ],
        ),
      );
    });
  }

  /// Compact-mode overflow: bundles symbols + export + the original
  /// "more" menu in a single popup so phone-width devices don't need
  /// to fit 7 buttons in the top bar.
  void _showCompactOverflow(
    BuildContext context, {
    VoidCallback? onSymbolsTap,
    VoidCallback? onExportTap,
    VoidCallback? onMoreTap,
  }) async {
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
              leading: const HwIcon('symbol', size: 18),
              title: const Text('Simboli'),
              onTap: () {
                Navigator.of(ctx).pop();
                onSymbolsTap?.call();
              },
            ),
            ListTile(
              leading: const HwIcon('export', size: 18),
              title: const Text('Esporta'),
              onTap: () {
                Navigator.of(ctx).pop();
                onExportTap?.call();
              },
            ),
            const Divider(),
            ListTile(
              leading: const HwIcon('more', size: 18),
              title: const Text('Altro…'),
              onTap: () {
                Navigator.of(ctx).pop();
                onMoreTap?.call();
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum DockPosition { floating, left, right, top }

/// Floating tool dock — circular pill with all tools + shape-guess toggle.
/// Tap a tool to select; tap again (or popOpen=true) opens the tool popup.
class HwFloatingDock extends StatelessWidget {
  final CanvasTool currentTool;
  final ValueChanged<CanvasTool> onToolChanged;
  final VoidCallback onActiveTap;
  final Color activeInkColor;
  final DockPosition position;
  final bool shapeGuess;
  final ValueChanged<bool> onShapeGuessChanged;

  const HwFloatingDock({
    super.key,
    required this.currentTool,
    required this.onToolChanged,
    required this.onActiveTap,
    required this.activeInkColor,
    required this.shapeGuess,
    required this.onShapeGuessChanged,
    this.position = DockPosition.floating,
  });

  @override
  Widget build(BuildContext context) {
    final isVert =
        position == DockPosition.left || position == DockPosition.right;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: HwThemeScope.of(context).paper0,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: HwThemeScope.of(context).paper3),
        boxShadow: hwShadow2(HwThemeScope.of(context).brightness),
      ),
      child: Flex(
        direction: isVert ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolBtn(context, CanvasTool.pen, 'pen', 'Penna · P'),
          _toolBtn(
              context, CanvasTool.calligraphy, 'calligraphy', 'Calligrafia'),
          _toolBtn(context, CanvasTool.highlighter, 'highlighter',
              'Evidenziatore'),
          _gap(isVert, context),
          // Default eraser is "per stroke" — full-stroke removal is what
          // the user reaches for most often. The popup still lets them
          // flip to per-area mode.
          _toolBtn(
              context, CanvasTool.eraserStroke, 'eraser', 'Gomma · E'),
          _toolBtn(context, CanvasTool.lasso, 'lasso', 'Lasso · L'),
          _toolBtn(context, CanvasTool.text, 'text', 'Testo · T'),
          _toolBtn(context, CanvasTool.shape, 'shape', 'Forma · S'),
          _toolBtn(context, CanvasTool.pan, 'hand', 'Mano · H'),
          _gap(isVert, context),
          _shapeGuessBtn(context),
        ],
      ),
    );
  }

  Widget _gap(bool isVert, BuildContext context) {
    final p = HwThemeScope.of(context);
    return Padding(
      padding: isVert
          ? const EdgeInsets.symmetric(vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        width: isVert ? 20 : 1,
        height: isVert ? 1 : 20,
        color: p.paper3,
      ),
    );
  }

  static const Set<CanvasTool> _inkTools = {
    CanvasTool.pen,
    CanvasTool.ballpoint,
    CanvasTool.brush,
    CanvasTool.calligraphy,
    CanvasTool.highlighter,
  };

  Widget _toolBtn(
      BuildContext context, CanvasTool tool, String icon, String tooltip) {
    // The eraser dock button represents both per-stroke and per-area
    // erasers — the user picks the mode in the popup. Highlight the
    // single button whichever variant is active.
    final isEraserBtn = tool == CanvasTool.eraserStroke ||
        tool == CanvasTool.eraserStandard;
    final isEraserActive = currentTool == CanvasTool.eraserStroke ||
        currentTool == CanvasTool.eraserStandard;
    final active = isEraserBtn ? isEraserActive : currentTool == tool;
    final p = HwThemeScope.of(context);
    final isInkTool = _inkTools.contains(tool);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (active) {
              onActiveTap();
            } else {
              onToolChanged(tool);
            }
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: active ? p.ink0 : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                HwIcon(icon,
                    size: 18, color: active ? p.paper0 : p.ink1),
                // Color stripe under active ink tool
                if (active && isInkTool)
                  Positioned(
                    bottom: 6,
                    child: Container(
                      width: 14,
                      height: 3,
                      decoration: BoxDecoration(
                        color: activeInkColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _shapeGuessBtn(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Tooltip(
      message: 'Auto-forma · ${shapeGuess ? "attivo" : "spento"}',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onShapeGuessChanged(!shapeGuess),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: shapeGuess ? p.accentSoft : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: HwIcon('shape-guess',
                  size: 18,
                  color: shapeGuess ? p.accentDeep : p.ink1),
            ),
          ),
        ),
      ),
    );
  }
}

/// Popup with color preset + thickness slider + per-tool extras.
class HwToolPopup extends StatelessWidget {
  final CanvasTool tool;
  final Color color;
  final ValueChanged<Color> onColorChanged;
  final double thickness;
  final ValueChanged<double> onThicknessChanged;
  final List<Color> presetColors;
  final EraserSize? eraserSize;
  final ValueChanged<EraserSize>? onEraserSizeChanged;
  final bool? eraserPerStroke;
  final ValueChanged<bool>? onEraserPerStrokeChanged;
  final VoidCallback onClose;

  const HwToolPopup({
    super.key,
    required this.tool,
    required this.color,
    required this.onColorChanged,
    required this.thickness,
    required this.onThicknessChanged,
    required this.presetColors,
    required this.onClose,
    this.eraserSize,
    this.onEraserSizeChanged,
    this.eraserPerStroke,
    this.onEraserPerStrokeChanged,
  });

  bool get _showColor => !{
        CanvasTool.eraserStandard,
        CanvasTool.eraserStroke,
        CanvasTool.lasso,
        CanvasTool.pan,
      }.contains(tool);

  bool get _showThickness => !{
        CanvasTool.lasso,
        CanvasTool.pan,
        CanvasTool.text,
      }.contains(tool);

  bool get _isEraser =>
      tool == CanvasTool.eraserStandard || tool == CanvasTool.eraserStroke;

  String get _label {
    switch (tool) {
      case CanvasTool.pen:
        return 'Penna';
      case CanvasTool.ballpoint:
        return 'Ballpoint';
      case CanvasTool.brush:
        return 'Pennello';
      case CanvasTool.calligraphy:
        return 'Calligrafia';
      case CanvasTool.highlighter:
        return 'Evidenziatore';
      case CanvasTool.eraserStandard:
      case CanvasTool.eraserStroke:
        return 'Gomma';
      case CanvasTool.lasso:
        return 'Lasso';
      case CanvasTool.text:
        return 'Testo';
      case CanvasTool.shape:
        return 'Forma';
      case CanvasTool.image:
        return 'Immagine';
      case CanvasTool.pan:
        return 'Mano';
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      width: 300,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.paper0,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.paper3),
        boxShadow: hwShadow3(p.brightness),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: p.ink0)),
              const Spacer(),
              HwButton.icon(
                  icon: const HwIcon('x', size: 14), onPressed: onClose),
            ],
          ),
          const SizedBox(height: 8),
          if (_showColor) ...[
            _section('Colore', p),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in presetColors)
                  _colorChip(c, p),
                _customColorChip(p),
              ],
            ),
            const SizedBox(height: 14),
          ],
          if (_showThickness) ...[
            Row(
              children: [
                _section('Spessore', p),
                const Spacer(),
                Text('${thickness.toStringAsFixed(1)} px',
                    style: TextStyle(
                      fontSize: 12,
                      color: p.ink1,
                      fontFamily: HwTheme.fontMono,
                    )),
              ],
            ),
            const SizedBox(height: 6),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8, elevation: 1),
                activeTrackColor: p.ink0,
                inactiveTrackColor: p.paper3,
                thumbColor: p.ink0,
              ),
              child: Slider(
                min: 0.5,
                max: 20.0,
                divisions: 39,
                value: thickness.clamp(0.5, 20.0),
                onChanged: onThicknessChanged,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.paper2)),
              ),
              child: Row(
                children: [
                  Text('Anteprima',
                      style: TextStyle(fontSize: 12, color: p.ink2)),
                  const Spacer(),
                  CustomPaint(
                    size: const Size(160, 20),
                    painter: _StrokePreviewPainter(
                        color: color, width: thickness),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (_isEraser) ...[
            _section('Modalità', p),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _modeBtn(p, 'Per area', !(eraserPerStroke ?? false),
                      () => onEraserPerStrokeChanged?.call(false)),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _modeBtn(p, 'Per tratto', eraserPerStroke ?? false,
                      () => onEraserPerStrokeChanged?.call(true)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _section('Dimensione', p),
            const SizedBox(height: 6),
            Row(
              children: [
                for (final s in EraserSize.values) ...[
                  Expanded(
                    child: _modeBtn(
                        p,
                        switch (s) {
                          EraserSize.small => 'S',
                          EraserSize.medium => 'M',
                          EraserSize.large => 'L',
                        },
                        eraserSize == s,
                        () => onEraserSizeChanged?.call(s)),
                  ),
                  if (s != EraserSize.large) const SizedBox(width: 6),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String label, HwPalette p) => Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: p.ink2,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      );

  Widget _colorChip(Color c, HwPalette p) {
    final selected = c.toARGB32() == color.toARGB32();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onColorChanged(c),
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: p.paper0, width: 2)
                : Border.all(color: const Color(0x1A000000), width: 1),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: c, blurRadius: 0, spreadRadius: 2),
                  ]
                : null,
          ),
        ),
      ),
    );
  }

  Widget _customColorChip(HwPalette p) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: p.paper3),
        gradient: const SweepGradient(colors: [
          Colors.red,
          Colors.yellow,
          Colors.green,
          Colors.cyan,
          Colors.blue,
          Colors.purple,
          Colors.red,
        ]),
      ),
    );
  }

  Widget _modeBtn(HwPalette p, String label, bool active, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? p.ink0 : p.paper2,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                    color: active ? p.paper0 : p.ink0,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
        ),
      ),
    );
  }
}

class _StrokePreviewPainter extends CustomPainter {
  final Color color;
  final double width;
  _StrokePreviewPainter({required this.color, required this.width});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width.clamp(0.5, size.height)
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..quadraticBezierTo(
          size.width * 0.25, 4, size.width * 0.5, size.height / 2)
      ..quadraticBezierTo(size.width * 0.75, size.height - 4, size.width,
          size.height / 2);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_StrokePreviewPainter old) =>
      old.color != color || old.width != width;
}

/// Bottom strip with chapter label + horizontally scrolling page thumbnails.
///
/// Shows the pages whose 1-based numbers are in [pageNumbers] (typically
/// just the active chapter's pages). Auto-scrolls to keep the current page
/// roughly centered. Each thumbnail renders a mini sketch (4 ruled lines)
/// so it reads as a "page" instead of an empty box. Real rendered
/// thumbnails (via ThumbnailService) can be plugged in later.
class HwBottomPageStrip extends StatefulWidget {
  final String? chapterLabel;

  /// 1-based page numbers to show. The strip mirrors the active chapter
  /// filter — when no filter is active this should be 1..totalPages.
  final List<int> pageNumbers;

  /// 1-based page number of the currently open page. May or may not be
  /// present in [pageNumbers] (if the user is on a page outside the
  /// filter, no thumbnail is highlighted).
  final int currentPage;

  /// Tapping a thumbnail emits the underlying 1-based page number.
  final ValueChanged<int> onPageTap;
  /// Right-click / long-press on a thumbnail — opens a contextual menu.
  /// Receives the 1-based page number and the global tap position so the
  /// caller can position a popup menu correctly.
  final void Function(int pageNumber, Offset globalPosition)? onPageSecondary;
  final VoidCallback onAllPagesTap;

  const HwBottomPageStrip({
    super.key,
    this.chapterLabel,
    required this.pageNumbers,
    required this.currentPage,
    required this.onPageTap,
    this.onPageSecondary,
    required this.onAllPagesTap,
  });

  @override
  State<HwBottomPageStrip> createState() => _HwBottomPageStripState();
}

class _HwBottomPageStripState extends State<HwBottomPageStrip> {
  static const double _itemWidth = 50;
  static const double _itemSpacing = 8;
  static const double _stride = _itemWidth + _itemSpacing;

  final ScrollController _ctrl = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void didUpdateWidget(covariant HwBottomPageStrip old) {
    super.didUpdateWidget(old);
    final pagesChanged = old.pageNumbers.length != widget.pageNumbers.length;
    if (old.currentPage != widget.currentPage || pagesChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  void _scrollToCurrent() {
    if (!_ctrl.hasClients) return;
    final viewport = _ctrl.position.viewportDimension;
    if (viewport <= 0) return;
    final pos = widget.pageNumbers.indexOf(widget.currentPage);
    if (pos < 0) return; // current page is outside the filter — no scroll
    final desired = pos * _stride - (viewport - _itemWidth) / 2;
    final clamped =
        desired.clamp(0.0, _ctrl.position.maxScrollExtent).toDouble();
    _ctrl.animateTo(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    return Container(
      height: 84,
      decoration: BoxDecoration(
        color: p.paper0,
        border: Border(top: BorderSide(color: p.paper3)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          if (widget.chapterLabel != null &&
              widget.chapterLabel!.isNotEmpty) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                widget.chapterLabel!.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: p.ink2,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(width: 1, height: 18, color: p.paper3),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: widget.pageNumbers.isEmpty
                ? Center(
                    child: Text('Nessuna pagina',
                        style:
                            TextStyle(fontSize: 12, color: p.ink2)))
                : Listener(
                    // Mouse-wheel translates vertical wheel ticks into
                    // horizontal scroll on the strip, so a desktop user
                    // can flick through pages with the wheel without
                    // touching the trackpad.
                    onPointerSignal: (signal) {
                      if (signal is PointerScrollEvent &&
                          _ctrl.hasClients) {
                        final dy = signal.scrollDelta.dy;
                        final dx = signal.scrollDelta.dx;
                        final delta = dy.abs() > dx.abs() ? dy : dx;
                        final next = (_ctrl.offset + delta).clamp(
                          0.0,
                          _ctrl.position.maxScrollExtent,
                        );
                        _ctrl.jumpTo(next);
                      }
                    },
                    child: ListView.separated(
                    controller: _ctrl,
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.pageNumbers.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(width: _itemSpacing),
                    itemBuilder: (_, i) {
                      // n = global 1-based page number (used for navigation
                      // and right-click menu); displayLabel = position
                      // within the chapter (1..N). Showing the chapter
                      // position avoids confusing "gaps" in the displayed
                      // numbers when a chapter's pages are not contiguous
                      // in the overall notebook (e.g. simulations 185–207
                      // followed by 212+ when 208–211 belong elsewhere).
                      final n = widget.pageNumbers[i];
                      final selected = n == widget.currentPage;
                      final displayLabel = i + 1;
                      return _PageThumb(
                        number: displayLabel,
                        selected: selected,
                        globalPageNumber: n,
                        onTap: () => widget.onPageTap(n),
                        onSecondary: widget.onPageSecondary == null
                            ? null
                            : (pos) => widget.onPageSecondary!(n, pos),
                      );
                    },
                  ),
                  ),
          ),
          const SizedBox(width: 12),
          HwButton(
            leading: const HwIcon('grid', size: 14),
            label: 'Tutte le pagine',
            onPressed: widget.onAllPagesTap,
          ),
        ],
      ),
    );
  }
}

/// Single thumbnail in the bottom strip — renders a mini ruled "page" so the
/// strip reads as content rather than empty boxes.
class _PageThumb extends StatelessWidget {
  /// Label shown inside the thumbnail (chapter-local position, 1..N).
  final int number;
  /// Real notebook page number (1-based) — used only for the tooltip
  /// so the user can still find the page in the global numbering.
  final int? globalPageNumber;
  final bool selected;
  final VoidCallback onTap;
  /// Right-click / long-press → contextual menu. Receives the global
  /// pointer position so the caller can anchor the menu correctly.
  final void Function(Offset globalPosition)? onSecondary;
  const _PageThumb({
    required this.number,
    required this.selected,
    required this.onTap,
    this.globalPageNumber,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final p = HwThemeScope.of(context);
    final tooltip = globalPageNumber != null && globalPageNumber != number
        ? 'Pagina $number del capitolo · pagina $globalPageNumber del taccuino'
        : 'Pagina $number';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        onSecondaryTapDown: onSecondary == null
            ? null
            : (d) => onSecondary!(d.globalPosition),
        onLongPressStart: onSecondary == null
            ? null
            : (d) => onSecondary!(d.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 50,
          decoration: BoxDecoration(
            color: p.paper0,
            border: Border.all(
              color: selected ? p.accent : p.paper3,
              width: selected ? 1.8 : 1,
            ),
            borderRadius: BorderRadius.circular(3),
            boxShadow: selected ? hwShadow1(p.brightness) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(5, 5, 5, 2),
                  child: CustomPaint(
                    painter: _MiniPagePainter(
                      lineColor: p.ink3.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 1),
                alignment: Alignment.center,
                color: selected ? p.accent : Colors.transparent,
                child: Text(
                  number.toString(),
                  style: TextStyle(
                    fontSize: 9,
                    color: selected ? p.paper0 : p.ink3,
                    fontFamily: HwTheme.fontMono,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

class _MiniPagePainter extends CustomPainter {
  final Color lineColor;
  _MiniPagePainter({required this.lineColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    // 4 short ruled lines of decreasing length — mimics a written page.
    final lengths = [size.width * 0.95, size.width * 0.8, size.width * 0.6, size.width * 0.4];
    final ySpacing = size.height / (lengths.length + 1);
    for (int i = 0; i < lengths.length; i++) {
      final y = ySpacing * (i + 1);
      canvas.drawLine(Offset(0, y), Offset(lengths[i], y), paint);
    }
  }

  @override
  bool shouldRepaint(_MiniPagePainter old) => old.lineColor != lineColor;
}
