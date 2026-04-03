import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
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

  /// Carica la lista dei notebook dal server.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final syncService = _ref.read(syncServiceProvider);
      final webdav = _ref.read(webdavServiceProvider);
      if (syncService == null || webdav == null) {
        state = const AsyncValue.data([]);
        return;
      }

      await webdav.ensureBaseDirectory();
      final remoteFiles = await syncService.listRemoteNotebooks();

      final entries = <NotebookEntry>[];
      for (final file in remoteFiles) {
        try {
          final remotePath =
              '${AppConfig.defaultRemotePath}${file.name}';
          final result = await syncService.downloadNotebook(remotePath);
          entries.add(NotebookEntry(
            metadata: result.metadata,
            remotePath: remotePath,
            lastSynced: DateTime.now(),
          ));
        } catch (_) {
          // Skip file corrotti
        }
      }

      // Ordina per data modifica (più recente prima)
      entries.sort(
          (a, b) => b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt));
      state = AsyncValue.data(entries);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Crea un nuovo notebook vuoto e lo carica sul server.
  Future<NotebookEntry> createNotebook({
    required String title,
    String paperType = 'lined',
    int coverColor = 0xFF1565C0,
  }) async {
    final syncService = _ref.read(syncServiceProvider);
    if (syncService == null) throw Exception('Non connesso');

    final uuid = const Uuid();
    final notebookId = uuid.v4();
    final now = DateTime.now();
    final pageId = uuid.v4();

    final metadata = NotebookMetadata(
      id: notebookId,
      title: title,
      createdAt: now,
      modifiedAt: now,
      paperType: paperType,
      coverColor: coverColor,
      pageCount: 1,
    );

    final document = DocumentStructure(
      notebookId: notebookId,
      pages: [
        PageEntry(
          pageId: pageId,
          pageNumber: 1,
          fileName: 'page_001.json',
          lastModified: now,
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

    await syncService.uploadNotebook(
      remotePath: remotePath,
      metadata: metadata,
      document: document,
      pages: {'page_001.json': pageData},
    );

    final entry = NotebookEntry(
      metadata: metadata,
      remotePath: remotePath,
      lastSynced: DateTime.now(),
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
