import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/services/webdav_service.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

/// Stato di sincronizzazione di un notebook.
enum SyncStatus { synced, modified, uploading, downloading, conflict, error }

/// Entry nella coda di sync.
class SyncQueueEntry {
  final String notebookId;
  final String remotePath;
  final List<String> dirtyPages;
  final DateTime queuedAt;
  SyncStatus status;
  String? error;

  SyncQueueEntry({
    required this.notebookId,
    required this.remotePath,
    required this.dirtyPages,
    DateTime? queuedAt,
    this.status = SyncStatus.modified,
    this.error,
  }) : queuedAt = queuedAt ?? DateTime.now();
}

/// Engine di sincronizzazione offline-first.
///
/// Strategia:
/// 1. Ogni modifica va prima in locale (immediata)
/// 2. Le pagine modificate vengono marcate "dirty"
/// 3. Un timer periodico (o manuale) triggera il sync
/// 4. Upload solo delle pagine dirty (delta sync)
/// 5. Conflict detection via ETag comparison
class SyncService {
  final WebDavService _webdav;
  final Map<String, SyncQueueEntry> _syncQueue = {};
  final Map<String, String> _etagCache = {}; // notebookId → etag
  Timer? _autoSyncTimer;
  bool _isSyncing = false;

  /// Callback per notificare la UI dello stato sync.
  void Function(String notebookId, SyncStatus status)? onStatusChanged;

  SyncService(this._webdav);

  // ── Integrity Protection ──

  /// Validates that a byte buffer is a well-formed ZIP with the required
  /// ncnote entries (metadata.json + document.json).
  /// Throws [CorruptedArchiveException] on failure.
  static void validateNcnoteArchive(Uint8List data, {String context = ''}) {
    if (data.length < 22) {
      throw CorruptedArchiveException(
        'Archive too small (${data.length} bytes)${context.isNotEmpty ? ' [$context]' : ''}',
      );
    }
    // Quick check: ZIP magic number
    if (data[0] != 0x50 || data[1] != 0x4B) {
      throw CorruptedArchiveException(
        'Not a ZIP file (bad magic)${context.isNotEmpty ? ' [$context]' : ''}',
      );
    }
    // Full parse to find End of Central Directory
    try {
      final archive = ZipDecoder().decodeBytes(data);
      final hasMetadata = archive.findFile(AppConfig.metadataFile) != null;
      final hasDocument = archive.findFile(AppConfig.documentFile) != null;
      if (!hasMetadata || !hasDocument) {
        throw CorruptedArchiveException(
          'Missing required files (metadata=$hasMetadata, document=$hasDocument)'
          '${context.isNotEmpty ? ' [$context]' : ''}',
        );
      }
    } on CorruptedArchiveException {
      rethrow;
    } catch (e) {
      throw CorruptedArchiveException(
        'ZIP parse failed: $e${context.isNotEmpty ? ' [$context]' : ''}',
      );
    }
  }

  /// Checks if the WebDAV server is reachable before starting a sync.
  /// Returns true if a lightweight PROPFIND succeeds within timeout.
  Future<bool> isServerReachable() async {
    try {
      return await _webdav.testConnection();
    } catch (_) {
      return false;
    }
  }

