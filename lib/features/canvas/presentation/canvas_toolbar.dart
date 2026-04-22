import 'package:flutter/material.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';

/// GoodNotes-style horizontal toolbar — compact, icon-driven, with inline
/// stroke width indicators and preset color dots on the right.
class CanvasToolbar extends StatelessWidget {
  final CanvasTool currentTool;
  final ToolSettings toolSettings;
  final bool canUndo;
  final bool canRedo;
  final bool showToolOptions;
  final PaperType currentPaperType;
  final LassoSelection? lassoSelection;
  final ValueChanged<CanvasTool> onToolChanged;
  final ValueChanged<ToolSettings> onSettingsChanged;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onToggleOptions;
  final ValueChanged<PaperType> onPaperTypeChanged;
  final VoidCallback? onDeleteSelection;
  final VoidCallback? onClearSelection;
  final VoidCallback? onInsertImage;
  final VoidCallback? onCopySelection;
  final VoidCallback? onCutSelection;
  final VoidCallback? onPasteSelection;
  final VoidCallback? onDuplicateSelection;
  final ValueChanged<int>? onChangeSelectionColor;
  final VoidCallback? onOpenSymbols;
  final VoidCallback? onCreateSymbol;
  final int symbolCount;
  final List<int> presetColors;
  /// Called when the user long-presses a preset slot and picks a new color
  /// from the palette editor. Provides (slotIndex, newColorInt).
  final void Function(int slotIndex, int newColor)? onEditColorSlot;
  /// Called when the user long-presses a preset slot and taps move L/R in
  /// the palette editor. Provides (fromIndex, toIndex).
  final void Function(int fromIndex, int toIndex)? onMoveColorSlot;

