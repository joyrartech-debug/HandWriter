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
    final fileService = _ref.read(fileServiceProvider);

    // ── Step 1: Show cached notebooks instantly from local DB ──
    await _loadFromLocalDb(fileService);

    // ── Step 2: Sync with server in background ──
    try {
      final syncService = _ref.read(syncServiceProvider);
      final webdav = _ref.read(webdavServiceProvider);
      if (syncService == null || webdav == null) return;

      await _syncWithServer(syncService, webdav, fileService);
    } catch (e) {
      debugPrint('[Library] Remote sync failed: $e');
      // Local data is already shown — no need to show error
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
  Future<void> _syncWithServer(
    SyncService syncService,
    dynamic webdav,
    FileService fileService,
  ) async {
    await webdav.ensureBaseDirectory();
    final remoteFiles = await syncService.listRemoteNotebooks();
    debugPrint('[Library] PROPFIND returned ${remoteFiles.length} .ncnote files');

    // Build map of locally cached ETags
    final localRows = await fileService.getAllNotebookMeta();
    final localEtagByPath = <String, String?>{};
    final localIdByPath = <String, String>{};
    for (final row in localRows) {
      final rp = row['remote_path'] as String? ?? '';
      localEtagByPath[rp] = row['etag'] as String?;
      localIdByPath[rp] = row['id'] as String;
    }

    var changed = false;
    final skipped = <String>[];

    for (final file in remoteFiles) {
      final remotePath = '${AppConfig.defaultRemotePath}${file.name}';
      final localEtag = localEtagByPath[remotePath];

      // Skip if ETag matches — notebook hasn't changed
      if (localEtag != null && localEtag == file.etag) {
        localEtagByPath.remove(remotePath); // mark as seen
        continue;
      }

      // Need to download this notebook (new or changed)
      const maxRetries = 2;
      var success = false;
      for (var attempt = 0; attempt < maxRetries && !success; attempt++) {
        try {
          final fullData = await webdav.downloadFile(remotePath);
          final result = syncService.parseNcnoteMetadata(fullData);

          // Save locally
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
          changed = true;
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
      // These are already in the DB, no need to re-download
      if (!localIdByPath.containsValue(id)) {
        changed = true; // new local notebook appeared
      }
    }

    if (skipped.isNotEmpty) {
      debugPrint('[Library] Skipped ${skipped.length} notebooks: $skipped');
    }

    // Reload from DB if anything changed
    if (changed) {
      await _loadFromLocalDb(fileService);
    }
  }

  /// Load notebooks from local SQLite + filesystem cache.
  /// Falls back to ZIP parsing only if DB metadata is incomplete.
  Future<void> _loadFromLocalCache(FileService fileService) async {
    await _loadFromLocalDb(fileService);
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
