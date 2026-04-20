// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ncnote_format.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ChapterImpl _$$ChapterImplFromJson(Map<String, dynamic> json) =>
    _$ChapterImpl(
      id: json['id'] as String,
      title: json['title'] as String,
      pageIds: (json['pageIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );

Map<String, dynamic> _$$ChapterImplToJson(_$ChapterImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'pageIds': instance.pageIds,
    };

_$NotebookMetadataImpl _$$NotebookMetadataImplFromJson(
        Map<String, dynamic> json) =>
    _$NotebookMetadataImpl(
      id: json['id'] as String,
      title: json['title'] as String,
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 1,
      createdAt: DateTime.parse(json['createdAt'] as String),
      modifiedAt: DateTime.parse(json['modifiedAt'] as String),
      coverStyle: json['coverStyle'] as String? ?? 'default',
      coverColor: (json['coverColor'] as num?)?.toInt() ?? 0xFF1565C0,
      paperType: json['paperType'] as String? ?? 'lined',
      paperColor: (json['paperColor'] as num?)?.toInt() ?? 0xFFFFFFFF,
      pageCount: (json['pageCount'] as num?)?.toInt() ?? 0,
      tags:
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
              const [],
      chapters: (json['chapters'] as List<dynamic>?)
              ?.map((e) => Chapter.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      author: json['author'] as String?,
      description: json['description'] as String?,
    );

Map<String, dynamic> _$$NotebookMetadataImplToJson(
        _$NotebookMetadataImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'formatVersion': instance.formatVersion,
      'createdAt': instance.createdAt.toIso8601String(),
      'modifiedAt': instance.modifiedAt.toIso8601String(),
      'coverStyle': instance.coverStyle,
      'coverColor': instance.coverColor,
      'paperType': instance.paperType,
      'paperColor': instance.paperColor,
      'pageCount': instance.pageCount,
      'tags': instance.tags,
      'chapters': instance.chapters.map((e) => e.toJson()).toList(),
      'author': instance.author,
      'description': instance.description,
    };

_$DocumentStructureImpl _$$DocumentStructureImplFromJson(
        Map<String, dynamic> json) =>
    _$DocumentStructureImpl(
      notebookId: json['notebookId'] as String,
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 1,
      pages: (json['pages'] as List<dynamic>)
          .map((e) => PageEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$$DocumentStructureImplToJson(
        _$DocumentStructureImpl instance) =>
    <String, dynamic>{
      'notebookId': instance.notebookId,
      'formatVersion': instance.formatVersion,
      'pages': instance.pages.map((e) => e.toJson()).toList(),
    };

_$PageEntryImpl _$$PageEntryImplFromJson(Map<String, dynamic> json) =>
    _$PageEntryImpl(
      pageId: json['pageId'] as String,
      pageNumber: (json['pageNumber'] as num).toInt(),
      fileName: json['fileName'] as String,
      width: (json['width'] as num?)?.toDouble() ?? 595.0,
      height: (json['height'] as num?)?.toDouble() ?? 842.0,
      thumbnailFile: json['thumbnailFile'] as String?,
      chapterId: json['chapterId'] as String?,
      lastModified: json['lastModified'] == null
          ? null
          : DateTime.parse(json['lastModified'] as String),
    );

Map<String, dynamic> _$$PageEntryImplToJson(_$PageEntryImpl instance) =>
    <String, dynamic>{
      'pageId': instance.pageId,
      'pageNumber': instance.pageNumber,
      'fileName': instance.fileName,
      'width': instance.width,
      'height': instance.height,
      'thumbnailFile': instance.thumbnailFile,
      'chapterId': instance.chapterId,
      'lastModified': instance.lastModified?.toIso8601String(),
    };

_$PageDataImpl _$$PageDataImplFromJson(Map<String, dynamic> json) =>
    _$PageDataImpl(
      pageId: json['pageId'] as String,
      pageNumber: (json['pageNumber'] as num).toInt(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      layers: RenderingLayers.fromJson(json['layers'] as Map<String, dynamic>),
      assetReferences: (json['assetReferences'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      createdAt: json['createdAt'] == null
          ? null
          : DateTime.parse(json['createdAt'] as String),
      modifiedAt: json['modifiedAt'] == null
          ? null
          : DateTime.parse(json['modifiedAt'] as String),
    );

Map<String, dynamic> _$$PageDataImplToJson(_$PageDataImpl instance) =>
    <String, dynamic>{
      'pageId': instance.pageId,
      'pageNumber': instance.pageNumber,
      'width': instance.width,
      'height': instance.height,
      'layers': instance.layers.toJson(),
      'assetReferences': instance.assetReferences,
      'createdAt': instance.createdAt?.toIso8601String(),
      'modifiedAt': instance.modifiedAt?.toIso8601String(),
    };

_$RenderingLayersImpl _$$RenderingLayersImplFromJson(
        Map<String, dynamic> json) =>
    _$RenderingLayersImpl(
      background: json['background'] == null
          ? const BackgroundLayer()
          : BackgroundLayer.fromJson(
              json['background'] as Map<String, dynamic>),
      content: (json['content'] as List<dynamic>?)
              ?.map((e) => ContentElement.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$$RenderingLayersImplToJson(
        _$RenderingLayersImpl instance) =>
    <String, dynamic>{
      'background': instance.background.toJson(),
      'content': instance.content.map((e) => e.toJson()).toList(),
    };

_$BackgroundLayerImpl _$$BackgroundLayerImplFromJson(
        Map<String, dynamic> json) =>
    _$BackgroundLayerImpl(
      type: json['type'] as String? ?? 'lined',
      color: (json['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
      lineSpacing: (json['lineSpacing'] as num?)?.toDouble() ?? 30.0,
      lineColor: (json['lineColor'] as num?)?.toInt() ?? 0xFFB0B8C0,
      pdfAsset: json['pdfAsset'] as String?,
      pdfPage: (json['pdfPage'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$BackgroundLayerImplToJson(
        _$BackgroundLayerImpl instance) =>
    <String, dynamic>{
      'type': instance.type,
      'color': instance.color,
      'lineSpacing': instance.lineSpacing,
      'lineColor': instance.lineColor,
      'pdfAsset': instance.pdfAsset,
      'pdfPage': instance.pdfPage,
    };

_$StrokeElementImpl _$$StrokeElementImplFromJson(Map<String, dynamic> json) =>
    _$StrokeElementImpl(
      id: json['id'] as String,
      zIndex: (json['zIndex'] as num).toInt(),
      data: StrokeData.fromJson(json['data'] as Map<String, dynamic>),
      $type: json['type'] as String?,
    );

Map<String, dynamic> _$$StrokeElementImplToJson(_$StrokeElementImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'zIndex': instance.zIndex,
      'data': instance.data.toJson(),
      'type': instance.$type,
    };

_$TextElementImpl _$$TextElementImplFromJson(Map<String, dynamic> json) =>
    _$TextElementImpl(
      id: json['id'] as String,
      zIndex: (json['zIndex'] as num).toInt(),
      data: TextData.fromJson(json['data'] as Map<String, dynamic>),
      $type: json['type'] as String?,
    );

Map<String, dynamic> _$$TextElementImplToJson(_$TextElementImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'zIndex': instance.zIndex,
      'data': instance.data.toJson(),
      'type': instance.$type,
    };

_$ImageElementImpl _$$ImageElementImplFromJson(Map<String, dynamic> json) =>
    _$ImageElementImpl(
      id: json['id'] as String,
      zIndex: (json['zIndex'] as num).toInt(),
      data: ImageData.fromJson(json['data'] as Map<String, dynamic>),
      $type: json['type'] as String?,
    );

Map<String, dynamic> _$$ImageElementImplToJson(_$ImageElementImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'zIndex': instance.zIndex,
      'data': instance.data.toJson(),
      'type': instance.$type,
    };

_$ShapeElementImpl _$$ShapeElementImplFromJson(Map<String, dynamic> json) =>
    _$ShapeElementImpl(
      id: json['id'] as String,
      zIndex: (json['zIndex'] as num).toInt(),
      data: ShapeData.fromJson(json['data'] as Map<String, dynamic>),
      $type: json['type'] as String?,
    );

Map<String, dynamic> _$$ShapeElementImplToJson(_$ShapeElementImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'zIndex': instance.zIndex,
      'data': instance.data.toJson(),
      'type': instance.$type,
    };

_$StrokeDataImpl _$$StrokeDataImplFromJson(Map<String, dynamic> json) =>
    _$StrokeDataImpl(
      points: (json['points'] as List<dynamic>)
          .map((e) => StrokePoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      toolType: json['toolType'] as String? ?? 'pen',
      color: (json['color'] as num?)?.toInt() ?? 0xFF000000,
      baseWidth: (json['baseWidth'] as num?)?.toDouble() ?? 2.0,
      isHighlighter: json['isHighlighter'] as bool? ?? false,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      timestamp: json['timestamp'] == null
          ? null
          : DateTime.parse(json['timestamp'] as String),
    );

Map<String, dynamic> _$$StrokeDataImplToJson(_$StrokeDataImpl instance) =>
    <String, dynamic>{
      'points': instance.points.map((e) => e.toJson()).toList(),
      'toolType': instance.toolType,
      'color': instance.color,
      'baseWidth': instance.baseWidth,
      'isHighlighter': instance.isHighlighter,
      'opacity': instance.opacity,
      'timestamp': instance.timestamp?.toIso8601String(),
    };

_$StrokePointImpl _$$StrokePointImplFromJson(Map<String, dynamic> json) =>
    _$StrokePointImpl(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      pressure: (json['pressure'] as num?)?.toDouble() ?? 0.5,
      tilt: (json['tilt'] as num?)?.toDouble() ?? 0.0,
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$$StrokePointImplToJson(_$StrokePointImpl instance) =>
    <String, dynamic>{
      'x': instance.x,
      'y': instance.y,
      'pressure': instance.pressure,
      'tilt': instance.tilt,
      'timestamp': instance.timestamp,
    };

_$TextDataImpl _$$TextDataImplFromJson(Map<String, dynamic> json) =>
    _$TextDataImpl(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      content: json['content'] as String,
      fontFamily: json['fontFamily'] as String? ?? 'sans-serif',
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
      color: (json['color'] as num?)?.toInt() ?? 0xFF000000,
      bold: json['bold'] as bool? ?? false,
      italic: json['italic'] as bool? ?? false,
      alignment: json['alignment'] as String? ?? 'left',
    );

Map<String, dynamic> _$$TextDataImplToJson(_$TextDataImpl instance) =>
    <String, dynamic>{
      'x': instance.x,
      'y': instance.y,
      'width': instance.width,
      'height': instance.height,
      'content': instance.content,
      'fontFamily': instance.fontFamily,
      'fontSize': instance.fontSize,
      'color': instance.color,
      'bold': instance.bold,
      'italic': instance.italic,
      'alignment': instance.alignment,
    };

_$ImageDataImpl _$$ImageDataImplFromJson(Map<String, dynamic> json) =>
    _$ImageDataImpl(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      assetPath: json['assetPath'] as String,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      locked: json['locked'] as bool? ?? false,
      flipHorizontal: json['flipHorizontal'] as bool? ?? false,
      comment: json['comment'] as String?,
    );

Map<String, dynamic> _$$ImageDataImplToJson(_$ImageDataImpl instance) =>
    <String, dynamic>{
      'x': instance.x,
      'y': instance.y,
      'width': instance.width,
      'height': instance.height,
      'assetPath': instance.assetPath,
      'rotation': instance.rotation,
      'opacity': instance.opacity,
      'locked': instance.locked,
      'flipHorizontal': instance.flipHorizontal,
      'comment': instance.comment,
    };

_$ShapeDataImpl _$$ShapeDataImplFromJson(Map<String, dynamic> json) =>
    _$ShapeDataImpl(
      shapeType: json['shapeType'] as String,
      x1: (json['x1'] as num).toDouble(),
      y1: (json['y1'] as num).toDouble(),
      x2: (json['x2'] as num).toDouble(),
      y2: (json['y2'] as num).toDouble(),
      strokeColor: (json['strokeColor'] as num?)?.toInt() ?? 0xFF000000,
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.0,
      fillColor: (json['fillColor'] as num?)?.toInt(),
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
    );

Map<String, dynamic> _$$ShapeDataImplToJson(_$ShapeDataImpl instance) =>
    <String, dynamic>{
      'shapeType': instance.shapeType,
      'x1': instance.x1,
      'y1': instance.y1,
      'x2': instance.x2,
      'y2': instance.y2,
      'strokeColor': instance.strokeColor,
      'strokeWidth': instance.strokeWidth,
      'fillColor': instance.fillColor,
      'rotation': instance.rotation,
    };

_$SyncMetadataImpl _$$SyncMetadataImplFromJson(Map<String, dynamic> json) =>
    _$SyncMetadataImpl(
      notebookId: json['notebookId'] as String,
      remotePath: json['remotePath'] as String,
      localPath: json['localPath'] as String?,
      etag: json['etag'] as String?,
      lastSynced: json['lastSynced'] == null
          ? null
          : DateTime.parse(json['lastSynced'] as String),
      status: json['status'] as String? ?? 'synced',
      dirtyPages: (json['dirtyPages'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );

Map<String, dynamic> _$$SyncMetadataImplToJson(_$SyncMetadataImpl instance) =>
    <String, dynamic>{
      'notebookId': instance.notebookId,
      'remotePath': instance.remotePath,
      'localPath': instance.localPath,
      'etag': instance.etag,
      'lastSynced': instance.lastSynced?.toIso8601String(),
      'status': instance.status,
      'dirtyPages': instance.dirtyPages,
    };