  const CanvasToolbar({
    super.key,
    required this.currentTool,
    required this.toolSettings,
    required this.canUndo,
    required this.canRedo,
    required this.showToolOptions,
    required this.currentPaperType,
    this.lassoSelection,
    required this.onToolChanged,
    required this.onSettingsChanged,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleOptions,
    required this.onPaperTypeChanged,
    this.onDeleteSelection,
    this.onClearSelection,
    this.onInsertImage,
    this.onCopySelection,
    this.onCutSelection,
    this.onPasteSelection,
    this.onDuplicateSelection,
    this.onChangeSelectionColor,
    this.onOpenSymbols,
    this.onCreateSymbol,
    this.symbolCount = 0,
    this.presetColors = const [0xFF000000, 0xFF1565C0, 0xFFC62828, 0xFFFFFFFF, 0xFFFF9800, 0xFF2196F3],
    this.onEditColorSlot,
    this.onMoveColorSlot,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Main toolbar row ──
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFFF8F9FA),
            border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 0.5)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 6),

              // Undo / Redo
              _TbBtn(Icons.undo_rounded, onTap: canUndo ? onUndo : null, tip: 'Annulla'),
              _TbBtn(Icons.redo_rounded, onTap: canRedo ? onRedo : null, tip: 'Ripeti'),
              _Sep(),

              // ── Drawing tools ──
              _PenToolIcon(
                currentTool: currentTool,
                onToolChanged: onToolChanged,
                onToggleOptions: onToggleOptions,
              ),
              _ToolIcon(Icons.border_color_rounded, CanvasTool.highlighter, 'Evidenziatore',
                  currentTool, onToolChanged, onToggleOptions),
              _Sep(),

              // Eraser
              _EraserIcon(currentTool: currentTool, onTool: onToolChanged, onToggle: onToggleOptions),

              // Lasso
              _ToolIcon(Icons.gesture_rounded, CanvasTool.lasso, 'Lazo',
                  currentTool, onToolChanged, onToggleOptions),
              _Sep(),

              // Text / Shape / Image
              _ToolIcon(Icons.text_fields_rounded, CanvasTool.text, 'Testo',
                  currentTool, onToolChanged, onToggleOptions),
              _ToolIcon(Icons.category_rounded, CanvasTool.shape, 'Forma',
                  currentTool, onToolChanged, onToggleOptions),
              _TbBtn(Icons.image_rounded, onTap: onInsertImage, tip: 'Immagine'),
              _Sep(),

              // Pan
              _ToolIcon(Icons.pan_tool_rounded, CanvasTool.pan, 'Sposta',
                  currentTool, onToolChanged, onToggleOptions),
              _Sep(),

              // ── Inline stroke width indicators (GoodNotes style) ──
              ..._buildWidthIndicators(),

              const Spacer(),

              // ── Color dots (preset + current) ──
              ..._buildColorDots(context),
              const SizedBox(width: 4),

              // Symbols
              if (onOpenSymbols != null)
                _SymbolButton(
                  count: symbolCount,
                  onOpen: onOpenSymbols!,
                  onCreate: lassoSelection != null ? onCreateSymbol : null,
                ),

              // Paper type
              _TbBtn(Icons.grid_on_rounded, onTap: () => _showPaperPicker(context), tip: 'Sfondo'),

              // Shape recognition toggle (only for pen/brush)
              if (currentTool == CanvasTool.pen || currentTool == CanvasTool.brush)
                _ToggleIcon(
                  icon: Icons.auto_fix_high_rounded,
                  active: toolSettings.shapeRecognition,
                  onTap: () => onSettingsChanged(toolSettings.copyWith(shapeRecognition: !toolSettings.shapeRecognition)),
                  tip: 'Auto-forme',
                ),
              const SizedBox(width: 6),
            ],
          ),
        ),

        // ── Lasso selection action bar ──
        if (lassoSelection != null)
          Container(
            height: 38,
            color: const Color(0xFFE3F2FD),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('${lassoSelection!.selectedIds.length} elementi',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const Spacer(),
                _ChipBtn(Icons.copy_rounded, 'Copia', onCopySelection),
                _ChipBtn(Icons.content_cut_rounded, 'Taglia', onCutSelection),
                _ChipBtn(Icons.copy_all_rounded, 'Duplica', onDuplicateSelection),
                if (onPasteSelection != null)
                  _ChipBtn(Icons.paste_rounded, 'Incolla', onPasteSelection),
                const SizedBox(width: 8),
                _ChipBtn(Icons.delete_outline, 'Elimina', onDeleteSelection, color: Colors.red),
                _ChipBtn(Icons.close, 'Deseleziona', onClearSelection),
              ],
            ),
          ),

        // ── Tool options panel ──
        if (showToolOptions) _buildOptionsPanel(context),
      ],
    );
  }

  // ── Width indicators: 3 inline line bars (thin / medium / thick) ──
  List<Widget> _buildWidthIndicators() {
    // Quick thin / normal / thick sizes in the main toolbar. 'Normal' (2.0)
    // must match ToolSettings.strokeWidth's default so the middle button is
    // highlighted out of the box — without this the user opens the pen and
    // sees three equally-unselected indicators, then has to tap one just
    // to see anything active.
    final widths = [1.0, 2.0, 4.0];
    final labels = {1.0: 'Sottile', 2.0: 'Normale', 4.0: 'Spesso'};
    return widths.map((w) {
      final selected = (toolSettings.strokeWidth - w).abs() < 0.5;
      return Tooltip(
        message: labels[w] ?? 'Spessore ${w.toStringAsFixed(0)}',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onSettingsChanged(toolSettings.copyWith(strokeWidth: w)),
          child: Container(
            width: 28, height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              color: selected ? const Color(0xFFE3F2FD) : Colors.transparent,
            ),
            child: Container(
              width: 16,
              height: (w * 1.2).clamp(1.5, 8.0),
              decoration: BoxDecoration(
                color: selected ? Colors.blue.shade800 : Colors.grey.shade700,
                borderRadius: BorderRadius.circular(w),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  // ── Color dots ──
  List<Widget> _buildColorDots(BuildContext context) {
    return [
      ...presetColors.asMap().entries.map((entry) {
        final idx = entry.key;
        final c = entry.value;
        final isSel = toolSettings.color == c;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: GestureDetector(
            onTap: () {
              onSettingsChanged(toolSettings.copyWith(color: c));
              if (lassoSelection != null) onChangeSelectionColor?.call(c);
            },
            onLongPress: (onEditColorSlot == null && onMoveColorSlot == null)
                ? null
                : () => _showColorSlotEditor(context, idx, c),
            child: Container(
              width: 22, height: 22,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? Colors.blue : (c == 0xFFFFFFFF ? Colors.grey.shade400 : Colors.grey.shade300),
                  width: isSel ? 2.5 : 1,
                ),
              ),
              child: isSel
                  ? Icon(Icons.check, size: 11, color: c == 0xFF000000 ? Colors.white : Colors.blue)
                  : null,
            ),
          ),
        );
      }),
      const SizedBox(width: 2),
      // Full palette button
      GestureDetector(
        onTap: () => _showFullPalette(context),
        child: Container(
          width: 24, height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const SweepGradient(colors: [
              Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple, Colors.red,
            ]),
            border: Border.all(color: Colors.grey.shade400, width: 1),
          ),
        ),
      ),
      const SizedBox(width: 4),
    ];
  }

  Widget _buildOptionsPanel(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 0.5)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _optionsForTool(context),
    );
  }

  Widget _optionsForTool(BuildContext context) {
    if (currentTool == CanvasTool.eraserStandard || currentTool == CanvasTool.eraserStroke) {
      return _eraserOptions();
    }
    if (currentTool == CanvasTool.shape) return _shapeOptions();
    return _penOptions();
  }

  Widget _penOptions() {
    return Row(
      children: [
        // ── Pen / Brush sub-toggle ──
        _MiniChip(
          icon: Icons.edit_rounded,
          label: 'Penna',
          active: currentTool == CanvasTool.pen,
          onTap: () => onToolChanged(CanvasTool.pen),
        ),
        const SizedBox(width: 4),
        _MiniChip(
          icon: Icons.brush_rounded,
          label: 'Pennello',
          active: currentTool == CanvasTool.brush,
          onTap: () => onToolChanged(CanvasTool.brush),
        ),
        const SizedBox(width: 10),
        Container(width: 1, height: 28, color: Colors.grey.shade300),
        const SizedBox(width: 10),
        const Text('Spessore:', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 8),
        ...[0.5, 1.0, 2.0, 4.0, 8.0, 12.0].map((w) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: GestureDetector(
            onTap: () => onSettingsChanged(toolSettings.copyWith(strokeWidth: w)),
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: toolSettings.strokeWidth == w ? const Color(0xFFE3F2FD) : Colors.transparent,
                border: Border.all(color: toolSettings.strokeWidth == w ? Colors.blue : Colors.grey.shade300),
              ),
              child: Center(
                child: Container(
                  width: (w * 2).clamp(4.0, 22.0),
                  height: (w * 2).clamp(4.0, 22.0),
                  decoration: BoxDecoration(color: Color(toolSettings.color), shape: BoxShape.circle),
                ),
              ),
            ),
          ),
        )),
        const SizedBox(width: 12),
        Expanded(
          child: Slider(
            value: toolSettings.strokeWidth,
            min: 0.5, max: 20.0,
            onChanged: (v) => onSettingsChanged(toolSettings.copyWith(strokeWidth: v)),
          ),
        ),
      ],
    );
  }

  Widget _eraserOptions() {
    return Row(
      children: [
        _EraserChip('Standard', Icons.circle_outlined,
            currentTool == CanvasTool.eraserStandard, () => onToolChanged(CanvasTool.eraserStandard)),
        const SizedBox(width: 8),
        _EraserChip('Per tratto', Icons.gesture,
            currentTool == CanvasTool.eraserStroke, () => onToolChanged(CanvasTool.eraserStroke)),
        const SizedBox(width: 24),
        const Text('Dimensione:', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 8),
        ...(EraserSize.values.map((size) {
          final labels = {EraserSize.small: 'S', EraserSize.medium: 'M', EraserSize.large: 'L'};
          final diameters = {EraserSize.small: 16.0, EraserSize.medium: 24.0, EraserSize.large: 36.0};
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onSettingsChanged(toolSettings.copyWith(eraserSize: size)),
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: toolSettings.eraserSize == size ? const Color(0xFFFCE4EC) : Colors.transparent,
                  border: Border.all(color: toolSettings.eraserSize == size ? Colors.red.shade300 : Colors.grey.shade300),
                ),
                child: Center(
                  child: Container(
                    width: diameters[size], height: diameters[size],
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade600, width: 1.5),
                    ),
                    child: Center(child: Text(labels[size]!, style: TextStyle(fontSize: 10, color: Colors.grey.shade600))),
                  ),
                ),
              ),
            ),
          );
        })),
      ],
    );
  }

  Widget _shapeOptions() {
    final shapes = [
      ('rectangle', Icons.rectangle_outlined, 'Rettangolo'),
      ('circle', Icons.circle_outlined, 'Cerchio'),
      ('triangle', Icons.change_history, 'Triangolo'),
      ('rhombus', Icons.diamond_outlined, 'Rombo'),
      ('line', Icons.remove, 'Linea'),
      ('arrow', Icons.arrow_forward, 'Freccia'),
      ('xy_plane', Icons.grid_3x3_rounded, 'Piano XY'),
    ];
    return Row(
      children: shapes.map((s) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          onTap: () => onSettingsChanged(toolSettings.copyWith(shapeType: s.$1)),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: toolSettings.shapeType == s.$1 ? const Color(0xFFE3F2FD) : Colors.transparent,
              border: Border.all(color: toolSettings.shapeType == s.$1 ? Colors.blue : Colors.grey.shade300),
            ),
            child: Tooltip(message: s.$3, child: Icon(s.$2, size: 20, color: toolSettings.shapeType == s.$1 ? Colors.blue : Colors.grey.shade700)),
          ),
        ),
      )).toList(),
    );
  }

  /// Long-press on a preset slot opens this editor. User can:
  ///  • pick a different color from the full palette (replaces that slot)
  ///  • shift the slot one step left or right (reorder)
  /// Uses explicit buttons instead of gesture-based drag because long-press
  /// + drag conflicts are unreliable with stylus on iPad.
  void _showColorSlotEditor(BuildContext context, int slotIndex, int currentColor) {
    if (onEditColorSlot == null && onMoveColorSlot == null) return;
    final colors = <int>[
      0xFF000000, 0xFF424242, 0xFF757575, 0xFFBDBDBD, 0xFFFFFFFF,
      0xFFC62828, 0xFFE53935, 0xFFEF5350, 0xFFEF9A9A,
      0xFFE65100, 0xFFF57C00, 0xFFFF9800, 0xFFFFCC80,
      0xFFF9A825, 0xFFFDD835, 0xFFFFEB3B, 0xFFFFF59D,
      0xFF2E7D32, 0xFF43A047, 0xFF66BB6A, 0xFFA5D6A7,
      0xFF1565C0, 0xFF1E88E5, 0xFF42A5F5, 0xFF90CAF9,
      0xFF4527A0, 0xFF7B1FA2, 0xFF9C27B0, 0xFFCE93D8,
      0xFF006064, 0xFF00838F, 0xFF00ACC1, 0xFF80DEEA,
      0xFF3E2723, 0xFF5D4037, 0xFF795548, 0xFFA1887F,
    ];
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: Color(currentColor),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.grey.shade400),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('Slot ${slotIndex + 1}',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    // Reorder buttons
                    if (onMoveColorSlot != null) ...[
                      IconButton(
                        tooltip: 'Sposta a sinistra',
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: slotIndex == 0
                            ? null
                            : () {
                                onMoveColorSlot!(slotIndex, slotIndex - 1);
                                Navigator.pop(ctx);
                              },
                      ),
                      IconButton(
                        tooltip: 'Sposta a destra',
                        icon: const Icon(Icons.arrow_forward_rounded),
                        onPressed: slotIndex >= presetColors.length - 1
                            ? null
                            : () {
                                onMoveColorSlot!(slotIndex, slotIndex + 1);
                                Navigator.pop(ctx);
                              },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                const Text('Scegli un nuovo colore per questo slot:',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
                const SizedBox(height: 10),
                if (onEditColorSlot != null)
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: colors.map((c) {
                      final isSel = c == currentColor;
                      return GestureDetector(
                        onTap: () {
                          onEditColorSlot!(slotIndex, c);
                          Navigator.pop(ctx);
                        },
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSel
                                  ? Colors.blue
                                  : (c == 0xFFFFFFFF ? Colors.grey.shade400 : Colors.grey.shade300),
                              width: isSel ? 2.5 : 1,
                            ),
                          ),
                          child: isSel
                              ? Icon(Icons.check, size: 14, color: c == 0xFF000000 ? Colors.white : Colors.blue)
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFullPalette(BuildContext context) {
    _showColorDialog(context, (c) {
      onSettingsChanged(toolSettings.copyWith(color: c));
      if (lassoSelection != null) onChangeSelectionColor?.call(c);
    }, toolSettings.color);
  }

  void _showColorDialog(BuildContext context, ValueChanged<int> onPick, int? currentColor) {
    final colors = [
      0xFF000000, 0xFF424242, 0xFF757575, 0xFFBDBDBD, 0xFFFFFFFF,
      0xFFC62828, 0xFFE53935, 0xFFEF5350, 0xFFEF9A9A,
      0xFFE65100, 0xFFF57C00, 0xFFFF9800, 0xFFFFCC80,
      0xFFF9A825, 0xFFFDD835, 0xFFFFEB3B, 0xFFFFF59D,
      0xFF2E7D32, 0xFF43A047, 0xFF66BB6A, 0xFFA5D6A7,
      0xFF1565C0, 0xFF1E88E5, 0xFF42A5F5, 0xFF90CAF9,
      0xFF4527A0, 0xFF7B1FA2, 0xFF9C27B0, 0xFFCE93D8,
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Colore'),
        contentPadding: const EdgeInsets.all(20),
        content: SizedBox(
          width: 260,
          child: Wrap(
            spacing: 10, runSpacing: 10,
            children: colors.map((c) {
              final sel = currentColor == c;
              return GestureDetector(
                onTap: () { onPick(c); Navigator.pop(ctx); },
                child: Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: Color(c), shape: BoxShape.circle,
                    border: Border.all(
                      color: sel ? Colors.blue : (c == 0xFFFFFFFF ? Colors.grey.shade300 : Colors.transparent),
                      width: sel ? 3 : 1,
                    ),
                    boxShadow: sel ? [BoxShadow(color: Color(c).withValues(alpha: 0.4), blurRadius: 8)] : null,
                  ),
                  child: sel ? const Icon(Icons.check, color: Colors.blue, size: 16) : null,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _showPaperPicker(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Sfondo pagina'),
        children: PaperType.values.map((type) {
          final isSelected = currentPaperType == type;
          return ListTile(
            leading: Icon(_paperIcon(type)),
            title: Text(paperTypeLabel(type)),
            trailing: isSelected
                ? const Icon(Icons.radio_button_checked, color: Colors.blue)
                : const Icon(Icons.radio_button_off, color: Colors.grey),
            onTap: () { onPaperTypeChanged(type); Navigator.pop(ctx); },
          );
        }).toList(),
      ),
    );
  }

  IconData _paperIcon(PaperType t) {
    switch (t) {
      case PaperType.blank: return Icons.rectangle_outlined;
      case PaperType.linedNarrow: return Icons.density_small;
      case PaperType.linedWide: return Icons.density_large;
      case PaperType.grid: return Icons.grid_on;
      case PaperType.dotted: return Icons.more_horiz;
      case PaperType.cornell: return Icons.view_column_outlined;
      case PaperType.isometric: return Icons.change_history;
      case PaperType.music: return Icons.music_note_outlined;
    }
  }
}

// ═════════════════════════════════════════════════════════════
//  Toolbar Widgets
// ═════════════════════════════════════════════════════════════

class _TbBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String tip;
  const _TbBtn(this.icon, {this.onTap, required this.tip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 34, height: 34,
          child: Icon(icon, size: 19, color: onTap != null ? Colors.grey.shade800 : Colors.grey.shade400),
        ),
      ),
    );
  }
}

class _PenToolIcon extends StatelessWidget {
  final CanvasTool currentTool;
  final ValueChanged<CanvasTool> onToolChanged;
  final VoidCallback onToggleOptions;
  const _PenToolIcon({
    required this.currentTool,
    required this.onToolChanged,
    required this.onToggleOptions,
  });

  @override
  Widget build(BuildContext context) {
    final active = currentTool == CanvasTool.pen || currentTool == CanvasTool.brush;
    return Tooltip(
      message: 'Penna / Pennello',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => active ? onToggleOptions() : onToolChanged(CanvasTool.pen),
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active ? const Color(0xFFE3F2FD) : Colors.transparent,
          ),
          child: Stack(
            children: [
              Center(child: Icon(
                currentTool == CanvasTool.brush ? Icons.brush_rounded : Icons.edit_rounded,
                size: 19,
                color: active ? Colors.blue : Colors.grey.shade700,
              )),
              if (active)
                const Positioned(
                  right: 2, bottom: 2,
                  child: Icon(Icons.expand_more_rounded, size: 10, color: Colors.blue),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _MiniChip({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: active ? const Color(0xFFE3F2FD) : Colors.transparent,
            border: Border.all(color: active ? Colors.blue : Colors.grey.shade300),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: active ? Colors.blue : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: active ? Colors.blue : Colors.grey.shade600)),
          ]),
        ),
      ),
    );
  }
}

class _ToolIcon extends StatelessWidget {
  final IconData icon;
  final CanvasTool tool;
  final String tip;
  final CanvasTool current;
  final ValueChanged<CanvasTool> onChanged;
  final VoidCallback onToggle;
  const _ToolIcon(this.icon, this.tool, this.tip, this.current, this.onChanged, this.onToggle);

  @override
  Widget build(BuildContext context) {
    final active = current == tool;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => active ? onToggle() : onChanged(tool),
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active ? const Color(0xFFE3F2FD) : Colors.transparent,
          ),
          child: Icon(icon, size: 19, color: active ? Colors.blue : Colors.grey.shade700),
        ),
      ),
    );
  }
}

