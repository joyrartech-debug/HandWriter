# HandWriter Code Search Results

## Tasks Completed

### 1. Notebook Loading & activeChapterId Initialization
- **openNotebook method**: canvas_provider.dart
  - Takes metadata, document, pages, remotePath, assets, symbolLibraries
  - Creates new CanvasState with activeChapterId NOT SET (defaults to null)
  - activeChapterId=null means filteredPageIndices returns ALL pages
  - NO auto-selection of first chapter on open

### 2. addChapter Method 
- **Location**: canvas_provider.dart
- Assigns CURRENT page to new chapter (not creating new page)
- Updates page.chapterId to the new chapter
- Sets state.activeChapterId to point to new chapter

### 3. Lasso Selection Logic
- **_startLasso**, **_endLasso**, **_pointInPolygon**, **_getElementBounds**
- Selects strokes, text, images, AND shapes (NOT filtered by type)
- Uses ray-casting for point-in-polygon detection

### 4. Double-tap Selection
- **_isDoubleTap**: Returns true if elapsed < 400ms AND distance < 30px
- **selectElement**: canvas_provider.dart
- **_findImageOrShapeAt**: Only looks for images and shapes (not strokes/text)

### 5. ImageData Model
- Has `assetPath` field (relative path in assets/images/)
- NO `sourceType` or `isPdfImage` or similar field

---

## ROTATION SYSTEM DEEP-DIVE

### 1. Image Rotation (Working Reference)
- **rotateElement**: Direct angle assignment: `rotation: e.data.rotation + deltaAngle`
- Image rotation is stored in ImageData.rotation (radians)

### 2. Stroke Rotation (Via applySelectionTransform)
- Strokes are rotated by modifying ALL individual point coordinates
- NO rotation field stored on StrokeData

### 3. Shape Rotation 
- Shapes HAVE a rotation field: `ShapeData.rotation`
- Only TRANSLATES the bounding box corner points
- Increments shape.rotation field for canvas rendering

### 4. Rotation Math Center
- Selection center for rotation: `sel.bounds.center`

### 5. Rotation in Render Engine
- **Shapes**: Uses canvas.save/rotate/translate pattern
- **Strokes**: NO rotation applied (points already rotated)
- **Images**: canvas.save/rotate pattern same as shapes

---

## SHAPE RECOGNITION SYSTEM

### 1. Shape Types Recognized
- 'line', 'arrow', 'circle', 'triangle', 'rectangle', 'xy_plane'

### 2. Recognition Algorithm
- Stages: validity → line/arrow → closure → polygon → circle/triangle/rectangle
- Uses Douglas-Peucker for corner detection
- Uses radial variance for circle detection

### 3. Shape Data Model
- Fields: shapeType, x1, y1, x2, y2, strokeColor, strokeWidth, fillColor, rotation

### 4. Helper Methods
- _snapLineEnd: Snaps to 15° multiples
- _douglasPeucker: Path simplification
- _perpendicularDistance: Distance from point to line

### 5. Preview Rendering
- _paintShapePreview: Preview while dragging
- _paintRecognizedShapePreview: Preview with green glow
