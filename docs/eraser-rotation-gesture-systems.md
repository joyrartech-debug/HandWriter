# Eraser, Rotation & Gesture Systems - HandWriter App

## 1. ERASER SYSTEM

### Two Eraser Types
- **Standard Eraser** (`eraserStandard`): Splits strokes into segments, removing only touched points
- **Per Tratto Eraser** (`eraserStroke`): Removes entire strokes if ANY point is within eraser radius

### Eraser Size Constants
```
EraserSize.small:  4.0px radius
EraserSize.medium: 8.0px radius (default)
EraserSize.large:  20.0px radius
```

### Eraser Logic Flow (_eraseAt method)

#### Non-Stroke Elements (Text/Symbols/Shapes) - Both Erasers
- Text, symbols, and shapes are **removed entirely** when touched
- Check: bounding box + inflated eraser radius

#### Strokes - Different Logic Per Type

**Per Tratto Eraser** (eraserStroke):
- Check if ANY point within eraser radius: `dx² + dy² < eraseRadius²`
- If found: **remove entire stroke**

**Standard Eraser**:
- Iterate through ALL stroke points
- Build segments of points OUTSIDE eraser radius
- Keep only segments with ≥2 points
- Create new stroke elements for each segment

### Eraser Workflow
1. `startStroke()` → `eraserCursorPos` set, `_eraseAt()` called
2. `continueStroke()` → `eraserCursorPos` updated, `_eraseAt()` called repeatedly
3. `endStroke()` → cursor disappears
4. No undo tracking per point (entire gesture is one undo state)

---

## 2. ROTATION SYSTEM

### Two Rotation Scopes
1. **Individual Elements**: Images and Shapes have `rotation: double` field (radians)
2. **Lasso Selection**: Entire selection group rotated around selection center

### Individual Element Rotation (rotateElement)

**Images & Shapes**: `rotation: e.data.rotation + deltaAngle`

**Strokes & Text**: NOT directly rotatable - only via lasso selection transform

### Lasso Selection Rotation

**Selection Center Rotation**:
- Center point: `selectionBounds.center`
- Rotation formula: `atan2(start) → atan2(current) → deltaAngle`

**Strokes**: All points rotated individually
**Images/Shapes**: Center point rotated, then bounding box translated + rotation field incremented

### Rotation UI (ImageHandleOverlay)
- Rotate handle: 30px above element top-center
- Drag gesture computes delta angle

---

## 3. PALM REJECTION & LONG-PRESS HANDLING

### Palm Rejection Strategy

**Stylus-Only Drawing Mode** (Mobile):
```dart
_stylusOnlyDrawing = !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
     defaultTargetPlatform == TargetPlatform.android);
```

### Stylus Barrel Button (Secondary Button)
- Restores previous tool after erasing
- Used as temporary stroke eraser

### Long-Press Context Menu
- 500ms timer on touch-pan (not on active stroke)
- Cancels if movement > 10px

### Multi-Touch Handling
- ≥2 pointers → cancel stroke, disable pan, cancel long-press timer
- Pinch-to-zoom takes over exclusively

### Double-Tap Detection
```dart
return elapsed < 400 && dist < 30;  // 400ms, 30px threshold
```
Used to select image/shape for editing.

### Hold-to-Recognize (GoodNotes-style)
- 200ms hold with shape recognition enabled
- 3px jitter tolerance

### Gesture Priority
1. Barrel button → erase mode
2. Multi-touch (≥2 pointers) → pinch-to-zoom
3. Middle mouse → pan
4. Long-press → context menu
5. Draw tools default