class _EraserIcon extends StatelessWidget {
  final CanvasTool currentTool;
  final ValueChanged<CanvasTool> onTool;
  final VoidCallback onToggle;
  const _EraserIcon({required this.currentTool, required this.onTool, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final active = currentTool == CanvasTool.eraserStandard || currentTool == CanvasTool.eraserStroke;
    return Tooltip(
      message: 'Gomma',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => active ? onToggle() : onTool(CanvasTool.eraserStroke),
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active ? const Color(0xFFFCE4EC) : Colors.transparent,
          ),
          child: Center(
            child: CustomPaint(
              size: const Size(19, 19),
              painter: _EraserPainter(
                color: active ? Colors.red.shade400 : Colors.grey.shade700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a simple eraser shape: angled rectangle with a pink tip.
class _EraserPainter extends CustomPainter {
  final Color color;
  _EraserPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    canvas.save();
    canvas.translate(w / 2, h / 2);
    canvas.rotate(-0.4); // slight angle
    canvas.translate(-w / 2, -h / 2);

    // Eraser body
    final bodyRect = RRect.fromLTRBR(
      w * 0.15, h * 0.2, w * 0.85, h * 0.8,
      const Radius.circular(2),
    );
    final bodyPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRRect(bodyRect, bodyPaint);

    // Pink tip (filled bottom portion)
    final tipRect = RRect.fromLTRBAndCorners(
      w * 0.15, h * 0.55, w * 0.85, h * 0.8,
      bottomLeft: const Radius.circular(2),
      bottomRight: const Radius.circular(2),
    );
    final tipPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(tipRect, tipPaint);

    // Dividing line between body and tip
    canvas.drawLine(
      Offset(w * 0.15, h * 0.55),
      Offset(w * 0.85, h * 0.55),
      bodyPaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_EraserPainter old) => color != old.color;
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1, height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 5),
      color: Colors.grey.shade300,
    );
  }
}

class _ToggleIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tip;
  const _ToggleIcon({required this.icon, required this.active, required this.onTap, required this.tip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active ? const Color(0xFFE8F5E9) : Colors.transparent,
          ),
          child: Icon(icon, size: 17, color: active ? Colors.green : Colors.grey.shade500),
        ),
      ),
    );
  }
}

