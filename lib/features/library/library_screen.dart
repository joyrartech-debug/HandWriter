import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/config/app_config.dart';
import 'package:handwriter/core/providers/app_settings_provider.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/services/crash_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/cross_notebook_clipboard_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/providers/pending_import_provider.dart';
import 'package:handwriter/core/services/share_receiver.dart';
import 'package:handwriter/core/services/file_service.dart';
import 'package:handwriter/core/services/search_service.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/features/canvas/presentation/canvas_screen.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedTags = <String>{};
  Timer? _bgSyncTimer;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      ref.read(notebookListProvider.notifier).refresh();
      _startConnectivityMonitor();
      _startBackgroundSync();
      // Retry uploads that a prior session couldn't complete (offline,
      // Tailscale drop mid-save). Runs after refresh so local DB is fresh.
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        await ref.read(notebookListProvider.notifier).retryPendingUploads();
      } catch (e) {
        debugPrint('[Library] retryPendingUploads on boot failed: $e');
      }
    });
  }

  @override
  void dispose() {
    _bgSyncTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _startBackgroundSync() {
    _bgSyncTimer?.cancel();
    // Run every 90 seconds. First run after 30s (give app time to settle).
    Future.delayed(const Duration(seconds: 30), () {
      if (!mounted) return;
      _runBackgroundSync();
      _bgSyncTimer = Timer.periodic(const Duration(seconds: 90), (_) {
        if (mounted) _runBackgroundSync();
      });
    });
  }

  Future<void> _runBackgroundSync() async {
    final syncService = ref.read(syncServiceProvider);
    final fileService = ref.read(fileServiceProvider);
    if (syncService == null) return;

    // If the user has a notebook open, do NOT start a BgSync cycle at all.
    // BgSync downloads every page of every notebook it thinks has changed;
    // even if the open notebook itself is skipped, the parallel HTTP load
    // on Tailscale starves the open canvas's 2 s pull timer and makes it
    // feel like "I saved on iPad but PC still shows old content". The
    // open notebook has its own per-page delta sync — let it run alone.
    final openId = ref.read(canvasProvider)?.metadata.id;
    if (openId != null) {
      debugPrint('[BgSync] Skipping cycle — notebook $openId is open');
      return;
    }

    final notebooks = ref.read(notebookListProvider).valueOrNull ?? const [];
    if (notebooks.isEmpty) return;

    bool anyUpdated = false;

    // Pre-load SharedPreferences once so per-notebook lookups are cheap.
    final prefs = await SharedPreferences.getInstance();

    for (final entry in notebooks) {
      final id = entry.metadata.id;

      try {
        // 1. Check if anything changed remotely
        final changeState = await syncService.getRemoteChangeState(id);
        final storedMeta = await fileService.getNotebookMeta(id);
        final storedEtag = storedMeta?['etag'] as String?;
        // Canvas's pull path persists the meta ETag to SharedPreferences
        // (and the DB mirror was added in 0.33.1). For older installs the
        // DB column can still be stale — fall back to prefs so BgSync
        // doesn't re-download every page after a pure-pull-close cycle.
        final prefsEtag = prefs.getString('delta_meta_etag_$id');

        // Skip notebooks with local unsaved changes — _syncDirtyNotebooks handles
        // them and has conflict-resolution logic.  'pending' is intentionally not
        // skipped: it means a prior BgSync cycle saved a partial notebook and this
        // cycle should retry downloading the remaining pages.
        final bgSyncStatus = storedMeta?['sync_status'] as String?;
        if (bgSyncStatus == 'modified' || bgSyncStatus == 'new') continue;

        if (changeState.metaEtag != null &&
            (changeState.metaEtag == storedEtag ||
             changeState.metaEtag == prefsEtag)) {
          continue; // nothing changed on the server since we last synced
        }

        debugPrint('[BgSync] Syncing ${entry.metadata.title}...');

        // 2. Load local .ncnote
        final localBytes = await fileService.readNotebookFile(id);

        // 3. Download remote metadata + ALL pages from the delta folder.
        //
        // Previously this only fetched pages *missing* from the local .ncnote.
        // That was wrong: a page can exist locally but have *stale content*
        // (modified on another device since the last sync).  We must overwrite
        // those pages so the device gets the up-to-date content.
        //
        // Safety: we only reach here for 'synced' / 'pending' notebooks (the
        // 'modified' / 'new' guard above skips notebooks with local edits), so
        // overwriting every page with the server version is safe.
        final remoteMeta = await syncService.downloadDeltaMeta(id);

        Map<String, PageData> mergedPages;
        Map<String, Uint8List> mergedAssets;
        List<Map<String, dynamic>> symbols = [];

        if (localBytes != null) {
          // Run ZIP decoding off the UI thread — large notebooks with many
          // pages/images would otherwise freeze the app (especially on iPad).
          mergedPages = Map<String, PageData>.from(
              await syncService.extractAllPagesIsolated(localBytes));
          mergedAssets = Map<String, Uint8List>.from(
              await syncService.extractAllAssetsIsolated(localBytes));
          try {
            symbols = syncService.extractSymbolLibraries(localBytes);
          } catch (_) {}
        } else {
          mergedPages = {};
          mergedAssets = {};
        }

        // ── Per-page ETag diff: download ONLY pages whose ETag moved ──
        //
        // Previously this loop fetched every page listed in remote document
        // even when local already had identical content, just because the
        // notebook-level meta ETag had changed. On Tailscale that burned
        // 30+ MB per cycle for a large notebook that had merely been
        // re-saved elsewhere (140 pages x ~200 KB = 28 MB). Now we compare
        // each page's WebDAV ETag against a persisted per-notebook cache
        // and only download the real diff — typically 0-3 pages per cycle.
        final etagKey = 'bgsync_page_etags_$id';
        Map<String, String> cachedPageEtags = {};
        try {
          final raw = prefs.getString(etagKey);
          if (raw != null && raw.isNotEmpty) {
            cachedPageEtags = Map<String, String>.from(
                jsonDecode(raw) as Map<String, dynamic>);
          }
        } catch (_) {}

        final remotePageEtags = changeState.pageEtags;
        final allRemotePageNames = remoteMeta.document.pages
            .map((p) => p.fileName)
            .where((fn) => fn.isNotEmpty)
            .toList();
        final pagesToFetch = <String>[];
        final phantomPages = <String>[];
        for (final fn in allRemotePageNames) {
          final remoteEtag = remotePageEtags[fn];
          // A page can be listed in document.json but absent from pages/
          // folder when a previous save uploaded the document update but
          // failed on the page body. We can't fetch what the server doesn't
          // have — skip instead of firing a 404 retry burst.
          if (remoteEtag == null) {
            phantomPages.add(fn);
            continue;
          }
          final cachedEtag = cachedPageEtags[fn];
          final etagChanged = remoteEtag != cachedEtag;
          final missingLocally = !mergedPages.containsKey(fn);
          if (etagChanged || missingLocally) pagesToFetch.add(fn);
        }
        if (phantomPages.isNotEmpty) {
          debugPrint('[BgSync] ${entry.metadata.title}: '
              '${phantomPages.length} pages listed in document but missing '
              'from pages/ folder (phantom): ${phantomPages.take(3).join(", ")}'
              '${phantomPages.length > 3 ? "..." : ""}');
        }

        if (pagesToFetch.isNotEmpty) {
          debugPrint('[BgSync] Downloading ${pagesToFetch.length} pages '
              'for ${entry.metadata.title} '
              '(${pagesToFetch.where((fn) => !mergedPages.containsKey(fn)).length} new, '
              '${pagesToFetch.where((fn) => mergedPages.containsKey(fn)).length} refresh)');

          // Helper: download a single page with retries
          Future<PageData?> fetchPage(String fn) async {
            const maxRetries = 3;
            for (var attempt = 0; attempt < maxRetries; attempt++) {
              try {
                return await syncService.downloadDeltaPage(id, fn);
              } catch (e) {
                if (attempt == maxRetries - 1) {
                  debugPrint('[BgSync] FAILED page $fn for ${entry.metadata.title} after $maxRetries attempts: $e');
                  return null;
                }
                await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
              }
            }
            return null;
          }

          final pageResults = await Future.wait(
            pagesToFetch.map((fn) async => (fn, await fetchPage(fn))),
          );
          for (final (fn, page) in pageResults) {
            if (page != null) mergedPages[fn] = page;
          }
        } else {
          debugPrint('[BgSync] ${entry.metadata.title}: no per-page ETag changes, skipping page downloads');
        }

        // Persist the updated per-page ETag cache for the next cycle.
        try {
          await prefs.setString(etagKey, jsonEncode(remotePageEtags));
        } catch (_) {}

        // If any pages that document.json references still have no data,
        // trim the document to only the pages we actually have.  This prevents
        // saving a malformed .ncnote (document lists pages that aren't in the
        // ZIP), which would otherwise corrupt the notebook.  The next background
        // sync cycle will retry the missing pages.
        final stillMissing = remoteMeta.document.pages
            .where((p) => p.fileName.isNotEmpty && !mergedPages.containsKey(p.fileName))
            .toList();
        final effectiveDocument = stillMissing.isEmpty
            ? remoteMeta.document
            : remoteMeta.document.copyWith(
                pages: remoteMeta.document.pages
                    .where((p) => mergedPages.containsKey(p.fileName))
                    .toList(),
              );
        if (stillMissing.isNotEmpty) {
          debugPrint('[BgSync] ${entry.metadata.title}: saving partial notebook '
              '(${effectiveDocument.pages.length}/${remoteMeta.document.pages.length} pages). '
              'Missing: ${stillMissing.map((p) => p.fileName).join(', ')}');
        }

        // Download missing assets
        final allAssetRefs = <String>{};
        for (final page in mergedPages.values) {
          allAssetRefs.addAll(page.assetReferences);
          for (final el in page.layers.content) {
            el.map(
              stroke: (_) {},
              text: (_) {},
              shape: (_) {},
              image: (img) {
                if (img.data.assetPath.isNotEmpty) allAssetRefs.add(img.data.assetPath);
              },
            );
          }
        }
        final missingAssets = allAssetRefs.where((r) => !mergedAssets.containsKey(r)).toList();
        if (missingAssets.isNotEmpty) {
          final assetResults = await Future.wait(
            missingAssets.map((assetRef) async {
              try {
                final data = await syncService.downloadDeltaAsset(id, assetRef);
                return (assetRef, data, null as Object?);
              } catch (e) {
                return (assetRef, null as Uint8List?, e);
              }
            }),
          );
          for (final (assetRef, data, _) in assetResults) {
            if (data != null) mergedAssets[assetRef] = data;
          }
        }

        // 4. Build and save updated .ncnote (off the UI thread).
        // Use effectiveDocument (trimmed to pages we have data for) so the ZIP
        // is always self-consistent.
        final effectiveMetadata = stillMissing.isEmpty
            ? remoteMeta.metadata
            : remoteMeta.metadata.copyWith(
                pageCount: effectiveDocument.pages.length);
        final bytes = await SyncService.buildPackageBytesIsolated(
          metadata: effectiveMetadata,
          document: effectiveDocument,
          pages: mergedPages,
          assets: mergedAssets,
          symbolLibraries: symbols,
        );
        await fileService.saveNotebookFile(id, bytes);

        // 5. Update DB
        await fileService.upsertNotebookMeta(
          id: id,
          title: effectiveMetadata.title,
          remotePath: entry.remotePath,
          localModifiedAt: effectiveMetadata.modifiedAt,
          // If we only saved a partial notebook, don't advance the ETag — force
          // the next sync cycle to retry and finish the download.
          syncStatus: stillMissing.isEmpty ? 'synced' : 'pending',
          fileSize: bytes.length,
          coverColor: effectiveMetadata.coverColor,
          paperType: effectiveMetadata.paperType,
          pageCount: effectiveMetadata.pageCount,
          createdAt: effectiveMetadata.createdAt,
          etag: stillMissing.isEmpty ? changeState.metaEtag : null,
        );

        anyUpdated = true;
        debugPrint('[BgSync] ${entry.metadata.title} synced '
            '(${effectiveDocument.pages.length} pages saved'
            '${stillMissing.isNotEmpty ? ", ${stillMissing.length} still missing — will retry" : ""}'
            ')');
      } catch (e) {
        debugPrint('[BgSync] Failed to sync ${entry.metadata.title}: $e');
      }
    }

    // Refresh library cards if anything changed
    if (anyUpdated && mounted) {
      ref.read(notebookListProvider.notifier).refresh();
    }
  }

  void _startConnectivityMonitor() {
    final connectivity = ref.read(connectivityServiceProvider);
    if (connectivity == null) return;

    connectivity.onReconnected = () async {
      // First action on reconnect: wake up the WebDAV client. On iOS the
      // dart:io NSURLSession can get stuck after a Tailscale/WiFi handoff
      // — every call returns null even though Safari works. Forcing a
      // fresh client here beats waiting for the zombie-detector inside
      // WebDavService to trip on 3 consecutive failures.
      try {
        ref.read(webdavServiceProvider)?.wakeUp();
      } catch (e) {
        debugPrint('[Library] webdav wakeUp failed: $e');
      }
      // Delta-based retry is fast (only uploads changed pages) so try it
      // first — if the notebook has a delta folder on the server it'll
      // complete in a few hundred ms. _syncDirtyNotebooks is the legacy
      // full-ZIP fallback that still handles notebooks created before the
      // delta era.
      try {
        await ref.read(notebookListProvider.notifier).retryPendingUploads();
      } catch (e) {
        debugPrint('[Library] reconnect retryPendingUploads failed: $e');
      }
      // Sync dirty notebooks FIRST (legacy path), then refresh library.
      // Sequential to avoid 423 Locked from Nextcloud.
      await _syncDirtyNotebooks();
      ref.read(notebookListProvider.notifier).refresh();
    };
    connectivity.startMonitoring();
  }

  Future<void> _syncDirtyNotebooks() async {
    final fileService = ref.read(fileServiceProvider);
    final syncService = ref.read(syncServiceProvider);
    if (syncService == null) return;

    final dirtyRows = await fileService.getDirtyNotebooks();
    if (dirtyRows.isEmpty) return;

    debugPrint('[Library] Syncing ${dirtyRows.length} dirty notebooks after reconnection');
    for (final row in dirtyRows) {
      final id = row['id'] as String;
      final remotePath = row['remote_path'] as String;
      final cachedEtag = row['etag'] as String?;
      final localModifiedAt = DateTime.tryParse(
        row['local_modified_at'] as String? ?? '',
      );
      try {
        final localData = await fileService.readNotebookFile(id);
        if (localData == null) continue;

        SyncService.validateNcnoteArchive(localData, context: 'reconnect-sync $id');

        // ── Conflict check: did another device change the remote file? ──
        final remoteInfo = await syncService.getNcnoteInfo(remotePath);
        final remoteEtag = remoteInfo?.etag;
        final remoteLastModified = remoteInfo?.lastModified;

        final etagChanged = cachedEtag != null &&
            remoteEtag != null &&
            cachedEtag != remoteEtag;

        if (etagChanged) {
          // True conflict. Decide winner by timestamp instead of blindly
          // overwriting the remote. Symptom we're fixing: PC opens stale,
          // uploads old ZIP, and clobbers iPad's recent edits on the server.
          final remoteIsNewer = remoteLastModified != null &&
              localModifiedAt != null &&
              remoteLastModified.isAfter(
                // Allow a small clock-skew grace window so we don't ping-pong
                // when both devices bumped mtime within a second.
                localModifiedAt.add(const Duration(seconds: 2)),
              );
          if (remoteIsNewer) {
            // Remote wins. Back up OUR local copy as a conflict file so no
            // unsynced edits are lost, then replace local with the remote.
            debugPrint(
              '[Library] Conflict for $id — remote newer '
              '(local=$localModifiedAt, remote=$remoteLastModified). Pulling remote.',
            );
            try {
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              final conflictPath = remotePath.replaceAll(
                '.ncnote',
                '_local_conflict_$timestamp.ncnote',
              );
              await syncService.uploadRawPackage(conflictPath, localData);
              debugPrint('[Library] Local backup saved: $conflictPath');
            } catch (e) {
              debugPrint('[Library] Could not back up local version: $e');
            }
            try {
              final remoteData = await syncService.downloadFile(remotePath);
              await fileService.saveNotebookFile(id, remoteData);
              await fileService.markNotebookSynced(id, remoteEtag);
              debugPrint('[Library] $id replaced with remote version');
            } catch (e) {
              debugPrint('[Library] Failed to pull remote for $id: $e');
            }
            // Skip the upload path entirely — remote already has what we want.
            continue;
          }
          // Local is newer (or timestamps unavailable but ETag differs and
          // we genuinely have dirty local edits). Preserve the existing
          // remote as a conflict file, then upload local.
          debugPrint('[Library] Conflict for $id — local newer, backing up remote');
          try {
            final remoteData = await syncService.downloadFile(remotePath);
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            final conflictPath = remotePath.replaceAll(
              '.ncnote',
              '_conflict_$timestamp.ncnote',
            );
            await syncService.uploadRawPackage(conflictPath, remoteData);
            debugPrint('[Library] Remote backup saved: $conflictPath');
          } catch (e) {
            debugPrint('[Library] Could not back up remote version: $e');
          }
        }

        // Upload full ZIP to the classic path
        final etag = await syncService.uploadRawPackage(remotePath, localData);
        await fileService.markNotebookSynced(id, etag);
        debugPrint('[Library] Synced $id (full ZIP)');

        // Migrate/update exploded delta folder — non-fatal if it fails
        try {
          if (!await syncService.deltaFolderExists(id)) {
            debugPrint('[Library] Migrating $id to exploded format...');
            await syncService.migrateToExploded(id, localData);
            debugPrint('[Library] Migration complete for $id');
          } else {
            final parsed = syncService.parseNcnoteMetadata(localData);
            // Offload to isolates — reconnect-sync runs on the UI thread and
            // large notebooks would otherwise freeze the app.
            final pages = await syncService.extractAllPagesIsolated(localData);
            final assets = await syncService.extractAllAssetsIsolated(localData);
            final symbols = syncService.extractSymbolLibraries(localData);
            await syncService.syncDelta(
              notebookId: id,
              metadata: parsed.metadata,
              document: parsed.document,
              dirtyPages: pages,
              dirtyAssets: assets.isNotEmpty ? assets : null,
              symbolLibraries: symbols.isNotEmpty ? symbols : null,
            );
          }
        } catch (e) {
          debugPrint('[Library] Delta migration deferred for $id: $e');
        }
      } catch (e) {
        debugPrint('[Library] Failed to sync $id: $e');
      }
    }
  }

  Future<void> _createNotebook() async {
    final titleController = TextEditingController();
    final tagController = TextEditingController();
    String paperType = 'lined_wide';
    int coverColor = 0xFF1565C0;
    final initialTags = <String>{};

    final coverColors = [
      (0xFF1565C0, 'Blu'),
      (0xFFC62828, 'Rosso'),
      (0xFF2E7D32, 'Verde'),
      (0xFFF57F17, 'Giallo'),
      (0xFF6A1B9A, 'Viola'),
      (0xFF00838F, 'Teal'),
      (0xFFEF6C00, 'Arancio'),
      (0xFF424242, 'Grigio'),
      (0xFF37474F, 'Antracite'),
      (0xFF4E342E, 'Marrone'),
    ];

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.note_add_rounded, color: Colors.blue.shade600, size: 24),
              ),
              const SizedBox(width: 12),
              const Text('Nuovo Notebook'),
            ],
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    labelText: 'Titolo',
                    hintText: 'Il mio notebook',
                    prefixIcon: const Icon(Icons.title),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                  ),
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 20),
                Text('Tipo di carta', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _PaperChip(label: 'Bianco', icon: Icons.rectangle_outlined, value: 'blank', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Righe strette', icon: Icons.density_small, value: 'lined_narrow', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Righe larghe', icon: Icons.density_large, value: 'lined_wide', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Quadretti', icon: Icons.grid_on, value: 'grid', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                    _PaperChip(label: 'Puntinato', icon: Icons.more_horiz, value: 'dotted', selected: paperType, onTap: (v) => setDialogState(() => paperType = v)),
                  ],
                ),
                const SizedBox(height: 20),
                Text('Tag (opzionali)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                TextField(
                  controller: tagController,
                  decoration: InputDecoration(
                    hintText: 'Invio per aggiungere…',
                    prefixIcon: const Icon(Icons.tag, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isEmpty) return;
                    setDialogState(() {
                      initialTags.add(t);
                      tagController.clear();
                    });
                  },
                ),
                if (initialTags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: initialTags.map((t) => InputChip(
                      label: Text('#$t', style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setDialogState(() => initialTags.remove(t)),
                      visualDensity: VisualDensity.compact,
                    )).toList(),
                  ),
                ],
                const SizedBox(height: 20),
                Text('Colore copertina', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: coverColors.map((c) {
                    final isSelected = coverColor == c.$1;
                    return GestureDetector(
                      onTap: () => setDialogState(() => coverColor = c.$1),
                      child: Tooltip(
                        message: c.$2,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: Color(c.$1),
                            shape: BoxShape.circle,
                            border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
                            boxShadow: [
                              if (isSelected)
                                BoxShadow(color: Color(c.$1).withValues(alpha: 0.5), blurRadius: 10, spreadRadius: 1),
                              BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, 2)),
                            ],
                          ),
                          child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Crea'),
            ),
          ],
        ),
      ),
    );

    if (result != true || titleController.text.trim().isEmpty) return;

    // Pick up any tag still pending in the input field.
    final stillTyping = tagController.text.trim();
    if (stillTyping.isNotEmpty) initialTags.add(stillTyping);

    try {
      final entry = await ref.read(notebookListProvider.notifier).createNotebook(
        title: titleController.text.trim(),
        paperType: paperType,
        coverColor: coverColor,
        tags: initialTags.toList(),
      );
      if (mounted) _openNotebook(entry);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore: $e')));
    }
  }

  Future<void> _openNotebook(NotebookEntry entry) async {
    // Mark this notebook as recently opened for the 'Recenti' section.
    ref.read(appSettingsProvider.notifier).markOpened(entry.metadata.id);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20)],
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Apertura notebook...', style: TextStyle(fontSize: 14, decoration: TextDecoration.none, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );

    try {
      final syncService = ref.read(syncServiceProvider);
      final fileService = ref.read(fileServiceProvider);

      // Try local cache first — instant and works offline.
      // We no longer do a pre-open ETag network round-trip here because:
      //  • Every open fires _startPullTimer() → _pullRemoteChanges() immediately,
      //    which already checks the remote delta ETag and downloads any changes.
      //  • The old getDeltaMetaEtag check used a delta ETag for comparison but
      //    _syncWithServer stores the .ncnote file ETag — always a mismatch →
      //    forced a full delta re-download on every single open.
      // The pull timer is the correct place for remote-change detection.
      Uint8List? localData = await fileService.readNotebookFile(entry.metadata.id);

      if (localData != null && syncService != null) {
        SyncService.validateNcnoteArchive(localData, context: 'open local ${entry.metadata.title}');
        final result = syncService.parseNcnoteMetadata(localData);
        // Page + asset extraction on the main isolate blocks the UI and can
        // trigger the iOS watchdog for large notebooks.  Offload both to a
        // background worker beyond a conservative threshold.
        const kLazyThresholdBytes = 512 * 1024; // 512 KB
        const kLazyThresholdPages = 15;
        final bool isLarge = localData.lengthInBytes > kLazyThresholdBytes ||
            result.document.pages.length > kLazyThresholdPages;

        final Map<String, PageData> pages = isLarge
            ? await syncService.extractAllPagesIsolated(localData)
            : syncService.extractAllPages(localData);
        // Assets (embedded images) can be tens of MB for notebooks with photos —
        // always offload to an isolate for large files to avoid OOM-killing on iPad.
        final Map<String, Uint8List> assets = isLarge
            ? await syncService.extractAllAssetsIsolated(localData)
            : syncService.extractAllAssets(localData);
        final symbols = syncService.extractSymbolLibraries(localData);

        // Corruption guard: if the local .ncnote has document entries but the
        // pages/ directory is empty (or missing data for every entry), the
        // notebook would open showing "Nessuna pagina" forever.  Detect this
        // and fall through to a fresh server download instead.
        final corruptedLocal = pages.isEmpty && result.document.pages.isNotEmpty;
        if (corruptedLocal) {
          debugPrint('[Library] Local .ncnote for ${entry.metadata.title} has '
              '${result.document.pages.length} doc entries but 0 pages — '
              'forcing fresh download');
          localData = null; // fall through to downloadExplodedFull below
        }

        // NOTE: we no longer force a blocking `downloadExplodedFull` when
        // the local ZIP has fewer pages than the library card shows.
        // Previously that staleness check ran in the "Apertura notebook..."
        // dialog and could take minutes on a 100-page first-time hydration
        // (user complaint: "ho aspettato piu di 2 minuti e non ha sincro-
        // nizzato tutte le strokes, la scritta sincronizzazione non e' mai
        // apparsa").  The canvas pull timer handles missing pages
        // incrementally, shows a live progress pill, and now persists
        // partial state to disk after every cycle — so closing the app
        // mid-sync no longer throws away the already-downloaded pages.

        if (!corruptedLocal) {
          await ref.read(canvasProvider.notifier).openNotebook(
            metadata: result.metadata,
            document: result.document,
            pages: pages,
            remotePath: entry.remotePath,
            assets: assets,
            symbolLibraries: symbols.isNotEmpty
                ? symbols.map((j) => SymbolLibrary.fromJson(j)).toList()
                : null,
          );

          if (mounted) {
            Navigator.pop(context);
            Navigator.push<Object?>(
              context,
              MaterialPageRoute(builder: (_) => const CanvasScreen()),
            ).then((result) async {
              // The canvas screen hands back its flushPendingWork()
              // future as the pop result so we can await it without
              // blocking the pop animation.  Refreshing BEFORE the
              // flush lands would re-read a stale SQLite row and the
              // library card would still show the old pageCount.
              if (result is Future) {
                try { await result; } catch (_) {}
              }
              if (mounted) {
                ref.read(notebookListProvider.notifier).refresh();
              }
            });
          }
          return;
        }
        // corruptedLocal == true: fall through to downloadExplodedFull below
      }

      // No local cache — must download from server
      if (syncService == null) throw Exception('Non connesso e nessuna copia locale');

      final result = await syncService.downloadExplodedFull(entry.metadata.id);

      // Persist the freshly downloaded exploded tree to a local .ncnote
      // immediately. Otherwise a subsequent close + reopen re-downloads
      // everything from the server (there was no local cache entry).
      try {
        final bytes = SyncService.buildPackageBytes(
          metadata: result.metadata,
          document: result.document,
          pages: result.pages,
          assets: result.assets,
          symbolLibraries: result.symbolLibraries,
        );
        await fileService.saveNotebookFile(result.metadata.id, bytes);
        await fileService.upsertNotebookMeta(
          id: result.metadata.id,
          title: result.metadata.title,
          remotePath: entry.remotePath,
          localModifiedAt: result.metadata.modifiedAt,
          syncStatus: 'synced',
          fileSize: bytes.length,
          coverColor: result.metadata.coverColor,
          paperType: result.metadata.paperType,
          pageCount: result.metadata.pageCount,
          createdAt: result.metadata.createdAt,
        );
      } catch (e) {
        debugPrint('[Library] Failed to persist downloaded notebook locally: $e');
      }

      await ref.read(canvasProvider.notifier).openNotebook(
        metadata: result.metadata,
        document: result.document,
        pages: result.pages,
        remotePath: entry.remotePath,
        assets: result.assets,
        symbolLibraries: result.symbolLibraries.isNotEmpty
            ? result.symbolLibraries.map((j) => SymbolLibrary.fromJson(j)).toList()
            : null,
      );

      if (mounted) {
        Navigator.pop(context);
        Navigator.push<Object?>(
          context,
          MaterialPageRoute(builder: (_) => const CanvasScreen()),
        ).then((result) async {
          if (result is Future) {
            try { await result; } catch (_) {}
          }
          if (mounted) {
            ref.read(notebookListProvider.notifier).refresh();
          }
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Errore apertura: $e')));
      }
    }
  }

  void _showNotebookMenu(NotebookEntry entry) {
    final isFav = ref.read(appSettingsProvider)
        .favoriteNotebookIds
        .contains(entry.metadata.id);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(
                isFav ? Icons.star_rounded : Icons.star_outline_rounded,
                color: isFav ? Colors.amber.shade700 : null,
              ),
              title: Text(isFav ? 'Rimuovi dai preferiti' : 'Aggiungi ai preferiti'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(appSettingsProvider.notifier)
                    .toggleFavorite(entry.metadata.id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rinomina'),
              onTap: () { Navigator.pop(ctx); _renameNotebook(entry); },
            ),
            ListTile(
              leading: const Icon(Icons.tag),
              title: const Text('Modifica tag'),
              onTap: () { Navigator.pop(ctx); _editTags(entry); },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
              title: Text('Elimina', style: TextStyle(color: Colors.red.shade400)),
              onTap: () { Navigator.pop(ctx); _deleteNotebook(entry); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _renameNotebook(NotebookEntry entry) async {
    final controller = TextEditingController(text: entry.metadata.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Rinomina'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.grey.shade50,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Salva')),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && result != entry.metadata.title) {
      try {
        await ref.read(notebookListProvider.notifier).renameNotebook(entry, result);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore rinomina: $e')),
          );
        }
      }
    }
  }

  Future<void> _editTags(NotebookEntry entry) async {
    final tags = <String>{...entry.metadata.tags};
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Modifica tag'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Invio per aggiungere…',
                    prefixIcon: const Icon(Icons.tag, size: 20),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isEmpty) return;
                    setDialogState(() {
                      tags.add(t);
                      controller.clear();
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (tags.isEmpty)
                  Text('Nessun tag', style: TextStyle(color: Colors.grey.shade500, fontSize: 13))
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags.map((t) => InputChip(
                      label: Text('#$t', style: const TextStyle(fontSize: 12)),
                      onDeleted: () => setDialogState(() => tags.remove(t)),
                      visualDensity: VisualDensity.compact,
                    )).toList(),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
            FilledButton(
              onPressed: () {
                final pending = controller.text.trim();
                if (pending.isNotEmpty) tags.add(pending);
                Navigator.pop(ctx, true);
              },
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    try {
      await ref.read(notebookListProvider.notifier).updateNotebookTags(entry, tags.toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore tag: $e')),
        );
      }
    }
  }

  Future<void> _deleteNotebook(NotebookEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Elimina notebook'),
        content: Text('Spostare "${entry.metadata.title}" nel cestino?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final trashId = await ref.read(notebookListProvider.notifier).deleteNotebook(entry);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('"${entry.metadata.title}" spostato nel cestino'),
              action: trashId == null
                  ? null
                  : SnackBarAction(
                      label: 'Annulla',
                      onPressed: () async {
                        try {
                          await ref.read(notebookListProvider.notifier).restoreFromTrash(trashId);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ripristino fallito: $e')),
                            );
                          }
                        }
                      },
                    ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore eliminazione: $e')),
          );
        }
      }
    }
  }

  Future<void> _showSearch() async {
    final search = ref.read(searchServiceProvider);
    if (search == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Servizio di ricerca non disponibile offline senza server')),
      );
      return;
    }
    final queryController = TextEditingController();
    var results = <SearchHit>[];
    var busy = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> runSearch(String q) async {
            if (q.trim().isEmpty) {
              setSheetState(() => results = []);
              return;
            }
            setSheetState(() => busy = true);
            try {
              final hits = await search.search(q);
              if (ctx.mounted) setSheetState(() { results = hits; busy = false; });
            } catch (_) {
              if (ctx.mounted) setSheetState(() => busy = false);
            }
          }

          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            builder: (_, scrollController) => Column(
              children: [
                Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.manage_search_rounded),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Cerca nei contenuti',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: queryController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'titolo, capitolo o testo…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: busy
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      isDense: true,
                    ),
                    onSubmitted: runSearch,
                    onChanged: (v) {
                      // Live search only when query is short enough to be cheap.
                      if (v.length >= 2) runSearch(v);
                    },
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      results.isEmpty
                          ? (queryController.text.trim().isEmpty
                              ? 'Digita per cercare…'
                              : 'Nessun risultato')
                          : '${results.length} risultati',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: results.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final hit = results[i];
                      final kindIcon = switch (hit.kind) {
                        SearchHitKind.notebookTitle => Icons.menu_book_rounded,
                        SearchHitKind.chapter => Icons.bookmark_outline_rounded,
                        SearchHitKind.text => Icons.text_fields_rounded,
                      };
                      return ListTile(
                        leading: Icon(kindIcon, color: Colors.blue.shade600),
                        title: Text(
                          hit.notebookTitle,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'Pag. ${hit.pageNumber} \u2022 ${hit.snippet}',
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          final list = ref.read(notebookListProvider).valueOrNull ?? const [];
                          final match = list.firstWhere(
                            (e) => e.metadata.id == hit.notebookId,
                            orElse: () => list.isEmpty
                                ? throw StateError('No notebooks')
                                : list.first,
                          );
                          if (match.metadata.id == hit.notebookId) {
                            _openNotebook(match);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _showCrashLog() async {
    final log = await CrashLogger.read();
    final path = CrashLogger.path ?? '(unknown)';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Log crash  —  v${AppConfig.fullVersion}'),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(path, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: SingleChildScrollView(
                  child: SelectableText(
                    log.isEmpty ? '(log vuoto — nessun errore registrato)' : log,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await CrashLogger.clear();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Svuota'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Log copiato negli appunti')),
                );
              }
            },
            child: const Text('Copia'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Chiudi'),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _buildThemeMenuItem(
      String value, IconData icon, String label, ThemeMode mode) {
    final current = ref.read(appSettingsProvider).themeMode;
    final isSel = current == mode;
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(icon, size: 18, color: isSel ? Colors.blue : null),
        const SizedBox(width: 8),
        Expanded(child: Text(label,
            style: TextStyle(color: isSel ? Colors.blue : null,
                fontWeight: isSel ? FontWeight.w600 : null))),
        if (isSel) const Icon(Icons.check, size: 16, color: Colors.blue),
      ]),
    );
  }

  Future<void> _forceResync() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forza sync'),
        content: const Text(
          'Invalida le cache ETag locali di tutti i notebook. Al prossimo '
          'open, ogni notebook viene ri-confrontato con il server e le '
          'pagine mancanti vengono ri-scaricate.\n\n'
          'I dati locali non vengono toccati — solo i metadata di '
          'sincronizzazione vengono reset per forzare un full pull.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Pulisci cache'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final fileService = ref.read(fileServiceProvider);
    final prefs = await SharedPreferences.getInstance();

    final metaKeys = prefs.getKeys()
        .where((k) => k.startsWith('delta_meta_etag_'))
        .toList();
    for (final k in metaKeys) {
      await prefs.remove(k);
    }
    final dbCount = await fileService.invalidateAllEtags();

    await ref.read(notebookListProvider.notifier).refresh();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Cache pulite — ${metaKeys.length} meta ETag, '
          '$dbCount DB row(s). Apri un notebook per re-sincronizzare.',
        ),
      ),
    );
  }

  Future<void> _showTrash() async {
    final notifier = ref.read(notebookListProvider.notifier);
    final List<TrashEntry> entries = await notifier.listTrash();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> refresh() async {
            final fresh = await notifier.listTrash();
            if (ctx.mounted) {
              setSheetState(() => entries
                ..clear()
                ..addAll(fresh));
            }
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.7,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline_rounded, size: 22),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Cestino',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (entries.isNotEmpty)
                          TextButton.icon(
                            icon: const Icon(Icons.delete_sweep_rounded, size: 18, color: Colors.red),
                            label: const Text('Svuota', style: TextStyle(color: Colors.red)),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: ctx,
                                builder: (dialogCtx) => AlertDialog(
                                  title: const Text('Svuota cestino'),
                                  content: const Text('Tutti gli elementi saranno eliminati definitivamente.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Annulla')),
                                    FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                      onPressed: () => Navigator.pop(dialogCtx, true),
                                      child: const Text('Svuota'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await notifier.emptyTrash();
                                await refresh();
                              }
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: entries.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.inbox_rounded, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                Text('Il cestino è vuoto', style: TextStyle(color: Colors.grey.shade600)),
                              ],
                            ),
                          )
                        : ListView.separated(
                            itemCount: entries.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final e = entries[i];
                              return ListTile(
                                leading: Container(
                                  width: 36, height: 36,
                                  decoration: BoxDecoration(
                                    color: Color(e.coverColor),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 18),
                                ),
                                title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text('Eliminato ${_formatDeletedAt(e.deletedAt)}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.restore_rounded, color: Colors.blue),
                                      tooltip: 'Ripristina',
                                      onPressed: () async {
                                        await notifier.restoreFromTrash(e.trashId);
                                        await refresh();
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_forever_rounded, color: Colors.red),
                                      tooltip: 'Elimina definitivamente',
                                      onPressed: () async {
                                        await notifier.purgeTrashEntry(e.trashId);
                                        await refresh();
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatDeletedAt(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'pochi secondi fa';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min fa';
    if (diff.inHours < 24) return '${diff.inHours} h fa';
    if (diff.inDays < 7) return '${diff.inDays} g fa';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  /// Ask the user where to drop the files that just arrived via the OS
  /// share sheet, then hand off to the canvas-open flow with a
  /// [PendingImport] so the canvas inserts them once the notebook is loaded.
  Future<void> _handleSharedImport(SharedImport imported) async {
    // Consume immediately so repeated rebuilds don't re-open the sheet.
    ref.read(shareReceiverProvider.notifier).consume();
    if (!mounted) return;

    final list = ref.read(notebookListProvider).valueOrNull ?? const [];

    final choice = await showModalBottomSheet<_ShareDest>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            expand: false,
            builder: (ctx, scroll) => Column(
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(top: 8, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'Importa ${imported.files.length} ${imported.files.length == 1 ? "file" : "file"}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add_circle_outline, color: Colors.blue),
                        title: const Text('Crea nuovo notebook'),
                        subtitle: const Text('Ogni pagina del PDF diventa una pagina'),
                        onTap: () => Navigator.pop(ctx, const _ShareDest.newNotebook()),
                      ),
                      const Divider(height: 1),
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nessun notebook esistente', style: TextStyle(color: Colors.grey)),
                        )
                      else
                        ...list.map((e) => ListTile(
                              leading: Container(
                                width: 32, height: 40,
                                decoration: BoxDecoration(
                                  color: Color(e.metadata.coverColor),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              title: Text(e.metadata.title),
                              subtitle: Text('${e.metadata.pageCount} pagine'),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'new_chapter',
                                    child: Text('Nuovo capitolo'),
                                  ),
                                  for (final c in e.metadata.chapters)
                                    PopupMenuItem(
                                      value: 'chap:${c.id}',
                                      child: Text('→ ${c.title}'),
                                    ),
                                ],
                                onSelected: (v) {
                                  if (v == 'new_chapter') {
                                    Navigator.pop(ctx, _ShareDest.existing(e, newChapter: true));
                                  } else if (v.startsWith('chap:')) {
                                    Navigator.pop(
                                      ctx,
                                      _ShareDest.existing(e, chapterId: v.substring(5)),
                                    );
                                  }
                                },
                              ),
                              onTap: () => Navigator.pop(ctx, _ShareDest.existing(e)),
                            )),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null || !mounted) return;
    final paths = imported.files.map((f) => f.path).toList();

    if (choice.isNewNotebook) {
      // Derive a friendly title from the first file's basename.
      final first = paths.first.split(RegExp(r'[\\/]+')).last;
      final titleBase = first.replaceAll(RegExp(r'\.[^.]+$'), '');
      try {
        final entry = await ref.read(notebookListProvider.notifier).createNotebook(
              title: titleBase.isEmpty ? 'Importato' : titleBase,
            );
        if (!mounted) return;
        ref.read(pendingImportProvider.notifier).state = PendingImport(filePaths: paths);
        _openNotebook(entry);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Errore creazione notebook: $e')),
          );
        }
      }
      return;
    }

    final target = choice.entry!;
    ref.read(pendingImportProvider.notifier).state = PendingImport(
      filePaths: paths,
      targetChapterId: choice.chapterId,
      newChapterTitle: choice.newChapter
          ? 'Importato ${DateTime.now().toString().substring(0, 16)}'
          : null,
    );
    _openNotebook(target);
  }

  @override
  Widget build(BuildContext context) {
    final notebooks = ref.watch(notebookListProvider);
    final creds = ref.watch(credentialsProvider);
    final connectivity = ref.watch(connectivityServiceProvider);
    final crossClip = ref.watch(crossNotebookClipboardProvider);
    final screenWidth = MediaQuery.of(context).size.width;

    // Watch for files shared into the app from other apps (Android/iOS share
    // sheet). When one arrives, prompt the user for a destination.
    ref.listen<SharedImport?>(shareReceiverProvider, (_, next) {
      if (next == null || next.files.isEmpty) return;
      _handleSharedImport(next);
    });

    int crossAxisCount;
    if (screenWidth > 1200) {
      crossAxisCount = 5;
    } else if (screenWidth > 900) {
      crossAxisCount = 4;
    } else if (screenWidth > 600) {
      crossAxisCount = 3;
    } else {
      crossAxisCount = 2;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).colorScheme.surface
          : const Color(0xFFF8F8F8),
      appBar: AppBar(
        backgroundColor: isDark
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Colors.white,
        surfaceTintColor: isDark
            ? Theme.of(context).colorScheme.surfaceContainerHigh
            : Colors.white,
        foregroundColor: isDark
            ? Theme.of(context).colorScheme.onSurface
            : null,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF1565C0), Color(0xFF0277BD)]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit_note_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            const Text('HandWriter', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
          ],
        ),
        centerTitle: false,
        actions: [
          if (connectivity != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ValueListenableBuilder<bool>(
                valueListenable: connectivity.isOnline,
                builder: (_, online, __) => Tooltip(
                  message: online ? 'Online — sync attiva' : 'Offline — modifiche locali',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: online ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                          size: 14,
                          color: online ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          online ? 'Online' : 'Offline',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: online ? Colors.green.shade700 : Colors.red.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.manage_search_rounded),
            tooltip: 'Cerca nei contenuti',
            onPressed: _showSearch,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.read(notebookListProvider.notifier).refresh(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_rounded, size: 28),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              switch (value) {
                case 'logout':
                  ref.read(credentialsProvider.notifier).logout();
                  break;
                case 'trash':
                  _showTrash();
                  break;
                case 'crashlog':
                  _showCrashLog();
                  break;
                case 'forceresync':
                  _forceResync();
                  break;
                case 'theme_system':
                  ref.read(appSettingsProvider.notifier).setThemeMode(ThemeMode.system);
                  break;
                case 'theme_light':
                  ref.read(appSettingsProvider.notifier).setThemeMode(ThemeMode.light);
                  break;
                case 'theme_dark':
                  ref.read(appSettingsProvider.notifier).setThemeMode(ThemeMode.dark);
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(creds?.username ?? '', style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                    Text(creds?.serverUrl ?? '', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'trash',
                child: Row(children: [
                  Icon(Icons.delete_outline_rounded, size: 18),
                  SizedBox(width: 8),
                  Text('Cestino'),
                ]),
              ),
              const PopupMenuItem(
                value: 'crashlog',
                child: Row(children: [
                  Icon(Icons.bug_report_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Log crash'),
                ]),
              ),
              const PopupMenuItem(
                value: 'forceresync',
                child: Row(children: [
                  Icon(Icons.cloud_sync_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Forza sync'),
                ]),
              ),
              const PopupMenuDivider(),
              // Theme selector (live switch — no restart needed)
              PopupMenuItem(
                enabled: false,
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('Tema',
                      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
                ),
              ),
              _buildThemeMenuItem('theme_system', Icons.brightness_auto_rounded, 'Sistema', ThemeMode.system),
              _buildThemeMenuItem('theme_light', Icons.light_mode_rounded, 'Chiaro', ThemeMode.light),
              _buildThemeMenuItem('theme_dark', Icons.dark_mode_rounded, 'Scuro', ThemeMode.dark),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout_rounded, size: 18),
                  SizedBox(width: 8),
                  Text('Disconnetti'),
                ]),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNotebook,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuovo', style: TextStyle(fontWeight: FontWeight.w600)),
        elevation: 2,
      ),
      body: Column(
        children: [
          if (crossClip != null)
            Material(
              color: Colors.blue.shade700,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.content_paste_rounded, color: Colors.white, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${crossClip.elements.length} element${crossClip.elements.length == 1 ? "o" : "i"} copiati — apri un notebook per incollare',
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 18),
                        onPressed: () => ref.read(crossNotebookClipboardProvider.notifier).state = null,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: notebooks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text('Impossibile caricare i notebook', style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Text('$e', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => ref.read(notebookListProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Riprova'),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            final notifier = ref.read(notebookListProvider.notifier);
            return ValueListenableBuilder<bool>(
              valueListenable: notifier.isSyncing,
              builder: (_, syncing, __) {
                if (syncing) {
                  return Center(
                    child: ValueListenableBuilder<({int done, int total})>(
                      valueListenable: notifier.syncProgress,
                      builder: (_, progress, __) {
                        final label = progress.total == 0
                            ? 'Caricamento notebook dal server…'
                            : 'Download ${progress.done}/${progress.total} notebook…';
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: CircularProgressIndicator(
                                value: progress.total == 0
                                    ? null
                                    : progress.done / progress.total,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              label,
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                }
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.note_add_rounded, size: 48, color: Colors.blue.shade300),
                      ),
                      const SizedBox(height: 20),
                      Text('Nessun notebook', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
                      const SizedBox(height: 8),
                      Text('Crea il tuo primo notebook premendo il bottone +', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                );
              },
            );
          }

          // Aggregate all known tags so the filter bar stays visible even when
          // current search hides most notebooks.
          final allTags = <String>{};
          for (final e in list) {
            allTags.addAll(e.metadata.tags);
          }
          // Drop stale selections (tag removed from all notebooks).
          _selectedTags.removeWhere((t) => !allTags.contains(t));

          // Filter by search query (case-insensitive, matches title + chapter titles)
          // AND by selected tags (AND across selected tags).
          final query = _searchQuery.trim().toLowerCase();
          final settings = ref.watch(appSettingsProvider);
          final filtered = list.where((e) {
            if (_selectedTags.isNotEmpty &&
                !_selectedTags.every(e.metadata.tags.contains)) {
              return false;
            }
            if (query.isEmpty) return true;
            if (e.metadata.title.toLowerCase().contains(query)) return true;
            if (e.metadata.tags.any((t) => t.toLowerCase().contains(query))) return true;
            return e.metadata.chapters.any((c) => c.title.toLowerCase().contains(query));
          }).toList();

          // Apply sort. Favorites-first puts starred notebooks at the top of
          // each sort group without breaking within-group ordering.
          int cmp(NotebookEntry a, NotebookEntry b) {
            switch (settings.sortMode) {
              case LibrarySortMode.modifiedDesc:
                return b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt);
              case LibrarySortMode.modifiedAsc:
                return a.metadata.modifiedAt.compareTo(b.metadata.modifiedAt);
              case LibrarySortMode.titleAsc:
                return a.metadata.title.toLowerCase()
                    .compareTo(b.metadata.title.toLowerCase());
              case LibrarySortMode.titleDesc:
                return b.metadata.title.toLowerCase()
                    .compareTo(a.metadata.title.toLowerCase());
              case LibrarySortMode.createdDesc:
                return b.metadata.createdAt.compareTo(a.metadata.createdAt);
              case LibrarySortMode.createdAsc:
                return a.metadata.createdAt.compareTo(b.metadata.createdAt);
              case LibrarySortMode.colorGroup:
                final c = a.metadata.coverColor.compareTo(b.metadata.coverColor);
                if (c != 0) return c;
                return b.metadata.modifiedAt.compareTo(a.metadata.modifiedAt);
            }
          }
          filtered.sort((a, b) {
            if (settings.favoritesFirst) {
              final aFav = settings.favoriteNotebookIds.contains(a.metadata.id);
              final bFav = settings.favoriteNotebookIds.contains(b.metadata.id);
              if (aFav != bFav) return aFav ? -1 : 1;
            }
            return cmp(a, b);
          });

          // Recent files section: top 5 most recently opened (from settings,
          // not from modified-at — 'opened' is more relevant to quick access).
          final recent = <NotebookEntry>[];
          if (settings.lastOpenedAt.isNotEmpty) {
            final sortedIds = settings.lastOpenedAt.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value));
            for (final e in sortedIds) {
              if (recent.length >= 5) break;
              final match = list.where((n) => n.metadata.id == e.key);
              if (match.isNotEmpty) recent.add(match.first);
            }
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(notebookListProvider.notifier).refresh(),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    decoration: InputDecoration(
                      hintText: 'Cerca notebook...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      filled: true,
                      fillColor: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.surfaceContainerHigh
                          : Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                  ),
                ),
                if (allTags.isNotEmpty)
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      children: [
                        for (final tag in (allTags.toList()..sort())) ...[
                          FilterChip(
                            label: Text('#$tag', style: const TextStyle(fontSize: 12)),
                            selected: _selectedTags.contains(tag),
                            onSelected: (on) => setState(() {
                              if (on) {
                                _selectedTags.add(tag);
                              } else {
                                _selectedTags.remove(tag);
                              }
                            }),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (_selectedTags.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => setState(() => _selectedTags.clear()),
                            icon: const Icon(Icons.close, size: 14),
                            label: const Text('Pulisci', style: TextStyle(fontSize: 12)),
                          ),
                      ],
                    ),
                  ),
                // Sort + recent header.
                if (filtered.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
                    child: Row(
                      children: [
                        if (recent.isNotEmpty && _searchQuery.isEmpty && _selectedTags.isEmpty) ...[
                          Icon(Icons.history_rounded, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Text('${recent.length} recenti',
                              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ],
                        const Spacer(),
                        _SortButton(
                          mode: settings.sortMode,
                          favoritesFirst: settings.favoritesFirst,
                          onModeChanged: (m) => ref
                              .read(appSettingsProvider.notifier)
                              .setSortMode(m),
                          onFavoritesFirstChanged: (v) => ref
                              .read(appSettingsProvider.notifier)
                              .setFavoritesFirst(v),
                        ),
                      ],
                    ),
                  ),
                // Recent strip (only on unfiltered view).
                if (recent.isNotEmpty && _searchQuery.isEmpty && _selectedTags.isEmpty)
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: recent.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => _RecentChip(
                        entry: recent[i],
                        onTap: () => _openNotebook(recent[i]),
                      ),
                    ),
                  ),
                if (filtered.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.search_off_rounded, size: 48, color: Theme.of(context).colorScheme.outline),
                          const SizedBox(height: 12),
                          Text('Nessun risultato per "$_searchQuery"',
                              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 0.72,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, index) => _NotebookCard(
                          entry: filtered[index],
                          onTap: () => _openNotebook(filtered[index]),
                          onLongPress: () => _showNotebookMenu(filtered[index]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  WIDGETS
// ═══════════════════════════════════════════════════════════════

class _NotebookCard extends ConsumerStatefulWidget {
  final NotebookEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _NotebookCard({required this.entry, required this.onTap, required this.onLongPress});

  @override
  ConsumerState<_NotebookCard> createState() => _NotebookCardState();
}

class _NotebookCardState extends ConsumerState<_NotebookCard> {
  bool _lazyRenderTriggered = false;
  // Cache the thumbnail-existence check so we don't stat the disk on every
  // rebuild (previously a FutureBuilder<bool>(thumbFile.exists()) fired a
  // fresh I/O on every rebuild per card — scrolling a 50-card library was
  // spamming ~50 stat calls per frame before).
  //   null  = not checked yet (show gradient, async-probe once)
  //   true  = file exists (render Image.file)
  //   false = file absent (show gradient; if this is the first "absent"
  //           result, trigger a one-shot lazy render)
  bool? _thumbExists;
  String? _checkedForPath;

  Future<void> _checkThumbExistence(String path) async {
    try {
      final exists = await File(path).exists();
      if (!mounted) return;
      if (_thumbExists != exists) {
        setState(() => _thumbExists = exists);
      }
    } catch (_) {
      // Swallow — card gracefully falls back to gradient cover.
    }
  }

  Future<void> _maybeLazyRenderThumb() async {
    if (_lazyRenderTriggered) return;
    _lazyRenderTriggered = true;
    try {
      final thumbs = ref.read(thumbnailServiceProvider);
      final fileService = ref.read(fileServiceProvider);
      final bytes = await fileService.readNotebookFile(widget.entry.metadata.id);
      if (bytes == null || !mounted) return;
      final path = await thumbs.ensureFromNcnoteBytes(
        widget.entry.metadata.id,
        bytes,
      );
      if (path != null && mounted) {
        setState(() => _thumbExists = true);
      }
    } catch (_) {
      // Swallow — card gracefully falls back to gradient cover.
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final onTap = widget.onTap;
    final onLongPress = widget.onLongPress;
    final meta = entry.metadata;
    final coverColor = Color(meta.coverColor);
    final paperLabel = _paperLabel(meta.paperType);
    final thumbs = ref.watch(thumbnailServiceProvider);
    final thumbPath = thumbs.thumbnailPath(meta.id);
    final isFav = ref.watch(appSettingsProvider)
        .favoriteNotebookIds
        .contains(meta.id);
    final thumbFile = File(thumbPath);

    // Kick off the existence probe exactly once per thumbPath. If the
    // path changes (rename / id change) re-probe. This replaces the old
    // FutureBuilder which re-issued a File.exists() on every rebuild.
    if (_checkedForPath != thumbPath) {
      _checkedForPath = thumbPath;
      _thumbExists = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _checkThumbExistence(thumbPath);
      });
    }

    final hasThumb = _thumbExists == true;
    // Trigger lazy-render once the probe tells us the thumb is missing.
    if (_thumbExists == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeLazyRenderThumb();
      });
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapUp: (details) {
        onLongPress();
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 4)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cover
              Expanded(
                flex: 3,
                child: Builder(
                  builder: (ctx) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        // Always paint gradient first — acts as placeholder
                        // while the thumb loads and as a fallback when missing.
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [coverColor, coverColor.withValues(alpha: 0.8)],
                            ),
                          ),
                        ),
                        if (hasThumb)
                          Positioned.fill(
                            child: Image.file(
                              thumbFile,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                            ),
                          ),
                        if (hasThumb)
                          // Dark scrim for legibility of title text on top.
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.35),
                                    Colors.black.withValues(alpha: 0.05),
                                    Colors.black.withValues(alpha: 0.45),
                                  ],
                                  stops: const [0, 0.55, 1],
                                ),
                              ),
                            ),
                          ),
                        // Favorite star overlay (top-right). Tapping toggles
                        // the star without opening the notebook.
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => ref
                                  .read(appSettingsProvider.notifier)
                                  .toggleFavorite(meta.id),
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.all(4),
                                child: Icon(
                                  isFav ? Icons.star_rounded : Icons.star_outline_rounded,
                                  color: isFav ? Colors.amber : Colors.white.withValues(alpha: 0.7),
                                  size: 22,
                                  shadows: [
                                    Shadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (!hasThumb) ...[
                          Positioned(
                            left: 16,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1.5, color: Colors.white.withValues(alpha: 0.15)),
                          ),
                          Positioned(
                            left: 20,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 0.5, color: Colors.white.withValues(alpha: 0.1)),
                          ),
                        ],
                        // Title on cover
                        Padding(
                          padding: const EdgeInsets.fromLTRB(32, 16, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                meta.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                  shadows: [
                                    Shadow(color: Color(0x66000000), blurRadius: 4),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              if (meta.tags.isNotEmpty) ...[
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: meta.tags.take(3).map((t) => Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.25),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('#$t',
                                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500)),
                                  )).toList(),
                                ),
                                const SizedBox(height: 6),
                              ],
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        meta.chapters.isNotEmpty
                                            ? '${meta.pageCount} pag. \u2022 ${meta.chapters.map((c) => c.title).join(', ')}'
                                            : '${meta.pageCount} pag.',
                                        style: const TextStyle(color: Colors.white, fontSize: 11),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: onLongPress,
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.more_vert, color: Colors.white, size: 18),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              // Info bar
              Container(
                color: Theme.of(context).colorScheme.surface,
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.grid_on, size: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Text(paperLabel, style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const Spacer(),
                        Text(
                          _formatDate(meta.modifiedAt),
                          style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline),
                        ),
                      ],
                    ),
                    if (meta.chapters.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        meta.chapters.map((c) => c.title).join(' \u2022 '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.outline, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _paperLabel(String type) {
    switch (type) {
      case 'lined_narrow': return 'Righe strette';
      case 'lined_wide': case 'lined': return 'Righe larghe';
      case 'grid': return 'Quadretti';
      case 'dotted': return 'Puntinato';
      default: return 'Bianco';
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Adesso';
    if (diff.inHours < 1) return '${diff.inMinutes} min fa';
    if (diff.inDays < 1) return '${diff.inHours}h fa';
    if (diff.inDays < 7) return '${diff.inDays}g fa';
    return '${date.day}/${date.month}/${date.year}';
  }
}

class _PaperChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final String value;
  final String selected;
  final ValueChanged<String> onTap;

  const _PaperChip({
    required this.label,
    required this.icon,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = value == selected;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isSelected ? Colors.blue.shade50 : Colors.grey.shade100,
          border: Border.all(color: isSelected ? Colors.blue.shade300 : Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isSelected ? Colors.blue.shade600 : Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? Colors.blue.shade700 : Colors.grey.shade700,
            )),
          ],
        ),
      ),
    );
  }
}

