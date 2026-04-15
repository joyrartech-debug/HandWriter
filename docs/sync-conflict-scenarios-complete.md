# HandWriter Sync Conflict Scenarios - COMPLETE ANALYSIS

## Scenario 1: Device A offline → comes back online with new strokes, Device B also edited the same notebook

### Flow Trace:

#### From `_syncDirtyNotebooks()` in library_screen.dart
- Loads all dirty notebooks from DB
- For each: validates, uploads full ZIP, migrates/updates delta folder
- **No ETag conflict check** before uploading

#### From `_persistAndSyncAsync()` in canvas_provider.dart
- Local file write first (full ZIP for offline cache)
- Ensure delta folder exists (one-time migration)
- Delta upload: only changed pages
- Also upload full .ncnote ZIP for legacy devices
- Mark as synced

### ETag Checks and Conflict Detection:

#### ETag Check 1: In sync_service.dart `_syncNotebook()`
```dart
if (cachedEtag != null && remoteEtag != null && cachedEtag != remoteEtag) {
  entry.status = SyncStatus.conflict;
  await _handleConflict(entry, remoteEtag);
  return;
}
```

#### ETag Check 2: During Pull in `_pullRemoteChanges()`
- Strategy 1: Check exploded _delta/ folder metadata ETag
- Strategy 2: Check .ncnote ZIP ETag (fallback)

---

## Scenario 2: Device A deletes a notebook while Device B is offline editing it

### What Happens:
- Remote deletion detection removes synced notebooks not found on server
- But Device B RE-UPLOADS the deleted notebook when it comes online
- **Result**: Device A's deletion is undone

---

## Scenario 3: Device A deletes a page, Device B adds content to that page

### Delta Sync Page Detection:
- `_pullFromDelta()` detects ETag changed for the page
- Downloads remote version and **merges it back in**
- Device B's page is restored, overwriting Device A's deletion
- **No explicit conflict handling** - silently restores

---

## Scenario 4: Both devices edit the SAME page simultaneously

### Resolution Strategy: LAST-WRITE-WINS
- Compares `localPage.modifiedAt` vs remote `modifiedAt`
- If remote is NEWER: local edits **overwritten**
- If local is NEWER: local version kept
- **No merge, no conflict notification**

---

## Scenario 5: Conflict Handler - `_handleConflict()`

### Strategy: LAST-WRITE-WINS with Backup
1. Remote version downloaded and saved as `notebook_conflict_<timestamp>.ncnote`
2. Local version wins - status set back to `SyncStatus.modified`
3. Next sync cycle uploads local version
4. User must manually recover from `_conflict_` backup if needed

---

## CRITICAL FINDINGS

### What's NOT Handled:
1. **No per-page conflict detection** in delta sync
2. **No merge of conflicting edits** - one device completely overwrites
3. **No user notification UI** - SyncStatus.conflict exists but no UI
4. **No automatic recovery** - User must manually restore from backup
5. **Symbol libraries not synced via delta** - Only full ZIP
6. **Race condition**: Simultaneous uploads → incomplete state possible

### When Conflicts Happen:
- **ETag mismatch** on `.ncnote` → triggers `_handleConflict()`
- **modifiedAt comparison** in `_pullFromZip()` → silently overwrites older
- **Page ETag mismatch** in `_pullFromDelta()` → pulls remote, overwriting local deletions
