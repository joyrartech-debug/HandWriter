import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
///       <notebookId>.ncnote   ← full ZIP archive
///     handwriter.db           ← sync metadata
class FileService {
  late final String _basePath;
  late final String _notebooksDir;
  late final Database _db;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // ── Initialization ──

  Future<void> init() async {
    if (_initialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _basePath = p.join(appDir.path, 'HandWriter');
    _notebooksDir = p.join(_basePath, 'notebooks');

    await Directory(_notebooksDir).create(recursive: true);

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
  Future<void> saveNotebookFile(String notebookId, Uint8List data) async {
    final path = localPath(notebookId);
    final tmpPath = '$path.tmp';
    // Atomic write: write to temp file, then rename
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(data, flush: true);
    await tmpFile.rename(path);
    debugPrint('[FileService] Saved $notebookId (${data.length} bytes)');
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
  }

  /// Closes the database. Call on app shutdown.
  Future<void> dispose() async {
    await _db.close();
  }
}
