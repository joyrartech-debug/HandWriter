# HandWriter Sync System - Comprehensive Analysis

## Overview
Offline-first Flutter app with delta sync capability. Primary data format: .ncnote (ZIP archives containing JSON metadata, pages, and binary assets).

## Key Findings Summary

### ✅ STRENGTHS
1. **Offline-first architecture** - All changes saved locally before remote sync
2. **ETag-based conflict detection** - Uses WebDAV ETags for change detection
3. **Delta sync** - Can upload only changed pages instead of full ZIP
4. **Parallel parallelized downloads** - Batch & concurrent remote operations
5. **ZIP integrity validation** - Pre/post upload/download corruption checks
6. **Isolate-based packaging** - Package building off main thread
7. **Connectivity monitoring** - Socket-based connection detection
8. **Local persistence** - SQLite metadata + file cache

### ⚠️ CRITICAL ISSUES  
1. **NO RETRY LOGIC ON SYNC FAILURES** - Fire-and-forget `_persistAndSyncAsync()`
2. **NO MUTEX/LOCKING** - Race condition between concurrent page saves
3. **PARTIAL WRITE RISK** - If upload fails mid-operation, no rollback
4. **ASSET TRACKING BUG** - `assetReferences` can fall out of sync with image elements
5. **STAT RACE** - File size verification happens after upload, no atomic check
6. **UNHANDLED PROMISE** - Delta sync background task can silently fail
7. **INCOMPLETE PULL LOGIC** - Missing symbol library sync from remote
8. **ZIP PARSE DOUBLE-DECODE** - Inefficient parsing in some paths

## Critical Flow: From Edit to Upload

### 1. LOCAL SAVE (FAST PATH - RETURNS IMMEDIATELY)
```
User edits → isDirty=true → await save() → state.isDirty = false → RETURN
                                              ↓
                    [BACKGROUND] _persistAndSyncAsync()
                    (fire-and-forget, if fails, just logs)
```

### 2. LOCAL PERSISTENCE (_persistAndSyncAsync)
- ZIP package built in isolate via `compute()`
- Saved to disk via `fileService.saveNotebookFile()`
- SQLite metadata upserted
- **NO RETRY ON FAIL** - If write fails, sync attempt proceeds anyway

### 3. REMOTE SYNC
#### Phase 1: Ensure delta folder exists
- Calls `_ensureDeltaDir()` to create `/HandWriter/.sync/<id>/` structure

#### Phase 2: Delta upload
- Uploads metadata.json, document.json, all dirty pages in parallel
- No transactional guarantees

#### Phase 3: ZIP fallback upload
- Also uploads full .ncnote ZIP to server
- Ensures legacy devices can still download

### 4. SIZE VERIFICATION (POST-UPLOAD)
- Happens AFTER upload completes
- **Non-atomic** - server could truncate/corrupt between PUT and PROPFIND

## Critical Race Conditions

### Race A: Concurrent Page Edits
Thread 1 uploads while Thread 2 edits same page → potential lost update.

### Race B: Pull vs Local Save
`_pullRemoteChanges()` fires while user is editing → LOSS OF LOCAL WORK

### Race C: Multiple Sync Operations In Flight
If #2 completes first and sets _remoteMetaEtag, then #1 completes with different metadata → corruption

## Error Handling Analysis

### ✅ Wrapped with try/catch:
- `testConnection()`, `listRemoteNotebooks()`, `downloadFile()`, `uploadFile()`
- `_downloadAndCache()` - has 2x retry
- `_pullFromDelta()` / `_pullFromZip()` - outer try/catch

### ❌ NOT wrapped:
- `_ensureDeltaDir()` - doesn't propagate errors upward
- `syncDelta()` - `Future.wait()` with no per-upload error handling
- `_persistAndSyncAsync()` - no retry
- `migrateToExploded()` - no per-upload error handling

## Offline Mode Handling

### Detection
- `ConnectivityService._check()` - Socket connection every 15 seconds
- `isServerReachable()` in SyncService - lightweight PROPFIND

### Behavior
- If unreachable: skip `syncAll()` entirely
- Local changes remain in SQLite + file cache
- On reconnect: timer fires `_pullRemoteChanges()`
- **NO QUEUING** - Failed syncs lost, must retry manually

## Data Integrity Violations

### Scenario 1: Interrupted ZIP Upload
Server receives partial data → Corrupted file persists on server

### Scenario 2: Delta Partial Upload
Some pages succeed, others fail → inconsistent state on server

### Scenario 3: Conflict Not Detected
Simultaneous edits + race on ETag check → silent overwrite

## Positives/Mitigations in Place

1. **Validation before upload** - `validateNcnoteArchive()` catches corrupted local builds
2. **Parallel batch downloads** - Efficient remote list loading (max 4 concurrent)
3. **Identity-based dirty detection** - Efficient page change detection
4. **Isolate-based ZIP building** - Non-blocking main thread
5. **Local-first persistence** - Users never lose offline work
6. **Graceful offline fallback** - App continues fully functional offline
7. **Metadata-based sync** - SQLite avoids expensive ZIP parsing
8. **Per-page ETags** - Delta pull can detect single-page changes precisely
