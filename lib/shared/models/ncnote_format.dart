import 'package:freezed_annotation/freezed_annotation.dart';

part 'ncnote_format.freezed.dart';
part 'ncnote_format.g.dart';

// ═══════════════════════════════════════════════════════════════
//  METADATA.JSON – Informazioni del taccuino
// ═══════════════════════════════════════════════════════════════

@freezed
class NotebookMetadata with _$NotebookMetadata {
  const factory NotebookMetadata({
    required String id,
    required String title,
    @Default(1) int formatVersion,
    required DateTime createdAt,
    required DateTime modifiedAt,
    @Default('default') String coverStyle,
    @Default(0xFF1565C0) int coverColor, // Material Blue 800
    @Default('lined') String paperType, // blank, lined, grid, dotted
    @Default(0xFFFFFFFF) int paperColor,
    @Default(0) int pageCount,
    @Default([]) List<String> tags,
    String? author,
    String? description,
  }) = _NotebookMetadata;

  factory NotebookMetadata.fromJson(Map<String, dynamic> json) =>
      _$NotebookMetadataFromJson(json);
}

// ═══════════════════════════════════════════════════════════════
//  DOCUMENT.JSON – Struttura del documento (indice pagine)
// ═══════════════════════════════════════════════════════════════

@freezed
class DocumentStructure with _$DocumentStructure {
  const factory DocumentStructure({
    required String notebookId,
    @Default(1) int formatVersion,
    required List<PageEntry> pages,
  }) = _DocumentStructure;

  factory DocumentStructure.fromJson(Map<String, dynamic> json) =>
      _$DocumentStructureFromJson(json);
}

@freezed
class PageEntry with _$PageEntry {
  const factory PageEntry({
    required String pageId,
    required int pageNumber,
    required String fileName, // es. "page_001.json"
    @Default(595.0) double width,
    @Default(842.0) double height,
    String? thumbnailFile,
    DateTime? lastModified,
  }) = _PageEntry;

  factory PageEntry.fromJson(Map<String, dynamic> json) =>
      _$PageEntryFromJson(json);
}

// ═══════════════════════════════════════════════════════════════
//  PAGE_XXX.JSON – Dati vettoriali di una singola pagina
// ═══════════════════════════════════════════════════════════════

@freezed
class PageData with _$PageData {
  const factory PageData({
    required String pageId,
    required int pageNumber,
    required double width,
    required double height,
    required RenderingLayers layers,
    @Default([]) List<String> assetReferences,
    DateTime? createdAt,
    DateTime? modifiedAt,
  }) = _PageData;

  factory PageData.fromJson(Map<String, dynamic> json) =>
      _$PageDataFromJson(json);
}

@freezed
class RenderingLayers with _$RenderingLayers {
  const factory RenderingLayers({
    @Default(BackgroundLayer()) BackgroundLayer background,
    @Default([]) List<ContentElement> content,
  }) = _RenderingLayers;

  factory RenderingLayers.fromJson(Map<String, dynamic> json) =>
      _$RenderingLayersFromJson(json);
}

// ── Background Layer ──

@freezed
class BackgroundLayer with _$BackgroundLayer {
  const factory BackgroundLayer({
    @Default('lined') String type, // blank, lined, grid, dotted
    @Default(0xFFFFFFFF) int color,
    @Default(30.0) double lineSpacing,
    @Default(0xFFB0B8C0) int lineColor,
    String? pdfAsset, // path in assets/ se è un PDF annotato
    @Default(0) int pdfPage, // pagina del PDF
  }) = _BackgroundLayer;

  factory BackgroundLayer.fromJson(Map<String, dynamic> json) =>
      _$BackgroundLayerFromJson(json);
}

// ── Content Elements (unione polimorfa) ──

@Freezed(unionKey: 'type')
class ContentElement with _$ContentElement {
  const factory ContentElement.stroke({
    required String id,
    required int zIndex,
    required StrokeData data,
  }) = StrokeElement;

  const factory ContentElement.text({
    required String id,
    required int zIndex,
    required TextData data,
  }) = TextElement;

  const factory ContentElement.image({
    required String id,
    required int zIndex,
    required ImageData data,
  }) = ImageElement;

  const factory ContentElement.shape({
    required String id,
    required int zIndex,
    required ShapeData data,
  }) = ShapeElement;

  factory ContentElement.fromJson(Map<String, dynamic> json) =>
      _$ContentElementFromJson(json);
}

// ── Stroke Data ──

@freezed
class StrokeData with _$StrokeData {
  const factory StrokeData({
    required List<StrokePoint> points,
    @Default('pen') String toolType, // pen, ballpoint, brush, highlighter
    @Default(0xFF000000) int color,
    @Default(2.0) double baseWidth,
    @Default(false) bool isHighlighter,
    @Default(1.0) double opacity,
    DateTime? timestamp,
  }) = _StrokeData;

  factory StrokeData.fromJson(Map<String, dynamic> json) =>
      _$StrokeDataFromJson(json);
}

@freezed
class StrokePoint with _$StrokePoint {
  const factory StrokePoint({
    required double x,
    required double y,
    @Default(0.5) double pressure, // 0.0 - 1.0
    @Default(0.0) double tilt, // radianti
    @Default(0) int timestamp, // millisecondi relativi dall'inizio tratto
  }) = _StrokePoint;

  factory StrokePoint.fromJson(Map<String, dynamic> json) =>
      _$StrokePointFromJson(json);
}

// ── Text Data ──

@freezed
class TextData with _$TextData {
  const factory TextData({
    required double x,
    required double y,
    required double width,
    required double height,
    required String content,
    @Default('sans-serif') String fontFamily,
    @Default(16.0) double fontSize,
    @Default(0xFF000000) int color,
    @Default(false) bool bold,
    @Default(false) bool italic,
    @Default('left') String alignment, // left, center, right
  }) = _TextData;

  factory TextData.fromJson(Map<String, dynamic> json) =>
      _$TextDataFromJson(json);
}

// ── Image Data ──

@freezed
class ImageData with _$ImageData {
  const factory ImageData({
    required double x,
    required double y,
    required double width,
    required double height,
    required String assetPath, // path relativo in assets/images/
    @Default(0.0) double rotation, // radianti
    @Default(1.0) double opacity,
  }) = _ImageData;

  factory ImageData.fromJson(Map<String, dynamic> json) =>
      _$ImageDataFromJson(json);
}

// ── Shape Data ──

@freezed
class ShapeData with _$ShapeData {
  const factory ShapeData({
    required String shapeType, // rectangle, circle, line, arrow, triangle
    required double x1,
    required double y1,
    required double x2,
    required double y2,
    @Default(0xFF000000) int strokeColor,
    @Default(2.0) double strokeWidth,
    int? fillColor,
    @Default(0.0) double rotation,
  }) = _ShapeData;

  factory ShapeData.fromJson(Map<String, dynamic> json) =>
      _$ShapeDataFromJson(json);
}

// ═══════════════════════════════════════════════════════════════
//  SYNC METADATA – Per la gestione offline/sync
// ═══════════════════════════════════════════════════════════════

@freezed
class SyncMetadata with _$SyncMetadata {
  const factory SyncMetadata({
    required String notebookId,
    required String remotePath,
    String? localPath,
    String? etag,
    DateTime? lastSynced,
    @Default('synced') String status, // synced, modified, conflict, new
    @Default([]) List<String> dirtyPages, // pageId delle pagine modificate
  }) = _SyncMetadata;

  factory SyncMetadata.fromJson(Map<String, dynamic> json) =>
      _$SyncMetadataFromJson(json);
}