  /// Avvia il sync automatico periodico.
  void startAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer.periodic(AppConfig.syncInterval, (_) {
      syncAll();
    });
  }

  /// Ferma il sync automatico.
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Marca una pagina come modificata (dirty).
  /// Triggera un sync debounced.
  void markDirty(String notebookId, String pageId, String remotePath) {
    final entry = _syncQueue[notebookId];
    if (entry != null) {
      if (!entry.dirtyPages.contains(pageId)) {
        entry.dirtyPages.add(pageId);
      }
      entry.status = SyncStatus.modified;
    } else {
      _syncQueue[notebookId] = SyncQueueEntry(
        notebookId: notebookId,
        remotePath: remotePath,
        dirtyPages: [pageId],
      );
    }
    onStatusChanged?.call(notebookId, SyncStatus.modified);
  }

  /// Sincronizza tutti i notebook nella coda.
  /// Checks network connectivity before starting.
  Future<void> syncAll() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      // ── Network pre-check ──
      if (!await isServerReachable()) {
        debugPrint('[Sync] Server unreachable, skipping sync cycle.');
        return;
      }

      final entries = _syncQueue.values
          .where((e) => e.status == SyncStatus.modified)
          .toList();

      for (final entry in entries) {
        await _syncNotebook(entry);
      }
    } finally {
      _isSyncing = false;
    }
  }

  /// Sincronizza un singolo notebook.
  Future<void> syncNotebook(String notebookId) async {
    final entry = _syncQueue[notebookId];
    if (entry == null) return;
    await _syncNotebook(entry);
  }

  /// Logica di sync per un notebook.
  Future<void> _syncNotebook(SyncQueueEntry entry) async {
    try {
      entry.status = SyncStatus.uploading;
      onStatusChanged?.call(entry.notebookId, SyncStatus.uploading);

      // 1. Check conflict via ETag
      final remoteEtag = await _webdav.getEtag(entry.remotePath);
      final cachedEtag = _etagCache[entry.notebookId];

      if (cachedEtag != null && remoteEtag != null && cachedEtag != remoteEtag) {
        // Conflitto: il file è stato modificato remotamente
        entry.status = SyncStatus.conflict;
        onStatusChanged?.call(entry.notebookId, SyncStatus.conflict);
        await _handleConflict(entry, remoteEtag);
        return;
      }

      // 2. Upload: per ora upload dell'intero .ncnote
      //    In futuro: upload solo pagine dirty (richiede supporto PATCH o
      //    decompressione/ricompressione lato server)
      //
      //    Per Fase 1: upload completo del file .ncnote

      // In fase 1, il sync effettivo richiede il file locale.
      // Qui definiamo l'interfaccia che verrà implementata con FileService.

      entry.status = SyncStatus.synced;
      entry.dirtyPages.clear();
      if (remoteEtag != null) {
        _etagCache[entry.notebookId] = remoteEtag;
      }
      onStatusChanged?.call(entry.notebookId, SyncStatus.synced);

      // Rimuovi dalla coda
      _syncQueue.remove(entry.notebookId);
    } catch (e) {
      entry.status = SyncStatus.error;
      entry.error = e.toString();
      onStatusChanged?.call(entry.notebookId, SyncStatus.error);
    }
  }

  /// Gestisce un conflitto di sync.
  Future<void> _handleConflict(SyncQueueEntry entry, String remoteEtag) async {
    // Strategia: Last-Write-Wins con backup del conflitto
    // 1. Scarica versione remota
    // 2. Salvala come backup con suffisso _conflict_<timestamp>
    // 3. Carica versione locale (wins)
    // 4. Notifica utente

    try {
      // Scarica versione remota come backup
      final remoteData = await _webdav.downloadFile(entry.remotePath);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final conflictPath = entry.remotePath.replaceAll(
        AppConfig.fileExtension,
        '_conflict_$timestamp${AppConfig.fileExtension}',
      );
      await _webdav.uploadFile(conflictPath, remoteData);

      // La versione locale verrà caricata al prossimo sync cycle
      entry.status = SyncStatus.modified;
      _etagCache.remove(entry.notebookId);
      onStatusChanged?.call(entry.notebookId, SyncStatus.modified);
    } catch (e) {
      entry.status = SyncStatus.error;
      entry.error = 'Conflict resolution failed: $e';
      onStatusChanged?.call(entry.notebookId, SyncStatus.error);
    }
  }

  /// Scarica un notebook dal server e lo decomprime.
  /// Ritorna metadata e document structure.
  /// Validates ZIP integrity before parsing.
  Future<({NotebookMetadata metadata, DocumentStructure document})>
      downloadNotebook(String remotePath) async {
    final data = await _webdav.downloadFile(remotePath);

    // ── Post-download size verification ──
    try {
      final expectedSize = await _webdav.getContentLength(remotePath);
      if (expectedSize != null && expectedSize != data.length) {
        throw CorruptedArchiveException(
          'Download truncated for $remotePath: expected $expectedSize bytes, '
          'got ${data.length} bytes',
        );
      }
    } catch (e) {
      if (e is CorruptedArchiveException) rethrow;
      // Non-critical — proceed with ZIP validation
    }

    // ── Validate archive integrity ──
    validateNcnoteArchive(data, context: 'download $remotePath');
    return _parseNcnoteArchive(data);
  }

  /// Scarica una singola pagina da un archivio .ncnote in cache.
  /// Per ora scarica l'intero file e estrae la pagina richiesta.
  Future<PageData> downloadPage(
    String remotePath,
    String pageFileName,
  ) async {
    final data = await _webdav.downloadFile(remotePath);
    final archive = ZipDecoder().decodeBytes(data);

    final pageFile = archive.findFile('${AppConfig.pagesDir}/$pageFileName');
    if (pageFile == null) {
      throw Exception('Page not found in archive: $pageFileName');
    }

    final json = jsonDecode(utf8.decode(pageFile.content as List<int>));
    return PageData.fromJson(json as Map<String, dynamic>);
  }

  /// Crea un pacchetto .ncnote da metadata, document e pagine.
  Uint8List createNcnotePackage({
    required NotebookMetadata metadata,
    required DocumentStructure document,
    required Map<String, PageData> pages,
    Map<String, Uint8List>? assets,
    List<Map<String, dynamic>>? symbolLibraries,
  }) {
    final archive = Archive();

    // metadata.json
    final metadataJson = jsonEncode(metadata.toJson());
    archive.addFile(ArchiveFile(
      AppConfig.metadataFile,
      metadataJson.length,
      utf8.encode(metadataJson),
    ));

    // document.json
    final documentJson = jsonEncode(document.toJson());
    archive.addFile(ArchiveFile(
      AppConfig.documentFile,
      documentJson.length,
      utf8.encode(documentJson),
    ));

    // pages/
    for (final entry in pages.entries) {
      final pageJson = jsonEncode(entry.value.toJson());
      archive.addFile(ArchiveFile(
        '${AppConfig.pagesDir}/${entry.key}',
        pageJson.length,
        utf8.encode(pageJson),
      ));
    }

    // assets/
    if (assets != null) {
      for (final entry in assets.entries) {
        archive.addFile(ArchiveFile(
          '${AppConfig.assetsDir}/${entry.key}',
          entry.value.length,
          entry.value,
        ));
      }
    }

    // symbols.json
    if (symbolLibraries != null && symbolLibraries.isNotEmpty) {
      final symbolsJson = jsonEncode(symbolLibraries);
      archive.addFile(ArchiveFile(
        'symbols.json',
        symbolsJson.length,
        utf8.encode(symbolsJson),
      ));
    }

    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// Parsa un archivio .ncnote scaricato.
  ({NotebookMetadata metadata, DocumentStructure document})
      _parseNcnoteArchive(Uint8List data) {
    final archive = ZipDecoder().decodeBytes(data);

    // Estrai metadata.json
    final metadataFile = archive.findFile(AppConfig.metadataFile);
    if (metadataFile == null) {
      throw Exception('Invalid .ncnote: missing ${AppConfig.metadataFile}');
    }
    final metadataJson = jsonDecode(
      utf8.decode(metadataFile.content as List<int>),
    );
    final metadata =
        NotebookMetadata.fromJson(metadataJson as Map<String, dynamic>);

    // Estrai document.json
    final documentFile = archive.findFile(AppConfig.documentFile);
    if (documentFile == null) {
      throw Exception('Invalid .ncnote: missing ${AppConfig.documentFile}');
    }
    final documentJson = jsonDecode(
      utf8.decode(documentFile.content as List<int>),
    );
    final document =
        DocumentStructure.fromJson(documentJson as Map<String, dynamic>);

    return (metadata: metadata, document: document);
  }

  /// Public wrapper for parsing .ncnote metadata from raw bytes.
  /// Used by the library to read from local cache.
  ({NotebookMetadata metadata, DocumentStructure document})
      parseNcnoteMetadata(Uint8List data) => _parseNcnoteArchive(data);

  /// Lista i notebook .ncnote presenti sul server nella cartella base.
  /// Throws on network/server errors so the UI can show them.
  Future<List<WebDavItem>> listRemoteNotebooks() async {
    await _webdav.ensureBaseDirectory();
    final items = await _webdav.listDirectory(_webdav.basePath);
    return items
        .where((item) =>
            !item.isDirectory &&
            item.name.endsWith(AppConfig.fileExtension))
        .toList();
  }

  /// Upload di un notebook completo sul server.
  /// Extract symbol libraries from an .ncnote archive.
  List<Map<String, dynamic>> extractSymbolLibraries(Uint8List data) {
    final archive = ZipDecoder().decodeBytes(data);
    final symbolsFile = archive.findFile('symbols.json');
    if (symbolsFile == null) return [];
    try {
      final json = jsonDecode(utf8.decode(symbolsFile.content as List<int>));
      return (json as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<String?> uploadNotebook({
    required String remotePath,
    required NotebookMetadata metadata,
    required DocumentStructure document,
    required Map<String, PageData> pages,
    Map<String, Uint8List>? assets,
    List<Map<String, dynamic>>? symbolLibraries,
  }) async {
    final package = createNcnotePackage(
      metadata: metadata,
      document: document,
      pages: pages,
      assets: assets,
      symbolLibraries: symbolLibraries,
    );

    // ── Pre-upload validation ──
    validateNcnoteArchive(package, context: 'pre-upload ${metadata.title}');
    debugPrint('[Sync] Validated package for "${metadata.title}": '
        '${package.length} bytes, uploading...');

    final etag = await _webdav.uploadFile(remotePath, package);
    if (etag != null) {
      _etagCache[metadata.id] = etag;
    }

    // ── Post-upload size verification ──
    try {
      final remoteSize = await _webdav.getContentLength(remotePath);
      if (remoteSize != null && remoteSize != package.length) {
        debugPrint('[Sync] WARNING: Upload size mismatch for '
            '"${metadata.title}": local=${package.length}, '
            'remote=$remoteSize — upload may be corrupted!');
        throw CorruptedArchiveException(
          'Upload size mismatch: expected ${package.length} bytes, '
          'server has $remoteSize bytes. Upload corrupted.',
        );
      }
      debugPrint('[Sync] Upload verified for "${metadata.title}": '
          '$remoteSize bytes on server.');
    } catch (e) {
      if (e is CorruptedArchiveException) rethrow;
      // Non-critical: size check failed but upload itself succeeded
      debugPrint('[Sync] Could not verify upload size: $e');
    }

    return etag;
  }

  /// Estrae tutte le pagine da un archivio .ncnote raw bytes.
  Map<String, PageData> extractAllPages(Uint8List data) {
    final archive = ZipDecoder().decodeBytes(data);
    final pages = <String, PageData>{};

    for (final file in archive.files) {
      if (file.name.startsWith('${AppConfig.pagesDir}/') &&
          file.name.endsWith('.json')) {
        final fileName = file.name.split('/').last;
        final json = jsonDecode(utf8.decode(file.content as List<int>));
        pages[fileName] = PageData.fromJson(json as Map<String, dynamic>);
      }
    }

    return pages;
  }

  /// Scarica un notebook completo con tutte le pagine.
  /// Validates ZIP integrity before parsing.
  Future<({NotebookMetadata metadata, DocumentStructure document, Map<String, PageData> pages, Map<String, Uint8List> assets, List<Map<String, dynamic>> symbolLibraries})>
      downloadNotebookFull(String remotePath) async {
    final data = await _webdav.downloadFile(remotePath);

    // ── Validate before any parsing ──
    validateNcnoteArchive(data, context: 'downloadFull $remotePath');

    final result = _parseNcnoteArchive(data);
    final pages = extractAllPages(data);
    final assets = extractAllAssets(data);
    final symbols = extractSymbolLibraries(data);
    return (
      metadata: result.metadata,
      document: result.document,
      pages: pages,
      assets: assets,
      symbolLibraries: symbols,
    );
  }

  /// Estrae tutti gli asset binari (immagini) da un archivio .ncnote.
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

  void dispose() {
    stopAutoSync();
  }
}

/// Exception thrown when a .ncnote archive is detected as corrupted.
class CorruptedArchiveException implements Exception {
  final String message;
  CorruptedArchiveException(this.message);

  @override
  String toString() => 'CorruptedArchiveException: $message';
}
