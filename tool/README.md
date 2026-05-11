# HandWriter — Maintenance scripts

Standalone Dart scripts for one-off filesystem operations on the local
Nextcloud HandWriter mirror (`~/Nextcloud/HandWriter/`). They bypass the
running app and operate directly on the synced files, so changes are
fast (local disk) and Nextcloud propagates them to the server in the
background.

**Always close the app before running these.** Concurrent writes to the
same files would race the script's atomic rewrites.

---

## `compress_pdf_assets.dart`

Re-encodes existing PDF-raster PNG assets as JPEG q=85 in place, cutting
storage / sync bandwidth by ~50-80% on PDF-heavy notebooks.

**Filters by filename pattern** (`*.pdf_pXX.png`) so user screenshots /
pasted images with legitimate alpha channels are left untouched. The
app decodes by magic bytes, not extension, so the `.png` filename keeps
working transparently.

```bash
# Run on the default ~/Nextcloud/HandWriter root
dart run tool/compress_pdf_assets.dart

# Override the root
dart run tool/compress_pdf_assets.dart /custom/path/HandWriter
```

Idempotent: files already in JPEG form are skipped (magic-byte
detection). Files that don't compress smaller as JPEG (line-art PDFs)
are also skipped — original stays.

After running, the Nextcloud desktop client syncs the modified bytes to
the server; other devices download just the changed assets on their
next pull (ETag mismatch).

---

## `repair_empty_delta.dart`

Recovers from the "0-byte file on the server" scenario — caused by a
historic half-committed PUT where the wire body got cut off, the server
committed an empty body, and the file stayed 0 bytes on disk.

Symptom in the app: a notebook stuck in an infinite pull loop with
`FormatException: Unexpected end of input (at character 1)`.

### Modes

```bash
# Dry-run report (no flags): list all 0-byte .json files grouped by notebook
dart run tool/repair_empty_delta.dart
```

```bash
# Rebuild document.json from the live state of pages/ + metadata.json.
# Preferred over .ncnote restore: preserves work done AFTER the backup
# date. Only acts on document.json — page content is untouched.
dart run tool/repair_empty_delta.dart --rebuild-document
```

```bash
# Restore empty files from the corresponding root .ncnote ZIP backup.
# Use only when the .ncnote is fresh — older backups WILL overwrite
# recent work in OTHER pages/metadata of that notebook.
dart run tool/repair_empty_delta.dart --repair
```

```bash
# Hard-delete remaining 0-byte files. The app then handles them as
# "missing" (re-syncs from another device if available, else gracefully
# excludes them).
dart run tool/repair_empty_delta.dart --delete-empty
```

### Typical recovery

Server has 0-byte `document.json` (and maybe one or two 0-byte pages),
the rest of the notebook is fine, the user worked beyond the last
`.ncnote` backup:

```bash
dart run tool/repair_empty_delta.dart --rebuild-document --delete-empty
```

This:
1. Rebuilds `document.json` from the current `pages/*.json` content (no
   data loss for the surviving pages).
2. Deletes the irrecoverable 0-byte pages so the app stops looping on
   them.

After the script: re-open the app. The pull cycle completes normally;
Nextcloud syncs the rebuilt files to the server and other devices pick
them up on their next pull.

---

## `audit_notebooks.dart`

Periodic structural audit + optional cleanup of the local Nextcloud
HandWriter mirror. Catches the residual drift that accumulates over
months of multi-device sync: orphan pages, orphan assets, duplicate
pageId entries, stale chapter references, page-count mismatches, old
conflict `.ncnote` backups.

```bash
# Read-only audit (safe default)
dart run tool/audit_notebooks.dart

# Apply repairs after a y/N prompt
dart run tool/audit_notebooks.dart --clean

# Apply without prompting (CI / automation)
dart run tool/audit_notebooks.dart --clean --yes

# Override mirror root
dart run tool/audit_notebooks.dart /custom/HandWriter
```

The `--clean` pass does, in order:

1. Removes `_conflict_*.ncnote` files from the root older than 14 days
   (Nextcloud-style conflict copies the app accumulated but never
   cleaned).
2. **Reports** `page_*.json` files on disk that aren't in `document.json`
   but **never auto-deletes them**. A page < 1 KB in HandWriter is NOT
   "empty" — it's the JSON skeleton of a PDF-imported page that points
   at one asset PNG. Deleting it discards the user's PDF content. Manual
   reattachment to `document.json` (with the right `chapterId` derived
   from the referenced asset's PDF filename) is the safe repair.
3. Removes asset files not referenced by any active page.
4. Drops duplicate-pageId entries from `document.json` (e.g.
   `page_068.json` and `page_072.json` sharing pageId X), keeping the
   first occurrence and deleting the other files.
5. Drops entries from `document.json` whose `page_*.json` file is
   missing (server-side residue from a sync race).
6. Clears orphan `chapterId` in `document.pages[]` (sets to null when
   the chapter no longer exists).
7. Drops orphan `pageIds` from `metadata.chapters[].pageIds`.
8. Updates `metadata.pageCount` to match the actual file count.

Like the other scripts in this folder, atomic temp+rename writes
prevent the Nextcloud client from snapshotting a half-written file,
and a clean run is a no-op (idempotent).

The 0-byte `metadata.json` / `document.json` case is deliberately **not**
handled here — that's the `repair_empty_delta.dart` job. The audit
script reports them but won't touch them.

---

## Safety notes

- Both scripts use atomic `temp + rename` writes — a Nextcloud client
  picking up the file mid-script sees either the old or the new version,
  never a half-written one.
- Both are idempotent: re-running on a clean filesystem is a no-op.
- Neither modifies the running app's local cache (`~/Documents/HandWriter`,
  `~/.local/share/handwriter`, etc.) — only the Nextcloud mirror at
  `~/Nextcloud/HandWriter/`. The app's local cache rebuilds itself from
  the server on next pull.
