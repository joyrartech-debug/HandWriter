# HandWriter Image Storage, Sync, and Loading - Complete Flow Analysis

## Overview
Images in HandWriter are stored as binary assets in the .ncnote ZIP archives. The flow traces from insertion → packaging → uploading → downloading → loading → rendering.

---

## 1. IMAGE INSERTION FLOW

### Entry Point: canvas_screen.dart
- **_pickAndInsertImage()**: User selects image via file picker
- Gets image bytes as `Uint8List`
- Calls **_insertImage()**

### _insertImage()
- Decodes image dimensions
- Scales to max 300px width
- Calls **ref.read(canvasProvider.notifier).addImageElement()**

### addImageElement()
**KEY POINT - WHERE IMAGES ENTER THE SYSTEM:**

```dart
void addImageElement(Offset position, String fileName, Uint8List bytes, double width, double height) {
  final assetId = '${const Uuid().v4()}_$fileName';  // Generate unique ID
  
  final newElement = ContentElement.image(
    data: ImageData(
      x: position.dx, y: position.dy, width: width, height: height,
      assetPath: assetId,  // ← STORES REFERENCE (path), NOT bytes
    ),
  );
  
  // Store raw bytes in separate map
  final newAssetBytes = Map<String, Uint8List>.from(s.assetBytes);
  newAssetBytes[assetId] = bytes;
  
  _decodeAndCacheImage(assetId, bytes);
  _markAssetDirty(assetId);
  
  state = s.copyWith(
    pages: updatedPages,
    assetBytes: newAssetBytes,
    ...
  );
}
```

**KEY INSIGHT:**
- `ImageData` stores only: `assetPath` (string reference)
- Actual bytes stored in `CanvasState.assetBytes: Map<String, Uint8List>`

---

## 2. IMAGE DATA MODEL

### ImageData
```dart
@freezed
class ImageData with _$ImageData {
  const factory ImageData({
    required double x, y, width, height,
    required String assetPath,
    @Default(0.0) double rotation,
    @Default(1.0) double opacity,
    @Default(false) bool locked,
  }) = _ImageData;
}
```

### PageData
```dart
@freezed
class PageData with _$PageData {
  const factory PageData({
    required String pageId,
    required RenderingLayers layers,
    @Default([]) List<String> assetReferences,
    ...
  }) = _PageData;
}
```

---

## 3. NOTEBOOK SAVE/PACKAGE CREATION

### createNcnotePackage()

**ZIP Structure Created:**
```
notebook.ncnote (ZIP)
├── metadata.json
├── document.json
├── pages/
│   ├── page_001.json
│   └── page_002.json
└── assets/
    ├── abc123_photo.png      (raw bytes)
    └── def456_image.jpg
```

---

## 4. IMAGE DOWNLOAD/EXTRACTION FLOW

### extractAllAssets()

```dart
Map<String, Uint8List> extractAllAssets(Uint8List data) {
  final archive = ZipDecoder().decodeBytes(data);
  final assets = <String, Uint8List>{};
  
  for (final file in archive.files) {
    if (file.name.startsWith('${AppConfig.assetsDir}/') && file.isFile) {
      final fileName = file.name.substring('${AppConfig.assetsDir}/'.length);
      if (fileName.isNotEmpty) {
        assets[fileName] = Uint8List.fromList(file.content as List<int>);
      }
    }
  }
  return assets;
}
```

---

## 5. NOTEBOOK OPEN & IMAGE LOADING

### openNotebook()
```dart
void openNotebook({..., Map<String, Uint8List>? assets, ...}) {
  state = CanvasState(..., assetBytes: assets ?? const {}, ...);
  
  if (assets != null) {
    for (final entry in assets.entries) {
      _decodeAndCacheImage(entry.key, entry.value);
    }
  }
}
```

### _decodeAndCacheImage()
```dart
Future<void> _decodeAndCacheImage(String assetId, Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  
  if (state != null) {
    final newCache = Map<String, ui.Image>.from(state!.imageCache);
    newCache[assetId] = image;
    state = state!.copyWith(imageCache: newCache);
  }
}
```

---

## 6. IMAGE RENDERING

### _paintImage() in render_engine.dart
- Looks up `imageCache[imageData.assetPath]`
- If found: draws with `canvas.drawImageRect()`
- If not: shows grey placeholder

---

## 7. POTENTIAL ISSUES IDENTIFIED

1. **Assets NOT included if assetBytes map is empty** → null passed to uploadNotebook
2. **Asset bytes NOT persisted across app restart** (in-memory only)
3. **assetReferences not maintained during editing** → can desync
4. **Missing validation of assetPath references** → silent placeholder
5. **Asset paths not normalized** → no deduplication

---

## 8. SUCCESSFUL SYNC FLOW (HAPPY PATH)

```
PC1: User inserts image
  → addImageElement() stores bytes + reference
  → save() → createNcnotePackage(assets: s.assetBytes)
  → Upload ZIP to server

PC2: User opens notebook
  → downloadNotebookFull() → extractAllAssets()
  → openNotebook(assets: result.assets)
  → _decodeAndCacheImage() for each asset
  → _paintImage() renders from cache
```