class _ChipBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;
  const _ChipBtn(this.icon, this.label, this.onTap, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.grey.shade800;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: c),
              const SizedBox(width: 3),
              Text(label, style: TextStyle(fontSize: 11, color: c)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EraserChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _EraserChip(this.label, this.icon, this.selected, this.onTap);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: selected ? const Color(0xFFFCE4EC) : Colors.grey.shade100,
          border: Border.all(color: selected ? Colors.red.shade300 : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? Colors.red : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? Colors.red.shade700 : Colors.grey.shade700,
            )),
          ],
        ),
      ),
    );
  }
}

class _SymbolButton extends StatelessWidget {
  final int count;
  final VoidCallback onOpen;
  final VoidCallback? onCreate;
  const _SymbolButton({required this.count, required this.onOpen, this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: count > 0 ? 'Simboli ($count)' : 'Simboli',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onOpen,
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: count > 0 ? Colors.amber.shade50 : Colors.transparent,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(Icons.star_rounded, size: 19,
                      color: count > 0 ? Colors.amber.shade700 : Colors.grey.shade500),
                  if (count > 0)
                    Positioned(
                      right: 3, top: 3,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: Colors.amber.shade700, shape: BoxShape.circle),
                        constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                        child: Text('$count',
                            style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (onCreate != null)
          Tooltip(
            message: 'Crea simbolo dalla selezione',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onCreate,
              child: const SizedBox(
                width: 28, height: 28,
                child: Icon(Icons.add_circle_outline_rounded, size: 16, color: Colors.amber),
              ),
            ),
          ),
      ],
    );
  }
}