/// Destination chosen by the user in the "import shared files" bottom sheet.
class _ShareDest {
  final bool isNewNotebook;
  final NotebookEntry? entry;
  final String? chapterId;
  final bool newChapter;

  const _ShareDest.newNotebook()
      : isNewNotebook = true,
        entry = null,
        chapterId = null,
        newChapter = false;

  const _ShareDest.existing(NotebookEntry this.entry, {this.chapterId, this.newChapter = false})
      : isNewNotebook = false;
}

// ═══════════════════════════════════════════════════════════════
//  SORT / RECENT UI
// ═══════════════════════════════════════════════════════════════

class _SortButton extends StatelessWidget {
  final LibrarySortMode mode;
  final bool favoritesFirst;
  final ValueChanged<LibrarySortMode> onModeChanged;
  final ValueChanged<bool> onFavoritesFirstChanged;

  const _SortButton({
    required this.mode,
    required this.favoritesFirst,
    required this.onModeChanged,
    required this.onFavoritesFirstChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: 'Ordina',
      icon: Icon(mode.icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('Ordina per',
                style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ),
        ),
        ...LibrarySortMode.values.map((m) => PopupMenuItem<Object>(
              value: m,
              child: Row(
                children: [
                  Icon(m.icon, size: 18,
                      color: m == mode ? Colors.blue : Colors.grey.shade600),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(m.label,
                        style: TextStyle(
                          color: m == mode ? Colors.blue : null,
                          fontWeight: m == mode ? FontWeight.w600 : null,
                        )),
                  ),
                  if (m == mode) const Icon(Icons.check, size: 16, color: Colors.blue),
                ],
              ),
            )),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          value: 'toggle_fav_first',
          child: Row(
            children: [
              Icon(
                favoritesFirst ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 20,
                color: favoritesFirst ? Colors.blue : Colors.grey.shade600,
              ),
              const SizedBox(width: 8),
              const Expanded(child: Text('Preferiti in cima')),
            ],
          ),
        ),
      ],
      onSelected: (v) {
        if (v is LibrarySortMode) {
          onModeChanged(v);
        } else if (v == 'toggle_fav_first') {
          onFavoritesFirstChanged(!favoritesFirst);
        }
      },
    );
  }
}

class _RecentChip extends ConsumerWidget {
  final NotebookEntry entry;
  final VoidCallback onTap;

  const _RecentChip({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Color(entry.metadata.coverColor);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.7), color.withValues(alpha: 0.95)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.book_rounded, size: 14, color: Colors.white.withValues(alpha: 0.9)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.metadata.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
            Text(
              '${entry.metadata.pageCount} pagine',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
