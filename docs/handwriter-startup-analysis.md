# HandWriter Startup Flow Analysis

## Critical Path (Main Thread Blocking)

### Before runApp() - BLOCKING OPERATIONS

1. **FileService.init()** (awaited in [main.dart](lib/main.dart#L19))
   - Gets application documents directory
   - Creates `HandWriter/notebooks/` directories 
   - Opens SQLite database (handwriter.db) via sqflite
   - On first run: creates `notebooks` and `dirty_pages` tables
   - **Impact**: Initial DB open + directory creation, typically <500ms on local storage

### After runApp() - NON-BLOCKING BUT UI DELAYS

2. **ProviderScope initialization** 
   - credentialsProvider constructor calls _loadSaved() asynchronously
   - Loads credentials from SharedPreferences (async I/O)
   - Does NOT block initial render, but results trigger _AuthGate rebuild

3. **_AuthGate watches credentialsProvider**
   - Shows LoginScreen if no credentials
   - Shows LibraryScreen if credentials exist
   - Credentials available ~100-300ms after app start

4. **LibraryScreen.initState()** (in [library_screen.dart](lib/features/library/library_screen.dart#L20))
   - Via Future.microtask: calls `notebookListProvider.notifier.refresh()`
   - Calls _startConnectivityMonitor()
   - **HEAVY OPERATION STARTS HERE**

## MAJOR BOTTLENECK: notebookListProvider.refresh()

Located: [notebook_provider.dart](lib/core/providers/notebook_provider.dart#L64)

### Steps:

1. **WebDAV PROPFIND** → list all .ncnote files on server (1-5s typically)
   
2. **For EACH notebook file (sequential loop)**:
   - Call `syncService.downloadNotebook(remotePath)` which:
     a. `webdav.downloadFile(remotePath)` - downloads full ZIP archive (NETWORK I/O)
     b. `validateNcnoteArchive(data)` - validates ZIP structure
     c. `_parseNcnoteArchive(data)` which:
        - `ZipDecoder().decodeBytes(data)` - decompresses entire ZIP in memory
        - Extract metadata.json → JSON parse
        - Extract document.json → JSON parse  
        - For **large notebooks**: decompression can be 100s-1000s ms
     d. Call `webdav.downloadFile()` AGAIN to cache full file locally
     e. `fileService.saveNotebookFile()` - writes to disk
     f. `fileService.upsertNotebookMeta()` - SQLite insert
   
   - **Time per notebook: 1-10s depending on file size**

3. **Load local-only dirty notebooks** (async)

4. **Sort results by modification date**

### Result: 
- **UI shows loading spinner for 5-60+ seconds** if user has 5-20 notebooks
- **NO OPTIMIZATIONS**: Notebooks downloaded/parsed sequentially
- **NETWORK DEPENDENT**: Each notebook blocks on downloading
- **NO CACHING**: Even already-cached notebooks are re-downloaded

## Other Observations

### LoginScreen ([login_screen.dart](lib/features/auth/login_screen.dart#L33))
- On "Login" button tap:
  - Creates WebDavService with credentials
  - Calls `webdav.testConnection()` - network call
  - Calls `webdav.ensureBaseDirectory()` - network call
  - Calls `credentialsProvider.notifier.login()` - SharedPreferences write
  - **NOT blocking app startup** (only during login screen interaction)

### LibraryScreen Rendering ([library_screen.dart](lib/features/library/library_screen.dart#L410))
- GridView.builder with NotebookCards (appears after data loads)
- _NotebookCard draws:
  - Gradient cover with colored background
  - Title, page count, chapters, paper type
  - **NO heavy computation** - all data from metadata already loaded
  - Rendering is instant once data available

## Summary of Delays

| Stage | Duration | Blocking | Cause |
|-------|----------|----------|-------|
| main() → FileService.init() | ~100-300ms | YES | SQLite open + dir creation |
| App initialization → FirebaseGate render | ~50ms | NO | - |
| Credentials load | ~100-300ms | NO | SharedPreferences async I/O |
| First screen render (empty) | ~50ms | NO | - |
| **notebookListProvider.refresh() starts** | **~5000-60000ms+** | **PARTIAL** | **Network + ZIP decompression** |
| User sees loading spinner | **5-60+ seconds** | - | - |

## Key Performance Bottlenecks

1. **CRITICAL**: Sequential download + parse of ALL notebooks on app start
   - Each notebook re-downloaded even if cached
   - ZIP decompression on main thread (if not isolated)
   
2. **HIGH**: WebDAV PROPFIND can be slow with many files

3. **MEDIUM**: JSON parsing of large document.json files

4. **MEDIUM**: Sequential SQLite inserts in loop

5. **MINOR**: Directory/database initialization at startup (hidden by CRITICAL issue)

## What Happens if User Has Many Notebooks

- 5 notebooks × 2-3s each = 10-15s loading
- 20 notebooks × 2-3s each = 40-60s loading (unacceptable!)
