import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/file_service.dart';
import 'package:handwriter/core/services/search_service.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/core/services/webdav_service.dart';

import 'package:handwriter/shared/models/ncnote_format.dart';
import 'package:uuid/uuid.dart';

/// Full-text search across locally-cached notebooks.
final searchServiceProvider = Provider<SearchService?>((ref) {
  final sync = ref.watch(syncServiceProvider);
  if (sync == null) return null;
  return SearchService(ref.watch(fileServiceProvider), sync);
});

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
  final fileService = ref.watch(fileServiceProvider);
  final service = SyncService(webdav, fileService);
  // Preload ETags from local DB so conflict detection works on cold start.
  service.preloadEtags();
  ref.onDispose(() => service.dispose());
  return service;
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

  /// True while a background sync with the server is running. The library UI
  /// watches this to distinguish "cold install, still fetching" from "really
  /// no notebooks" when the local DB is empty.
  final ValueNotifier<bool> isSyncing = ValueNotifier<bool>(false);

  /// Progress during first sync: "downloaded/total" where 0/0 means PROPFIND
  /// is still in flight. UI shows this beside the spinner so first-install
  /// users can tell work is happening.
  final ValueNotifier<({int done, int total})> syncProgress =
      ValueNotifier<({int done, int total})>((done: 0, total: 0));

  @override
  void dispose() {
    isSyncing.dispose();
    syncProgress.dispose();
    super.dispose();
  }

  /// Carica la lista dei notebook dal server, con fallback locale offline.
  Future<void> refresh() async {
    final fileService = _ref.read(fileServiceProvider);

    // ── Step 1: Show cached notebooks instantly from local DB ──
    await _loadFromLocalDb(fileService);

    // ── Step 2: Sync with server in background ──
    isSyncing.value = true;
    try {
      final syncService = _ref.read(syncServiceProvider);
      final webdav = _ref.read(webdavServiceProvider);
      if (syncService == null || webdav == null) return;

      await _syncWithServer(syncService, webdav, fileService);
    } catch (e) {
      debugPrint('[Library] Remote sync failed: $e');
      // Local data is already shown — no need to show error
    } finally {
      if (mounted) {
        isSyncing.value = false;
        syncProgress.value = (done: 0, total: 0);
      }
    }
  }

  /// Build notebook entries directly from local SQLite metadata (no ZIP parsing).
  Future<void> _loadFromLocalDb(FileService fileService) async {
    final allMeta = await fileService.getAllNotebookMeta();
    if (allMeta.isEmpty) {
      state = const AsyncValue.data([]);
      return;
    }

    final entries = <NotebookEntry>[];
    for (final row in allMeta) {
      entries.add(_notebookEntryFromRow(row));
    }
    entries.sort((a, b) => b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt));
    state = AsyncValue.data(entries);
  }

  /// Create a NotebookEntry from a DB row without parsing ZIP.
  NotebookEntry _notebookEntryFromRow(Map<String, dynamic> row) {
    return NotebookEntry(
      metadata: NotebookMetadata(
        id: row['id'] as String,
        title: row['title'] as String? ?? 'Untitled',
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
        modifiedAt: DateTime.tryParse(row['local_modified_at'] as String? ?? '') ?? DateTime.now(),
        coverColor: row['cover_color'] as int? ?? 0xFF1565C0,
        paperType: row['paper_type'] as String? ?? 'lined',
        pageCount: row['page_count'] as int? ?? 0,
      ),
      remotePath: row['remote_path'] as String? ?? '',
      lastSynced: row['remote_modified_at'] != null
          ? DateTime.tryParse(row['remote_modified_at'] as String)
          : null,
      isLocal: row['sync_status'] != 'synced',
    );
  }

  /// Sync with server: only download notebooks whose ETag has changed.
  /// Detects remote deletions and parallelizes downloads.
  Future<void> _syncWithServer(
    SyncService syncService,
    dynamic webdav,
    FileService fileService,
  ) async {
    await webdav.ensureBaseDirectory();
    final remoteFiles = await syncService.listRemoteNotebooks();
    debugPrint('[Library] PROPFIND returned ${remoteFiles.length} .ncnote files');

    // Build map of locally cached ETags keyed by remote path
    final localRows = await fileService.getAllNotebookMeta();
    final localByPath = <String, Map<String, dynamic>>{};
    for (final row in localRows) {
      final rp = row['remote_path'] as String? ?? '';
      if (rp.isNotEmpty) localByPath[rp] = row;
    }

    // Track which remote paths we've seen (to detect deletions)
    final seenRemotePaths = <String>{};
    var changed = false;
    final skipped = <String>[];

    // ── Identify which notebooks need downloading ──
    final toDownload = <({String remotePath, WebDavItem file})>[];
    for (final file in remoteFiles) {
      final remotePath = '${AppConfig.defaultRemotePath}${file.name}';
      seenRemotePaths.add(remotePath);

      final localRow = localByPath[remotePath];
      final localEtag = localRow?['etag'] as String?;

      // Skip if ETag matches — notebook hasn't changed on the server.
      if (localEtag != null && localEtag == file.etag) continue;

      // Skip downloading the server .ncnote if local data is NEWER.
      // Notebooks that use delta sync are never re-packaged into the server
      // .ncnote — their local copy is always more up-to-date than the static
      // file on the server.  Re-downloading would corrupt the local cache
      // with stale data and reset the library page-count to an old value.
      // The pull timer inside CanvasNotifier handles actual remote-change
      // detection for delta notebooks.
      if (localRow != null && file.lastModified != null) {
        final localModAt = localRow['local_modified_at'] as String?;
        if (localModAt != null) {
          final localDt = DateTime.tryParse(localModAt);
          if (localDt != null && localDt.isAfter(file.lastModified!)) {
            debugPrint('[Library] Skipping .ncnote download for $remotePath '
                '(local $localDt > server ${file.lastModified})');
            // Even though we skip the download, refresh the DB from the local
            // .ncnote so the library card always shows correct page-count/title.
            // Without this, a notebook that was never opened on this device
            // (so _savePulledChangesLocally never ran) can show stale metadata.
            final nbId = localRow['id'] as String;
            try {
              final localBytes = await fileService.readNotebookFile(nbId);
              if (localBytes != null) {
                final parsed = syncService.parseNcnoteMetadata(localBytes);
                final existingPageCount = localRow['page_count'] as int? ?? 0;
                if (parsed.metadata.pageCount != existingPageCount) {
                  await fileService.upsertNotebookMeta(
                    id: nbId,
                    title: parsed.metadata.title,
                    remotePath: remotePath,
                    localModifiedAt: parsed.metadata.modifiedAt,
                    syncStatus: localRow['sync_status'] as String? ?? 'synced',
                    fileSize: localBytes.length,
                    coverColor: parsed.metadata.coverColor,
                    paperType: parsed.metadata.paperType,
                    pageCount: parsed.metadata.pageCount,
                    createdAt: parsed.metadata.createdAt,
                    etag: localRow['etag'] as String?,
                  );
                  changed = true;
                }
              }
            } catch (e) {
              debugPrint('[Library] Could not refresh DB from local cache for $nbId: $e');
            }
            continue;
          }
        }
      }

      toDownload.add((remotePath: remotePath, file: file));
    }

    // ── Download changed/new notebooks in parallel (max 4 concurrent) ──
    if (toDownload.isNotEmpty) {
      debugPrint('[Library] Downloading ${toDownload.length} changed notebooks');
      syncProgress.value = (done: 0, total: toDownload.length);
      const maxConcurrent = 4;
      var completed = 0;
      for (var i = 0; i < toDownload.length; i += maxConcurrent) {
        if (!mounted) return; // notifier disposed
        final batch = toDownload.skip(i).take(maxConcurrent);
        final futures = batch.map((item) =>
            _downloadAndCache(webdav, syncService, fileService, item.remotePath, item.file));
        final results = await Future.wait(futures);
        if (results.any((ok) => ok)) changed = true;
        skipped.addAll(results
            .asMap()
            .entries
            .where((e) => !e.value)
            .map((e) => toDownload[i + e.key].file.name));
        completed += results.length;
        syncProgress.value = (done: completed, total: toDownload.length);
        // Incrementally refresh the library while the batch drains so
        // already-downloaded notebooks appear before the whole sync finishes.
        if (changed && mounted) {
          await _loadFromLocalDb(fileService);
        }
      }
    }

    // ── Detect remote deletions: remove notebooks no longer on server ──
    for (final row in localRows) {
      final rp = row['remote_path'] as String? ?? '';
      final syncStatus = row['sync_status'] as String? ?? '';
      // Only remove synced notebooks (keep local-only ones)
      if (rp.isNotEmpty && syncStatus == 'synced' && !seenRemotePaths.contains(rp)) {
        final id = row['id'] as String;
        debugPrint('[Library] Notebook $id removed from server, cleaning local cache');
        await fileService.deleteNotebook(id);
        changed = true;
      }
    }

    if (skipped.isNotEmpty) {
      debugPrint('[Library] Skipped ${skipped.length} notebooks: $skipped');
    }

    // Reload from DB if anything changed
    if (changed && mounted) {
      await _loadFromLocalDb(fileService);
    }
  }

  /// Download a single notebook, parse metadata off main thread, and cache it.
  /// Returns true on success, false on failure.
  Future<bool> _downloadAndCache(
    dynamic webdav,
    SyncService syncService,
    FileService fileService,
    String remotePath,
    WebDavItem file,
  ) async {
    const maxRetries = 2;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final Uint8List fullData = await webdav.downloadFile(remotePath);

        // Validate ZIP integrity before touching anything else
        SyncService.validateNcnoteArchive(
            fullData, context: 'downloadAndCache $remotePath');

        // Parse metadata off the main thread
        final metadata = await SyncService.parseNcnoteMetadataIsolate(fullData);

        // Verify that the ZIP actually contains all the pages it promises.
        // A stale/truncated download may have fewer pages than metadata.pageCount,
        // which would silently save an incomplete notebook.
        if (metadata.pageCount > 0) {
          final actualPages = syncService.extractAllPages(fullData);
          if (actualPages.length < metadata.pageCount) {
            throw CorruptedArchiveException(
              'Page count mismatch for $remotePath: '
              'metadata says ${metadata.pageCount} pages, '
              'archive contains ${actualPages.length}',
            );
          }
        }

        // Save file + DB entry
        await fileService.saveNotebookFile(metadata.id, fullData);
        await fileService.upsertNotebookMeta(
          id: metadata.id,
          title: metadata.title,
          remotePath: remotePath,
          etag: file.etag,
          localModifiedAt: metadata.modifiedAt,
          remoteModifiedAt: file.lastModified,
          syncStatus: 'synced',
          fileSize: fullData.length,
          coverColor: metadata.coverColor,
          paperType: metadata.paperType,
          pageCount: metadata.pageCount,
          createdAt: metadata.createdAt,
        );
        return true;
      } catch (e) {
        if (e is CorruptedArchiveException) {
          debugPrint('[Library] CORRUPTED notebook ${file.name}: $e');
          return false;
        }
        if (attempt == maxRetries - 1) {
          debugPrint('[Library] FAILED to load ${file.name} after $maxRetries attempts: $e');
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    return false;
  }

  /// Crea un nuovo notebook vuoto. Salva localmente e tenta upload remoto.
  Future<NotebookEntry> createNotebook({
    required String title,
    String paperType = 'lined',
    int coverColor = 0xFF1565C0,
    List<String> tags = const [],
  }) async {
    final syncService = _ref.read(syncServiceProvider);
    final fileService = _ref.read(fileServiceProvider);

    const uuid = Uuid();
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
      tags: tags,
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

  /// Soft-deletes a notebook: moves it to the local trash and removes it from
  /// the remote server (when reachable). Can be undone via [restoreFromTrash].
  Future<String?> deleteNotebook(NotebookEntry entry) async {
    final webdav = _ref.read(webdavServiceProvider);
    final fileService = _ref.read(fileServiceProvider);
    final thumbs = _ref.read(thumbnailServiceProvider);

    // Delete remote (if connected)
    if (webdav != null) {
      try {
        await webdav.delete(entry.remotePath);
      } catch (e) {
        debugPrint('[Library] Remote delete failed: $e');
      }
    }

    // Soft-delete locally: preserve the .ncnote in the trash so it can be restored.
    final trashId = await fileService.moveNotebookToTrash(entry.metadata.id);

    // Best-effort thumbnail cleanup.
    try {
      await thumbs.deleteThumbnail(entry.metadata.id);
    } catch (_) {}

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(
      current.where((e) => e.metadata.id != entry.metadata.id).toList(),
    );
    return trashId;
  }

  /// Restores a notebook from the trash. Re-uploads it to the remote on the
  /// next sync because it was deleted from the server.
  Future<void> restoreFromTrash(String trashId) async {
    final fileService = _ref.read(fileServiceProvider);
    final meta = await fileService.restoreFromTrash(trashId);
    if (meta != null) await refresh();
  }

  /// Lists notebooks in the trash.
  Future<List<TrashEntry>> listTrash() {
    return _ref.read(fileServiceProvider).listTrash();
  }

  /// Permanently deletes a single trash entry.
  Future<void> purgeTrashEntry(String trashId) {
    return _ref.read(fileServiceProvider).purgeTrashEntry(trashId);
  }

  /// Permanently empties the trash.
  Future<void> emptyTrash() {
    return _ref.read(fileServiceProvider).emptyTrash();
  }

  /// Replaces the tag list on a notebook. Persists locally and re-uploads
  /// (best-effort). The `syncStatus` is flipped to `modified` so the next
  /// background sync picks it up when offline.
  Future<void> updateNotebookTags(NotebookEntry entry, List<String> tags) async {
    final syncService = _ref.read(syncServiceProvider);
    final webdav = _ref.read(webdavServiceProvider);
    final fileService = _ref.read(fileServiceProvider);

    final localData = await fileService.readNotebookFile(entry.metadata.id);
    if (localData == null || syncService == null) return;

    final result = syncService.parseNcnoteMetadata(localData);
    final allPages = syncService.extractAllPages(localData);
    final allAssets = syncService.extractAllAssets(localData);
    final symbolLibraries = syncService.extractSymbolLibraries(localData);

    // Normalize: trim, drop empties, dedup while preserving order.
    final seen = <String>{};
    final cleanTags = <String>[];
    for (final t in tags.map((e) => e.trim())) {
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) cleanTags.add(t);
    }

    final updatedMeta = result.metadata.copyWith(
      tags: cleanTags,
      modifiedAt: DateTime.now(),
    );

    final package = syncService.createNcnotePackage(
      metadata: updatedMeta,
      document: result.document,
      pages: allPages,
      assets: allAssets.isNotEmpty ? allAssets : null,
      symbolLibraries: symbolLibraries.isNotEmpty ? symbolLibraries : null,
    );
    await fileService.saveNotebookFile(updatedMeta.id, package);
    await fileService.upsertNotebookMeta(
      id: updatedMeta.id,
      title: updatedMeta.title,
      remotePath: entry.remotePath,
      localModifiedAt: updatedMeta.modifiedAt,
      syncStatus: 'modified',
      coverColor: updatedMeta.coverColor,
      paperType: updatedMeta.paperType,
      pageCount: updatedMeta.pageCount,
      createdAt: updatedMeta.createdAt,
    );

    try {
      if (webdav != null) {
        final etag = await syncService.uploadNotebook(
          remotePath: entry.remotePath,
          metadata: updatedMeta,
          document: result.document,
          pages: allPages,
          assets: allAssets.isNotEmpty ? allAssets : null,
          symbolLibraries: symbolLibraries.isNotEmpty ? symbolLibraries : null,
        );
        await fileService.markNotebookSynced(updatedMeta.id, etag);
      }
    } catch (e) {
      debugPrint('[Library] Tags uploaded locally, remote sync deferred: $e');
    }

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(current.map((e) {
      if (e.metadata.id == entry.metadata.id) {
        return e.copyWith(metadata: updatedMeta);
      }
      return e;
    }).toList());
  }

  /// Rinomina un notebook.
  Future<void> renameNotebook(NotebookEntry entry, String newTitle) async {
    final syncService = _ref.read(syncServiceProvider);
    final webdav = _ref.read(webdavServiceProvider);
    final fileService = _ref.read(fileServiceProvider);

    // Use the local copy instead of downloading from remote.
    // This works offline and avoids overwriting unsaved local changes.
    final localData = await fileService.readNotebookFile(entry.metadata.id);
    if (localData == null) {
      // No local copy — can't rename
      debugPrint('[Library] Cannot rename: no local file for ${entry.metadata.id}');
      return;
    }

    if (syncService == null) return;

    final result = syncService.parseNcnoteMetadata(localData);
    final allPages = syncService.extractAllPages(localData);
    final allAssets = syncService.extractAllAssets(localData);
    final symbolLibraries = syncService.extractSymbolLibraries(localData);

    final updatedMeta = result.metadata.copyWith(
      title: newTitle,
      modifiedAt: DateTime.now(),
    );

    // Rebuild and save locally
    final package = syncService.createNcnotePackage(
      metadata: updatedMeta,
      document: result.document,
      pages: allPages,
      assets: allAssets.isNotEmpty ? allAssets : null,
      symbolLibraries: symbolLibraries.isNotEmpty ? symbolLibraries : null,
    );
    await fileService.saveNotebookFile(updatedMeta.id, package);
    await fileService.upsertNotebookMeta(
      id: updatedMeta.id,
      title: newTitle,
      remotePath: entry.remotePath,
      localModifiedAt: updatedMeta.modifiedAt,
      syncStatus: 'modified',
      coverColor: updatedMeta.coverColor,
      paperType: updatedMeta.paperType,
      pageCount: updatedMeta.pageCount,
      createdAt: updatedMeta.createdAt,
    );

    // Try to upload to server (best-effort — succeeds when online)
    try {
      if (webdav != null) {
        final etag = await syncService.uploadNotebook(
          remotePath: entry.remotePath,
          metadata: updatedMeta,
          document: result.document,
          pages: allPages,
          assets: allAssets.isNotEmpty ? allAssets : null,
          symbolLibraries: symbolLibraries.isNotEmpty ? symbolLibraries : null,
        );
        await fileService.markNotebookSynced(updatedMeta.id, etag);
      }
    } catch (e) {
      debugPrint('[Library] Rename uploaded locally, remote sync deferred: $e');
    }

    final current = state.valueOrNull ?? [];
    state = AsyncValue.data(current.map((e) {
      if (e.metadata.id == entry.metadata.id) {
        return e.copyWith(metadata: updatedMeta);
      }
      return e;
    }).toList());
  }

}
