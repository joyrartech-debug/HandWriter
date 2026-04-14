# Bad WiFi Scenario Analysis - Exact Code Paths

## SCENARIO 1: Network Drop During Stroke Auto-Save Upload

**Trigger**: User draws stroke on iPad, auto-save fires every 30s, upload starts but network drops mid-way.

### Code Path:
1. **Stroke committed** → [canvas_provider.dart](canvas_provider.dart#L1467) `_addStrokeElement()` sets `isDirty: true`
2. **Auto-save timer fires** → [canvas_screen.dart](canvas_screen.dart#L118-L122)
   - Timer.periodic every 30 seconds
   - Calls `_save(silent: true)` if `isDirty && !_isSaving`
3. **Save() called** → [canvas_provider.dart](canvas_provider.dart#L4207-L4250)
   - Detects changed pages (line 4213-4225)
   - Builds ZIP package in isolate (line 4228-4240)
   - Updates UI state immediately to `isDirty: false` (line 4243-4248)
   - **Fire-and-forget**: calls `_persistAndSyncAsync()` (line 4250)
4. **Background sync starts** → [canvas_provider.dart](canvas_provider.dart#L4286-L4311)
   - Local write succeeds (line 4320-4335)
   - Remote sync attempted (line 4337+)
   - **If upload times out or network drops**: caught at line 4373 `catch (e)`
5. **On timeout/network failure** → [canvas_provider.dart](canvas_provider.dart#L4373-4374)
   ```dart
   } catch (e) {
     debugPrint('[Canvas] Remote sync deferred (offline?): $e');
     await fileService.markNotebookDirty(updatedMeta.id);
   }
   ```
   - Dirty flag **re-set** in DB via `markNotebookDirty()` [file_service.dart](file_service.dart#L169-L176)
   - Local file SAVED, remote upload FAILED
   - **NEXT auto-save** will retry (30s later)

---

## SCENARIO 2: WebDAV Timeout Values

**Location**: [app_config.dart](app_config.dart#L10)
```dart
static const int webdavTimeoutSeconds = 120;
static const int maxRetries = 3;
```

**All WebDAV operations use this timeout**:
- `testConnection()` [webdav_service.dart](webdav_service.dart#L47): `.timeout(Duration(seconds: 120))`
- `listDirectory()` [webdav_service.dart](webdav_service.dart#L66): `.timeout(Duration(seconds: 120))`
- `downloadFile()` [webdav_service.dart](webdav_service.dart#L95): `.timeout(Duration(seconds: 120))`
- `uploadFile()` [webdav_service.dart](webdav_service.dart#L108): `.timeout(Duration(seconds: 120))` 
- `createDirectory()` [webdav_service.dart](webdav_service.dart#L122): `.timeout(Duration(seconds: 120))`
- `delete()` [webdav_service.dart](webdav_service.dart#L135): `.timeout(Duration(seconds: 120))`
- `move()` [webdav_service.dart](webdav_service.dart#L147): `.timeout(Duration(seconds: 120))`
- `getEtag()` [webdav_service.dart](webdav_service.dart#L160): `.timeout(Duration(seconds: 120))`
- `getContentLength()` [webdav_service.dart](webdav_service.dart#L197): `.timeout(Duration(seconds: 120))`

**Sync delta upload**: [sync_service.dart](sync_service.dart#L800-850) - each file uses 120s timeout via `uploadFile()`

---

## SCENARIO 3: Multiple Save() Calls While Sync In-Flight (Bad WiFi = Slow)

**Mechanism**: NO DEBOUNCE - relies on `_isSaving` flag to prevent concurrent saves.

### Code Path:
1. **First save() fires** → [canvas_screen.dart](canvas_screen.dart#L127)
   ```dart
   Future<void> _save({bool silent = false}) async {
     if (_isSaving) return;  // ← GUARD against concurrent saves
     _isSaving = true;
   ```
   - `_isSaving` set to `true` (line 128)

2. **User draws again** → `isDirty: true` is set (e.g., [canvas_provider.dart](canvas_provider.dart#L1467))

3. **Auto-save timer fires 30s later** → [canvas_screen.dart](canvas_screen.dart#L120)
   ```dart
   if (state != null && state.isDirty && !_isSaving) {
     _save(silent: true);
   }
   ```
   - Checks `!_isSaving` - **BLOCKED if first save still uploading**

4. **First save completes** (or timeout at 120s) → [canvas_screen.dart](canvas_screen.dart#L139)
   ```dart
   } finally {
     _isSaving = false;
   }
   ```

5. **Second save can now fire** if `isDirty` is still `true`

**Result**: On bad WiFi with 120s timeout, a new save can start, but NOT concurrently. Max 1 active upload at a time.

---

## SCENARIO 4: Auto-Save Timer Keeps Firing Even if Previous Save Hasn't Completed

**Yes, it does keep firing** - but the save is blocked.

### Code Path:
- **Timer setup** → [canvas_screen.dart](canvas_screen.dart#L118-L122)
  ```dart
  _autoSaveTimer = Timer.periodic(_autoSaveInterval, (_) {
    final state = ref.read(canvasProvider);
    if (state != null && state.isDirty && !_isSaving) {
      _save(silent: true);
    }
  });
  ```
  - `Timer.periodic` **ALWAYS fires every 30s**, regardless of previous save state

- **Guard prevents concurrent execution** (line 120-121)
  - Checks `!_isSaving` before calling `_save()`
  - If previous save still running, the check is skipped
  - No exponential backoff or debounce
  - **No throttling** - just skips the callback if `_isSaving === true`

**Example timeline (bad WiFi, 120s upload timeout)**:
- T=0s: Timer fires → `_save()` starts, `_isSaving=true`
- T=30s: Timer fires → `_isSaving=true`, callback skipped
- T=60s: Timer fires → `_isSaving=true`, callback skipped
- T=90s: Timer fires → `_isSaving=true`, callback skipped
- T=120s: Upload timeout → `_isSaving=false`
- T=120s: Next timer fire (or immediate if within window) → `_isSaving=false`, `isDirty=true` → `_save()` fires again

**No debounce/throttle logic** - just simple boolean guard.

---

## SCENARIO 5: Online Check Says "Online" But Upload Timeout (Flaky WiFi)

**Connectivity check timing issue**: Separate from upload timeout.

### Code Path:
1. **Connectivity monitor** → [connectivity_service.dart](connectivity_service.dart#L1-70)
   - Periodic socket connection check every 15s (default) [connectivity_service.dart](connectivity_service.dart#L28)
   - Updates `isOnline` ValueNotifier (line 33)
   - **Problem**: 5s socket timeout [connectivity_service.dart](connectivity_service.dart#L32), but it only checks if socket can be ACCEPTED, not if data can transfer

2. **Sync fires based on online check** → [sync_service.dart](sync_service.dart#L136-140)
   ```dart
   if (!await isServerReachable()) {
     debugPrint('[Sync] Server unreachable, skipping sync cycle.');
     return;
   }
   ```
   - `isServerReachable()` → `testConnection()` → Socket check only (line 47)

3. **Upload proceeds despite flaky WiFi**:
   - Socket connection succeeds → app thinks it's online
   - But actual data upload hangs/drops mid-way
   - **120s timeout** eventually fires → `WebDavException` thrown
   - Exception caught at [canvas_provider.dart](canvas_provider.dart#L4373)

**Result**: App thinks it's online (socket OK), but upload fails with timeout anyway.
- Dirty flag re-set via `markNotebookDirty()` [file_service.dart](file_service.dart#L169)
- **Retry**: App will try again in 30s when next auto-save timer fires

---

## SCENARIO 6: Dirty Flag After 5+ Consecutive Failures

**YES, dirty flag is PRESERVED across app restarts.**

### Code Path:
1. **Local save succeeds, remote fails** → [canvas_provider.dart](canvas_provider.dart#L4373-4374)
   ```dart
   } catch (e) {
     debugPrint('[Canvas] Remote sync deferred (offline?): $e');
     await fileService.markNotebookDirty(updatedMeta.id);
   }
   ```
   - DB updated: `sync_status = 'modified'` [file_service.dart](file_service.dart#L172)

2. **Failure 1-5 (all same cycle)**:
   - Timer fires (30s interval)
   - `_isSaving` guard prevents overlap
   - Each attempt: local OK, remote fails → `markNotebookDirty()` called again
   - `isDirty` flag stays `true` in memory

3. **App restart** (user force-quit or crash):
   - **Dirty flag persists** via database!
   - SQL table: `notebooks.sync_status` = `'modified'` [file_service.dart](file_service.dart#L58)
   - On reopen: Library loads notebook from DB → `sync_status` read
   - App can check `getDirtyNotebooks()` [file_service.dart](file_service.dart#L196)

4. **After restart, sync retries automatically** (or manual):
   - Auto-sync timer [sync_service.dart](sync_service.dart#L102) fires every 5 minutes
   - Checks all dirty notebooks → queues them for sync
   - **NO explicit retry limit** - will keep retrying

**No max-retry counter for repeated failures** - just keeps `sync_status = 'modified'` until success.

---

## SCENARIO 7: iOS App Backgrounding/Foregrounding - Save & Sync Behavior

**NO EXPLICIT LIFECYCLE HANDLING - this is a gap!**

### Code Path:
1. **Navigation.pop() with dirty check** → [canvas_screen.dart](canvas_screen.dart#L260-277)
   ```dart
   Future<bool> _onWillPop() async {
     final state = ref.read(canvasProvider);
     if (state != null && state.isDirty) {
       final result = await showDialog(...);
       if (result == 'save') await _save();
     }
     ref.read(canvasProvider.notifier).closeNotebook();
     return true;
   }
   ```
   - **Only fires on explicit nav.pop()** - NOT on background/foreground!

2. **Auto-save timer persists** → [canvas_screen.dart](canvas_screen.dart#L118-122)
   - Timer is NOT cancelled on background
   - **Still fires every 30s even if app is backgrounded**
   - BUT: Dart/Flutter runtime may throttle/pause timers in background (OS-level)

3. **No `WidgetsBindingObserver`** in canvas_screen.dart
   - No `didChangeAppLifecycleState()` handler
   - No specific save on foreground/background transitions

4. **What actually happens**:
   - **Background**: Auto-save timer may be throttled by OS (iOS), but local/sync continues if allowed
   - **Foreground**: Timer resumes if it was paused, generates save attempt
   - **No explicit flush/sync on transition** - relies entirely on auto-save timer

5. **User action on return from background**: 
   - Any new stroke → `isDirty: true`
   - Next 30s timer fire → `_save()` if `!_isSaving`

**GAP**: No explicit "save before backgrounding" implementation. If app is killed while sync is in-flight:
- Local file already saved (synchronously before bg)
- Remote upload may be lost → dirty flag preserved in DB
- On reopen: retry via auto-sync

---

## TIMEOUT CONFIG SUMMARY
- **WebDAV ops**: 120 seconds (AppConfig.webdavTimeoutSeconds) [app_config.dart](app_config.dart#L10)
- **Auto-save**: 30 seconds interval [canvas_screen.dart](canvas_screen.dart#L87)  
- **Connectivity check**: 5 seconds socket timeout (per attempt) [connectivity_service.dart](connectivity_service.dart#L32)
- **Delta pull**: 10 seconds interval [app_config.dart](app_config.dart#L14)
- **Sync interval**: 5 minutes [app_config.dart](app_config.dart#L12)
- **Sync debounce**: 5 seconds [app_config.dart](app_config.dart#L11)

**NO RETRY: No explicit max-retry or exponential backoff** - uses boolean guards + timestamps only.
