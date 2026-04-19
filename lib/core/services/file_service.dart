import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:handwriter/config/app_config.dart';

/// Manages local notebook files and the sync-metadata database.
///
/// Directory layout (inside getApplicationDocumentsDirectory()):
///   HandWriter/
///     notebooks/
///       <notebookId>.ncnote        ← full ZIP archive
///     snapshots/
///       <notebookId>/
///         <timestamp>.ncnote       ← rolling local backups (last 3)
///     trash/
///       <trashId>.ncnote           ← soft-deleted notebooks
///       <trashId>.meta.json        ← metadata sidecar for restore
///     handwriter.db                ← sync metadata
class FileService {
  /// Max rolling backups to keep per notebook.
  static const int _maxSnapshots = 3;

  late final String _basePath;
  late final String _notebooksDir;
  late final String _snapshotsDir;
  late final String _trashDir;
  late final Database _db;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  /// Per-notebook save serialisation. Two concurrent writers (e.g. save()
  /// and _savePulledChangesLocally()) must not race on the same .ncnote
  /// path or the later rename can truncate the earlier ZIP mid-flush.
  final Map<String, Future<void>> _saveLocks = {};

  /// Counter used to guarantee a unique tmp filename per-invocation so two
  /// concurrent writers on the same notebook never stomp each other's tmp
  /// file (each then rename-atomically into the real path, serialised via
  /// [_saveLocks]).
  int _tmpCounter = 0;

  // ── Initialization ──

