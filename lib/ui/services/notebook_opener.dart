import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_provider.dart';
import 'package:handwriter/core/providers/notebook_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/sync_service.dart';
import 'package:handwriter/features/canvas/presentation/canvas_screen.dart';

/// Opens a notebook: loads it (local first, server fallback), populates
/// canvasProvider, then pushes the editor screen. Mirrors the legacy
/// flow so the new UI inherits all the corruption-recovery logic.
Future<void> openNotebookAndNavigate(
  BuildContext context,
  WidgetRef ref,
  NotebookEntry entry,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Apertura taccuino…'),
          ]),
        ),
      ),
    ),
  );

  try {
    final syncService = ref.read(syncServiceProvider);
    final fileService = ref.read(fileServiceProvider);

    Uint8List? localData = await fileService.readNotebookFile(entry.metadata.id);

    if (localData != null && syncService != null) {
      SyncService.validateNcnoteArchive(localData,
          context: 'open ${entry.metadata.title}');
      final parsed = syncService.parseNcnoteMetadata(localData);
      const kLazyThresholdBytes = 512 * 1024;
      const kLazyThresholdPages = 15;
      final isLarge = localData.lengthInBytes > kLazyThresholdBytes ||
          parsed.document.pages.length > kLazyThresholdPages;

      final pages = isLarge
          ? await syncService.extractAllPagesIsolated(localData)
          : syncService.extractAllPages(localData);
      final assets = isLarge
          ? await syncService.extractAllAssetsIsolated(localData)
          : syncService.extractAllAssets(localData);
      final symbols = syncService.extractSymbolLibraries(localData);

      final corrupted = pages.isEmpty && parsed.document.pages.isNotEmpty;
      if (!corrupted) {
        await ref.read(canvasProvider.notifier).openNotebook(
              metadata: parsed.metadata,
              document: parsed.document,
              pages: pages,
              remotePath: entry.remotePath,
              assets: assets,
              symbolLibraries: symbols.isNotEmpty
                  ? symbols.map((j) => SymbolLibrary.fromJson(j)).toList()
                  : null,
            );

        if (!context.mounted) return;
        Navigator.of(context).pop(); // dismiss the loader
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const CanvasScreen(),
        ));
        return;
      }
    }

    if (syncService == null) {
      throw Exception('Non connesso e nessuna copia locale');
    }

    final result =
        await syncService.downloadExplodedFull(entry.metadata.id);

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
      debugPrint('[NotebookOpener] persist after download failed: $e');
    }

    await ref.read(canvasProvider.notifier).openNotebook(
          metadata: result.metadata,
          document: result.document,
          pages: result.pages,
          remotePath: entry.remotePath,
          assets: result.assets,
          symbolLibraries: result.symbolLibraries.isNotEmpty
              ? result.symbolLibraries
                  .map((j) => SymbolLibrary.fromJson(j))
                  .toList()
              : null,
        );

    if (!context.mounted) return;
    Navigator.of(context).pop();
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const CanvasScreen(),
    ));
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Impossibile aprire: $e')),
    );
  }
}
