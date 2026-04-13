import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/file_service.dart';
import 'package:handwriter/core/services/sync_service.dart';

import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:uuid/uuid.dart';

/// Un notebook nella libreria (metadata + info remote).
class NotebookEntry {
  final NotebookMetadata metadata;
  final String remotePath;
  final DateTime? lastSynced;
  final bool isLocal; // creato localmente, non ancora sincronizzato

  const NotebookEntry({
    required this.metadata,
    required this.remotePath,
    this.lastSynced,
    this.isLocal = false,
  });

  NotebookEntry copyWith({
    NotebookMetadata? metadata,
    String? remotePath,
    DateTime? lastSynced,
    bool? isLocal,
  }) =>
      NotebookEntry(
        metadata: metadata ?? this.metadata,
        remotePath: remotePath ?? this.remotePath,
        lastSynced: lastSynced ?? this.lastSynced,
        isLocal: isLocal ?? this.isLocal,
      );
}

/// Provider del SyncService.
final syncServiceProvider = Provider<SyncService?>((ref) {
  final webdav = ref.watch(webdavServiceProvider);
  if (webdav == null) return null;
  return SyncService(webdav);
});

/// Provider della lista notebook nella libreria.
final notebookListProvider =
    StateNotifierProvider<NotebookListNotifier, AsyncValue<List<NotebookEntry>>>(
        (ref) {
  return NotebookListNotifier(ref);
});