  Future<void> init() async {
    if (_initialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _basePath = p.join(appDir.path, 'HandWriter');
    _notebooksDir = p.join(_basePath, 'notebooks');
    _snapshotsDir = p.join(_basePath, 'snapshots');
    _trashDir = p.join(_basePath, 'trash');

    await Directory(_notebooksDir).create(recursive: true);
    await Directory(_snapshotsDir).create(recursive: true);
    await Directory(_trashDir).create(recursive: true);

    _db = await openDatabase(
      p.join(_basePath, AppConfig.dbName),
      version: AppConfig.dbVersion,
      onCreate: _createTables,
      onUpgrade: _upgradeTables,
    );

    _initialized = true;
    debugPrint('[FileService] Initialized at $_basePath');
  }

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notebooks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        etag TEXT,
        local_modified_at TEXT NOT NULL,
        remote_modified_at TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        file_size INTEGER,
        cover_color INTEGER,
        paper_type TEXT,
        page_count INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE dirty_pages (
        notebook_id TEXT NOT NULL,
        page_id TEXT NOT NULL,
        modified_at TEXT NOT NULL,
        PRIMARY KEY (notebook_id, page_id),
        FOREIGN KEY (notebook_id) REFERENCES notebooks(id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _upgradeTables(Database db, int oldVersion, int newVersion) async {
    // Future schema migrations go here
  }

  // ── Local File I/O ──

  /// Returns the local filesystem path for a notebook.
  String localPath(String notebookId) =>
      p.join(_notebooksDir, '$notebookId${AppConfig.fileExtension}');

  /// Saves a raw .ncnote archive to local storage.
  ///
  /// Before overwriting the existing file, snapshots the previous version
  /// to `snapshots/<id>/<timestamp>.ncnote` keeping only the latest [_maxSnapshots].
  Future<void> saveNotebookFile(String notebookId, Uint8List data) async {
    // Serialise concurrent writes to the same notebook so the later rename
    // never overwrites an in-flight tmp file and so the two producers don't
    // each leave a truncated .ncnote behind (the "save() vs _savePulledChanges
    // Locally() race" path).
    final prev = _saveLocks[notebookId];
    final completer = Completer<void>();
    _saveLocks[notebookId] = completer.future;
    try {
      if (prev != null) {
        try { await prev; } catch (_) {}
      }
      await _writeNotebookAtomic(notebookId, data);
    } finally {
      completer.complete();
      if (identical(_saveLocks[notebookId], completer.future)) {
        _saveLocks.remove(notebookId);
      }
    }
  }

  Future<void> _writeNotebookAtomic(String notebookId, Uint8List data) async {
    final path = localPath(notebookId);

    // Roll a snapshot of the previous version (best-effort, never blocks save).
    try {
      final existing = File(path);
      if (await existing.exists()) {
        await _rotateSnapshot(notebookId, existing);
      }
    } catch (e) {
      debugPrint('[FileService] Snapshot rotation failed for $notebookId: $e');
    }

    // Unique tmp path per call — belt-and-braces alongside _saveLocks so a
    // crash mid-save never leaves a stale "$path.tmp" that a subsequent save
    // would silently overwrite.
    final ts = DateTime.now().microsecondsSinceEpoch;
    final seq = (++_tmpCounter).toRadixString(36);
    final rand = math.Random().nextInt(1 << 31).toRadixString(36);
    final tmpPath = '$path.$ts-$seq-$rand.tmp';
    final tmpFile = File(tmpPath);
    try {
      await tmpFile.writeAsBytes(data, flush: true);
      await tmpFile.rename(path);
      debugPrint('[FileService] Saved $notebookId (${data.length} bytes)');
    } catch (e) {
      // Clean the tmp file on any failure so we don't leak scratch files.
      try { if (await tmpFile.exists()) await tmpFile.delete(); } catch (_) {}
      rethrow;
    }
  }

  /// Copies the current .ncnote into the snapshot folder and prunes older ones.
  Future<void> _rotateSnapshot(String notebookId, File source) async {
    final dir = Directory(p.join(_snapshotsDir, notebookId));
    await dir.create(recursive: true);

    // Microsecond + counter stamp so two rotations landing on the same
    // millisecond don't collide (older snapshot would otherwise be
    // silently overwritten on the second `copy`).
    final micro = DateTime.now().microsecondsSinceEpoch;
    final seq = (++_tmpCounter).toRadixString(36);
    final stamp = '${micro}_$seq';
    final dest = File(p.join(dir.path, '$stamp${AppConfig.fileExtension}'));
    await source.copy(dest.path);

    // Prune old snapshots (keep newest _maxSnapshots).
    final snapshots = await dir
        .list()
        .where((e) => e is File && e.path.endsWith(AppConfig.fileExtension))
        .toList();
    snapshots.sort((a, b) => b.path.compareTo(a.path)); // timestamps sort lexically
    for (var i = _maxSnapshots; i < snapshots.length; i++) {
      try { await snapshots[i].delete(); } catch (_) {}
    }
  }

  /// Lists available snapshots for a notebook, newest first.
  /// Each entry is (timestamp, absolute path).
  Future<List<(DateTime, String)>> listSnapshots(String notebookId) async {
    final dir = Directory(p.join(_snapshotsDir, notebookId));
    if (!await dir.exists()) return const [];
    final out = <(DateTime, String)>[];
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith(AppConfig.fileExtension)) continue;
      final name = p.basenameWithoutExtension(entry.path);
      // Accept both legacy "1700000000000" (ms) and new "1700000000000000_3q"
      // (µs + counter) naming so existing snapshots remain listable.
      final stampPart = name.split('_').first;
      final stampInt = int.tryParse(stampPart);
      if (stampInt == null) continue;
      final ms = stampInt > 100000000000000 // µs if beyond year ~5138 in ms
          ? stampInt ~/ 1000
          : stampInt;
      out.add((DateTime.fromMillisecondsSinceEpoch(ms), entry.path));
    }
    out.sort((a, b) => b.$1.compareTo(a.$1));
    return out;
  }

  /// Restores a snapshot as the current notebook file.
  Future<void> restoreSnapshot(String notebookId, String snapshotPath) async {
    final src = File(snapshotPath);
    if (!await src.exists()) throw StateError('Snapshot not found: $snapshotPath');
    final data = await src.readAsBytes();
    await saveNotebookFile(notebookId, data); // will also snapshot the current version
  }

  /// Reads a raw .ncnote archive from local storage.
  /// Returns null if file doesn't exist.
  Future<Uint8List?> readNotebookFile(String notebookId) async {
    final file = File(localPath(notebookId));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Checks whether a notebook is cached locally.
  Future<bool> hasLocalCopy(String notebookId) async {
    return File(localPath(notebookId)).exists();
  }

  /// Deletes a local notebook file.
  Future<void> deleteNotebookFile(String notebookId) async {
    final file = File(localPath(notebookId));
    if (await file.exists()) {
      await file.delete();
    }
  }

  // ── Sync Metadata DB ──

  /// Upserts notebook metadata in the local DB.
  Future<void> upsertNotebookMeta({
    required String id,
    required String title,
    required String remotePath,
    String? etag,
    required DateTime localModifiedAt,
    DateTime? remoteModifiedAt,
    String syncStatus = 'synced',
    int? fileSize,
    int? coverColor,
    String? paperType,
    int pageCount = 0,
    DateTime? createdAt,
  }) async {
    await _db.insert(
      'notebooks',
      {
        'id': id,
        'title': title,
        'remote_path': remotePath,
        'etag': etag,
        'local_modified_at': localModifiedAt.toIso8601String(),
        'remote_modified_at': remoteModifiedAt?.toIso8601String(),
        'sync_status': syncStatus,
        'file_size': fileSize,
        'cover_color': coverColor,
        'paper_type': paperType,
        'page_count': pageCount,
        'created_at': (createdAt ?? localModifiedAt).toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns all locally-tracked notebook metadata rows.
  Future<List<Map<String, dynamic>>> getAllNotebookMeta() async {
    return _db.query('notebooks', orderBy: 'local_modified_at DESC');
  }

  /// Returns metadata for a single notebook, or null.
  Future<Map<String, dynamic>?> getNotebookMeta(String id) async {
    final rows = await _db.query('notebooks', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Marks a notebook as dirty (needs sync).
  Future<void> markNotebookDirty(String notebookId) async {
    await _db.update(
      'notebooks',
      {'sync_status': 'modified', 'local_modified_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [notebookId],
    );
  }

  /// Marks a notebook as synced with a new etag.
  Future<void> markNotebookSynced(String notebookId, String? etag) async {
    await _db.update(
      'notebooks',
      {
        'sync_status': 'synced',
        'etag': etag,
        'remote_modified_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [notebookId],
    );
  }

  /// Returns all notebook IDs that need syncing.
  Future<List<Map<String, dynamic>>> getDirtyNotebooks() async {
    return _db.query(
      'notebooks',
      where: 'sync_status != ?',
      whereArgs: ['synced'],
    );
  }

  /// Tracks a dirty page for a notebook.
  Future<void> addDirtyPage(String notebookId, String pageId) async {
    await _db.insert(
      'dirty_pages',
      {
        'notebook_id': notebookId,
        'page_id': pageId,
        'modified_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Clears all dirty pages for a notebook (after successful sync).
  Future<void> clearDirtyPages(String notebookId) async {
    await _db.delete(
      'dirty_pages',
      where: 'notebook_id = ?',
      whereArgs: [notebookId],
    );
  }

  /// Deletes a notebook from the DB and local file.
  Future<void> deleteNotebook(String notebookId) async {
    await _db.delete('notebooks', where: 'id = ?', whereArgs: [notebookId]);
    await _db.delete('dirty_pages', where: 'notebook_id = ?', whereArgs: [notebookId]);
    await deleteNotebookFile(notebookId);
    // Also clean up any rolling snapshots for this notebook.
    try {
      final dir = Directory(p.join(_snapshotsDir, notebookId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ── Trash (soft-delete with restore) ──

  /// Moves a notebook into the trash, preserving its metadata row for restore.
  ///
  /// Returns the opaque trash id that can be passed to [restoreFromTrash].
  /// Does NOT delete remote files — caller is responsible for deciding what
  /// to sync.
  Future<String?> moveNotebookToTrash(String notebookId) async {
    final src = File(localPath(notebookId));
    if (!await src.exists()) {
      // Nothing to preserve; still purge DB below.
      await _db.delete('notebooks', where: 'id = ?', whereArgs: [notebookId]);
      await _db.delete('dirty_pages', where: 'notebook_id = ?', whereArgs: [notebookId]);
      return null;
    }

    final meta = await getNotebookMeta(notebookId);
    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final trashId = '${notebookId}_$stamp';
    final destFile = File(p.join(_trashDir, '$trashId${AppConfig.fileExtension}'));
    final metaFile = File(p.join(_trashDir, '$trashId.meta.json'));

    await src.copy(destFile.path);
    await metaFile.writeAsString(jsonEncode({
      'originalId': notebookId,
      'deletedAt': DateTime.now().toIso8601String(),
      'meta': meta,
    }));
    await src.delete();

    // Purge DB so library stops showing it.
    await _db.delete('notebooks', where: 'id = ?', whereArgs: [notebookId]);
    await _db.delete('dirty_pages', where: 'notebook_id = ?', whereArgs: [notebookId]);
    return trashId;
  }

  /// Lists items currently in the trash, newest first.
  Future<List<TrashEntry>> listTrash() async {
    final dir = Directory(_trashDir);
    if (!await dir.exists()) return const [];
    final out = <TrashEntry>[];
    await for (final entry in dir.list()) {
      if (entry is! File || !entry.path.endsWith('.meta.json')) continue;
      try {
        final json = jsonDecode(await entry.readAsString()) as Map<String, dynamic>;
        final trashId = p.basenameWithoutExtension(entry.path).replaceAll('.meta', '');
        final data = File(p.join(_trashDir, '$trashId${AppConfig.fileExtension}'));
        if (!await data.exists()) continue;
        out.add(TrashEntry(
          trashId: trashId,
          originalId: json['originalId'] as String? ?? trashId,
          deletedAt: DateTime.tryParse(json['deletedAt'] as String? ?? '') ?? DateTime.now(),
          meta: (json['meta'] as Map?)?.cast<String, dynamic>(),
        ));
      } catch (_) {}
    }
    out.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return out;
  }

  /// Restores a trashed notebook. Returns the restored metadata row, or null
  /// if the trash entry is missing.
  Future<Map<String, dynamic>?> restoreFromTrash(String trashId) async {
    final dataFile = File(p.join(_trashDir, '$trashId${AppConfig.fileExtension}'));
    final metaFile = File(p.join(_trashDir, '$trashId.meta.json'));
    if (!await dataFile.exists() || !await metaFile.exists()) return null;

    final json = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    final originalId = json['originalId'] as String;
    final meta = (json['meta'] as Map?)?.cast<String, dynamic>();

    // Restore the .ncnote file.
    final bytes = await dataFile.readAsBytes();
    await File(localPath(originalId)).writeAsBytes(bytes, flush: true);

    // Restore DB row with a `modified` sync status so it re-syncs to remote.
    if (meta != null) {
      await upsertNotebookMeta(
        id: meta['id'] as String,
        title: meta['title'] as String? ?? 'Restored',
        remotePath: meta['remote_path'] as String? ?? '',
        etag: meta['etag'] as String?,
        localModifiedAt: DateTime.tryParse(meta['local_modified_at'] as String? ?? '') ?? DateTime.now(),
        remoteModifiedAt: meta['remote_modified_at'] != null
            ? DateTime.tryParse(meta['remote_modified_at'] as String)
            : null,
        syncStatus: 'modified', // needs re-upload; remote copy was deleted
        fileSize: meta['file_size'] as int?,
        coverColor: meta['cover_color'] as int?,
        paperType: meta['paper_type'] as String?,
        pageCount: meta['page_count'] as int? ?? 0,
        createdAt: DateTime.tryParse(meta['created_at'] as String? ?? '') ?? DateTime.now(),
      );
    }

    await dataFile.delete();
    await metaFile.delete();
    return meta;
  }

  /// Permanently deletes a single trash entry.
  Future<void> purgeTrashEntry(String trashId) async {
    final dataFile = File(p.join(_trashDir, '$trashId${AppConfig.fileExtension}'));
    final metaFile = File(p.join(_trashDir, '$trashId.meta.json'));
    if (await dataFile.exists()) await dataFile.delete();
    if (await metaFile.exists()) await metaFile.delete();
  }

  /// Permanently deletes all trash entries.
  Future<void> emptyTrash() async {
    final dir = Directory(_trashDir);
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      try { await entry.delete(recursive: true); } catch (_) {}
    }
  }

  /// Closes the database. Call on app shutdown.
  Future<void> dispose() async {
    await _db.close();
  }
}

/// Represents one item currently in the trash.
class TrashEntry {
  final String trashId;
  final String originalId;
  final DateTime deletedAt;
  final Map<String, dynamic>? meta;

  const TrashEntry({
    required this.trashId,
    required this.originalId,
    required this.deletedAt,
    required this.meta,
  });

  String get title => meta?['title'] as String? ?? 'Senza titolo';
  int get coverColor => meta?['cover_color'] as int? ?? 0xFF1565C0;
}