class NotebookListNotifier
    extends StateNotifier<AsyncValue<List<NotebookEntry>>> {
  final Ref _ref;

  NotebookListNotifier(this._ref) : super(const AsyncValue.loading());

  /// Carica la lista dei notebook dal server, con fallback locale offline.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    final fileService = _ref.read(fileServiceProvider);

    try {
      final syncService = _ref.read(syncServiceProvider);
      final webdav = _ref.read(webdavServiceProvider);
      if (syncService == null || webdav == null) {
        // No credentials — try local-only
        await _loadFromLocalCache(fileService);
        return;
      }

      // Try remote refresh
      await _refreshFromServer(syncService, webdav, fileService);
    } catch (e, st) {
      debugPrint('[Library] Remote refresh failed: $e — falling back to local cache');
      // Fallback: show locally cached notebooks
      try {
        await _loadFromLocalCache(fileService);
      } catch (localErr) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// Load notebook list from server and cache locally.
  Future<void> _refreshFromServer(
    SyncService syncService,
    dynamic webdav,
    FileService fileService,
  ) async {
    await webdav.ensureBaseDirectory();
    final remoteFiles = await syncService.listRemoteNotebooks();
    debugPrint('[Library] PROPFIND returned ${remoteFiles.length} .ncnote files');

    final entries = <NotebookEntry>[];
    final skipped = <String>[];
    for (final file in remoteFiles) {
      const maxRetries = 2;
      var success = false;
      for (var attempt = 0; attempt < maxRetries && !success; attempt++) {
        try {
          final remotePath = '${AppConfig.defaultRemotePath}${file.name}';
          final result = await syncService.downloadNotebook(remotePath);

          // Cache the full notebook locally for offline access
          try {
            final fullData = await webdav.downloadFile(remotePath);
            await fileService.saveNotebookFile(result.metadata.id, fullData);
            await fileService.upsertNotebookMeta(
              id: result.metadata.id,
              title: result.metadata.title,
              remotePath: remotePath,
              etag: file.etag,
              localModifiedAt: result.metadata.modifiedAt,
              remoteModifiedAt: file.lastModified,
              syncStatus: 'synced',
              fileSize: fullData.length,
              coverColor: result.metadata.coverColor,
              paperType: result.metadata.paperType,
              pageCount: result.metadata.pageCount,
              createdAt: result.metadata.createdAt,
            );
          } catch (cacheErr) {
            debugPrint('[Library] Cache write failed for ${file.name}: $cacheErr');
          }

          entries.add(NotebookEntry(
            metadata: result.metadata,
            remotePath: remotePath,
            lastSynced: DateTime.now(),
          ));
          success = true;
        } catch (e) {
          if (e is CorruptedArchiveException) {
            debugPrint('[Library] CORRUPTED notebook ${file.name}: $e');
            skipped.add('${file.name} (corrupted)');
            break;
          }
          if (attempt == maxRetries - 1) {
            debugPrint('[Library] FAILED to load ${file.name} after $maxRetries attempts: $e');
            skipped.add(file.name);
          } else {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
      }
    }

    // Also include local-only notebooks (created offline, not yet synced)
    final localMeta = await fileService.getDirtyNotebooks();
    for (final row in localMeta) {
      final id = row['id'] as String;
      if (!entries.any((e) => e.metadata.id == id)) {
        try {
          final localData = await fileService.readNotebookFile(id);
          if (localData != null) {
            final parsed = syncService.parseNcnoteMetadata(localData);
            entries.add(NotebookEntry(
              metadata: parsed.metadata,
              remotePath: row['remote_path'] as String,
              isLocal: true,
            ));
          }
        } catch (e) {
          debugPrint('[Library] Could not load local-only notebook $id: $e');
        }
      }
    }

    if (skipped.isNotEmpty) {
      debugPrint('[Library] Skipped ${skipped.length} notebooks: $skipped');
    }

    entries.sort((a, b) => b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt));
    state = AsyncValue.data(entries);
  }

  /// Load notebooks from local SQLite + filesystem cache.
  Future<void> _loadFromLocalCache(FileService fileService) async {
    final syncService = _ref.read(syncServiceProvider);
    final allMeta = await fileService.getAllNotebookMeta();
    debugPrint('[Library] Loading ${allMeta.length} notebooks from local cache');

    final entries = <NotebookEntry>[];
    for (final row in allMeta) {
      final id = row['id'] as String;
      try {
        final localData = await fileService.readNotebookFile(id);
        if (localData != null) {
          if (syncService != null) {
            final parsed = syncService.parseNcnoteMetadata(localData);
            entries.add(NotebookEntry(
              metadata: parsed.metadata,
              remotePath: row['remote_path'] as String,
              lastSynced: row['remote_modified_at'] != null
                  ? DateTime.tryParse(row['remote_modified_at'] as String)
                  : null,
              isLocal: row['sync_status'] != 'synced',
            ));
          }
        }
      } catch (e) {
        debugPrint('[Library] Skipping cached notebook $id: $e');
      }
    }

    entries.sort((a, b) => b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt));
    state = AsyncValue.data(entries);
  }

  /// Crea un nuovo notebook vuoto. Salva localmente e tenta upload remoto.
  Future<NotebookEntry> createNotebook({
    required String title,
    String paperType = 'lined',
    int coverColor = 0xFF1565C0,
  }) async {
    final syncService = _ref.read(syncServiceProvider);
    final fileService = _ref.read(fileServiceProvider);

    final uuid = const Uuid();
    final notebookId = uuid.v4();
    final now = DateTime.now();
    final pageId = uuid.v4();
    final chapterId = uuid.v4();

    final metadata = NotebookMetadata(
      id: notebookId,
      title: title,
      createdAt: now,
      modifiedAt: now,
      paperType: paperType,
      coverColor: coverColor,
      pageCount: 1,
      chapters: [
        Chapter(id: chapterId, title: 'Capitolo 1', pageIds: [pageId]),
      ],
    );

    final document = DocumentStructure(
      notebookId: notebookId,
      pages: [
        PageEntry(
          pageId: pageId,
          pageNumber: 1,
          fileName: 'page_001.json',
          lastModified: now,
          chapterId: chapterId,
        ),
      ],
    );

    final pageData = PageData(
      pageId: pageId,
      pageNumber: 1,
      width: AppConfig.defaultPageWidth,
      height: AppConfig.defaultPageHeight,
      layers: RenderingLayers(
        background: BackgroundLayer(type: paperType),
        content: const [],
      ),
      createdAt: now,
      modifiedAt: now,
    );

    // Sanitizza il nome file
    final safeName = title
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final remotePath =
        '${AppConfig.defaultRemotePath}${safeName}_$notebookId${AppConfig.fileExtension}';

    // Always save locally first
    bool isLocal = true;
    if (syncService != null) {
      final package = syncService.createNcnotePackage(
        metadata: metadata,
        document: document,
        pages: {'page_001.json': pageData},
      );
      await fileService.saveNotebookFile(notebookId, package);
      await fileService.upsertNotebookMeta(
        id: notebookId,
        title: title,
        remotePath: remotePath,
        localModifiedAt: now,
        syncStatus: 'modified',
        coverColor: coverColor,
        paperType: paperType,
        pageCount: 1,
        createdAt: now,
      );

      // Try uploading to server
      try {
        await syncService.uploadNotebook(
          remotePath: remotePath,
          metadata: metadata,
          document: document,
          pages: {'page_001.json': pageData},
        );
        await fileService.markNotebookSynced(notebookId, null);
        isLocal = false;
      } catch (e) {
        debugPrint('[Library] Created notebook locally, sync deferred: $e');
      }
    }

    final entry = NotebookEntry(
      metadata: metadata,
      remotePath: remotePath,
      lastSynced: isLocal ? null : DateTime.now(),
      isLocal: isLocal,
    );

    // Aggiungi alla lista
    final current = state.valueOrNull ?? [];
    state = AsyncValue.data([entry, ...current]);

    return entry;
  }

  /// Elimina un notebook dal server.
  Future<void> deleteNotebook(NotebookEntry entry) async {
    final webdav = _ref.read(webdavServiceProvider);
    if (webdav == null) return;

    await webdav.delete(entry.remotePath);

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(
      current.where((e) => e.metadata.id != entry.metadata.id).toList(),
    );
  }

  /// Rinomina un notebook.
  Future<void> renameNotebook(NotebookEntry entry, String newTitle) async {
    final syncService = _ref.read(syncServiceProvider);
    final webdav = _ref.read(webdavServiceProvider);
    if (syncService == null || webdav == null) return;

    // Scarica notebook completo (una sola volta)
    final result = await syncService.downloadNotebookFull(entry.remotePath);
    final updatedMeta = result.metadata.copyWith(
      title: newTitle,
      modifiedAt: DateTime.now(),
    );

    await syncService.uploadNotebook(
      remotePath: entry.remotePath,
      metadata: updatedMeta,
      document: result.document,
      pages: result.pages,
      assets: result.assets.isNotEmpty ? result.assets : null,
      symbolLibraries: result.symbolLibraries.isNotEmpty ? result.symbolLibraries : null,
    );

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(current.map((e) {
      if (e.metadata.id == entry.metadata.id) {
        return e.copyWith(metadata: updatedMeta);
      }
      return e;
    }).toList());
  }

  /// Estrae tutte le pagine da un archivio .ncnote raw.
  Future<Map<String, PageData>> _extractPages(
      SyncService sync, Uint8List data) async {
    return sync.extractAllPages(data);
  }
}
