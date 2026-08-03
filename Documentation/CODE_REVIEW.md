# ExifShell — Code Review Status

This document tracks outcomes from a full codebase walkthrough. Items are marked with their implementation status.

**Legend:** ✅ Implemented · ⬜ Open / Not Started · 🔄 Partially Done

---

## 🔴 Concerns & Potential Issues

### 1. Stale Documentation References ✅ Implemented

Several documentation references no longer matched the code:

| Location | Stale Reference | Fixed To |
|---|---|---|
| `ARCHITECTURE.md` — Import | "chunks of 80 files" | "chunks of 200 files" |
| `ARCHITECTURE.md` — Sanitise | "batches of 80" | "batches of 200" |
| `ARCHITECTURE.md` — Rename | "batches of 80" | "batches of 200" |
| `ARCHITECTURE.md` — Data Flow | "reads metadata in batches of 80" | "batches of 200" |
| `ARCHITECTURE.md` — Batch Reads | "chunks of 80 files" | "chunks of 200 files" |
| `ARCHITECTURE.md` — Read (full batch) | Command missing `-QuickTime:CreationDate -Make -Model -FileType -FileTypeExtension` | Command now matches `readAllTags` in code |
| `AGENTS.md` | Already current (19 tags, 15 fields, 200 batch) | No change needed |

**Note:** A CI check that greps for `"batches of 80"` / `"chunks of 80"` in `Documentation/` would prevent future drift. *(Open suggestion)*

---

### 2. `FileTableView` Cell Reuse — Fragile Warning Label Management ✅ Implemented

**Problem:** `dequeueTextCell` dynamically removed any `NSTextField` subview that wasn't the cell's `textField`, and leaked the `trailingAnchor` constraint when the warning label was removed.

**Fix:** Added a dedicated `FilenameCellView` subclass (private class in `FileTableView.swift`) with:
- A pre-built warning label (⚠️) always present as a subview, toggled via `isHidden`
- Pre-allocated constraint references (`warningTrailingConstraint`, `warningCenterYConstraint`, `textToWarningConstraint`, `textToTrailingConstraint`) that are toggled active/inactive — no constraint churn on reuse
- A `configure(text:warningText:warningToolTip:)` method for cell reuse
- A dedicated `dequeueFilenameCell` factory method for the Filename column

Also updated `dequeueTextCell` to accept optional `textColor` and `toolTip` parameters so the new Type column can reuse it without resetting colors improperly.

---

### 3. `FileListViewModel` — Computed Properties Iterate the Full Array ✅ Implemented

**Problem:** `imageCount`, `videoCount`, `dirtyCount`, and `mismatchedCount` each did O(n) `files.filter` on every SwiftUI body evaluation.

**Fix:** Added to `FileListViewModel.swift`:
- `private struct FileStats` holding cached counts
- `_cachedStats` + `_statsVersion` with `didSet { recomputeStats() }`
- `recomputeStats()` — single O(n) pass computing all four counts
- `invalidateSort()` now bumps `_statsVersion` alongside `_sortVersion`
- Getters read `_ = _statsVersion` (for observation tracking) then return `_cachedStats` values — O(1)

---

### 4. `isSanitising` Defined Mid-File ✅ Implemented

Moved `var isSanitising = false` in `FileListViewModel.swift` from line ~607 to the top with the other operation flags (`isLoading`, `isSaving`, `isRenaming`, `isFixingExtensions`).

---

### 5. `clearFeedback()` vs `clearAll()` — State Drift Risk ✅ Implemented

`clearAll()` now calls `clearFeedback()` first (resetting `lastSaveFeedback`, `lastDescriptionSaveFeedback`, `lastErrorDetail`, `statusMessage`, `operationMessage`, `operationProgress`), then resets only the persistent state (`selectedFile`, `selectedFiles`, `bulkEditValue`, `bulkEditDescriptionValue`).

---

### 6. Image Extensions Duplicated in ViewModel ✅ Implemented

**Fix:** Moved `imageExtensions` to `ExifToolService` (co-located with `videoExtensions`). `FileListViewModel` now delegates:
- `isSupportedFile(_:)` → `ExifToolService.isSupportedFile(_:)`
- `mediaType(for:)` → `ExifToolService.mediaType(for:)`
- The private `imageExtensions` set and both `mediaType`/`isSupportedFile` methods were removed from `FileListViewModel.swift`

The service layer is now the single source of truth for both image and video extension detection.

---

### 7. `FileListViewModel+ExtensionFix.swift` — Confirmation Before Bulk Rename ✅ Implemented

**Fix:** Added a confirmation dialog for "Fix All":
- `FileListViewModel.showFixAllConfirmation` boolean state
- `FileListViewModel.confirmFixExtensionsAll()` sets the flag
- `PreviewPanel` has a `.alert` bound to `$viewModel.showFixAllConfirmation` with:
  - "Fix All (N files)" destructive button
  - "Cancel" button
  - Message explaining files are renamed on disk and can be undone

---

## 🟡 Organisational Improvements

### 8. `FileListViewModel.swift` Is Getting Large (~800 lines) ⬜ Open

The main ViewModel file handles: sorting, import, selection, bulk edit, date helpers, sanitise, and file type detection. Consider splitting:

- `FileListViewModel+Sorting.swift` — sort key enum, `sortedFiles`, `_sortVersion`, `_cachedStats`
- `FileListViewModel+Import.swift` — `importFiles`, `importFolder`, `loadMetadata`, `applyMetadata`
- `FileListViewModel+BulkEdit.swift` — `applyBulkEdit`, `applyBulkSet`, `applyBulkOffset`, `applyBulkEditDescription`
- `FileListViewModel+Sanitise.swift` — `sanitiseSelected`, `sanitiseAll`, `sanitiseFiles`

### 9. `ExifToolService+ReadWrite.swift` Is Very Large (740+ lines) ⬜ Open

This single extension file contains: `FileMetadata`, `DateSource`, JSON decoders, property wrappers, read methods, write methods, and sanitise. Consider splitting:

- `ExifToolService+Read.swift` — `readAllMetadata`, `readDateTimeOriginal`, JSON decoding types
- `ExifToolService+Write.swift` — `writeDateTimeOriginal`, `writeDescription`, `writeQuickTimeCreationDate`
- `ExifToolService+Sanitise.swift` — `sanitise`

### 10. `PreviewPanel.swift` Is 600+ Lines ⬜ Open

The view handles: header, thumbnail, extension mismatch banner, editable fields, metadata display, save feedback, action buttons, and status. Consider extracting:

- `ExtensionMismatchBanner.swift` — the orange warning banner with Fix buttons
- `ActionButtonsView.swift` — the Save/Sanitise/Rename button rows
- `MetadataSectionView.swift` — the read-only metadata display

### 11. `FileTableView.swift` Coordinator Is Growing (now includes context menu) ⬜ Open

The `Coordinator` class handles data source, delegate, cell factories, editing, hover, and now context menu. Consider extracting cell factory methods into a separate `FileTableCellFactory` type.

---

## 🟢 Efficiency Opportunities

### 12. Targeted Table Reloads ⬜ Open

`FileTableView.updateNSView` calls `tableView.reloadData()` on every `invalidateSort()` — even for single-cell edits. For large collections, this is expensive.

**Recommendation:** Track which rows changed and use `reloadData(forRowIndexes:columnIndexes:)` for targeted updates.

### 13. Batch Size Documentation Mismatch ✅ Implemented

Stale "batches of 80" references in `ARCHITECTURE.md` were updated to "batches of 200". The `metadataBatchSize = 200` value in `FileListViewModel` is correct — docs now match.

### 14. `runBackground` Could Be Reused ✅ Implemented

`FileListViewModel+Rename.swift` now uses `runBackground` instead of raw `Task.detached(priority: .userInitiated)`:

```swift
// Before:
let result = await Task.detached(priority: .userInitiated) { ... }.value

// After:
let result = await runBackground { ... }
```

---

## 🔵 Feature Opportunities

### 15. Right-Click Context Menu for Individual Extension Fix ✅ Implemented

Added `tableView(_:menuForRows:)` to `FileTableView.Coordinator`:
- **"Fix Extension"** — appears when the right-clicked row has a mismatched extension, calls `fixExtensionsAsync(only: [file])`
- **"Sort by Mismatched"** — always available, sets `viewModel.sortKey = .mismatched`

### 16. Filter / Sort by Mismatched Files ✅ Implemented

- Added `.mismatched` case to `FileListViewModel.SortKey`
- `sortedFiles` sorts mismatched files to the top (ascending) / bottom (descending), then by filename
- The new "Type" column header can be clicked to toggle this sort
- Context menu also provides "Sort by Mismatched"

### 17. "Select All Mismatched" Action ✅ Implemented

- Added `selectAllMismatched()` to `FileListViewModel`
- The mismatch pill in `QuickStatsBar` is now a clickable button (`.buttonStyle(.plain)` with `.contentShape(Capsule())`) that selects all mismatched files
- Help text: "Click to select all mismatched files"

### 18. Show Actual File Type in Table ✅ Implemented

Added a "Type" column to `FileTableView`:
- Displays `file.readOnly.actualFileType` (e.g. "JPEG", "HEIC", "PNG"), or "—" when unknown
- Orange text when the file has a mismatched extension
- Tooltip explains when there's a mismatch
- Sorted via the `.mismatched` sort key (mismatched files first)

### 19. Undo Support for Extension Fixes ✅ Implemented

- `FileListViewModel.lastExtensionFixUndo: [(oldURL: URL, newURL: URL)]` tracks successful fix renames
- `FileListViewModel.canUndoExtensionFix` computed property
- `FileListViewModel.undoExtensionFix()` renames files back to their original URLs, updates loaded `ImageFile` instances, and clears the undo history
- An "Undo" button appears in the `PreviewPanel` mismatch banner when `canUndoExtensionFix` is true

### 20. Use `UTType` for File Type Detection ⬜ Open

The app still uses hardcoded extension sets. macOS's `UniformTypeIdentifiers` framework provides `UTType(filenameExtension:)` which is more robust and future-proof. This would also handle case-insensitivity and aliases (e.g. `jpeg` vs `jpg`) automatically.

**Note:** `FileListViewModel.swift` already imports `UniformTypeIdentifiers` but uses it only for drop handling. The hardcoded sets in `ExifToolService+Extensions.swift` (`imageExtensions`, `videoExtensions`, `quickTimeExtensions`, `heicExtensions`, `unwritableVideoExtensions`) could be migrated to UTType lookups.

---

## 📋 Summary Status

| Item | Priority | Status |
|---|---|---|
| 1 — Stale documentation | 🔴 High | ✅ |
| 2 — `dequeueTextCell` constraint leak | 🔴 High | ✅ |
| 3 — Cache computed counts | 🟡 Medium | ✅ |
| 4 — Move `isSanitising` | 🔴 High | ✅ |
| 5 — `clearAll()` → `clearFeedback()` | 🔴 High | ✅ |
| 6 — Move `imageExtensions` to service | 🟡 Medium | ✅ |
| 7 — Confirmation for "Fix All" | 🔴 High | ✅ |
| 8 — Split `FileListViewModel` | 🟡 Medium | ⬜ |
| 9 — Split `ExifToolService+ReadWrite` | 🟡 Medium | ⬜ |
| 10 — Split `PreviewPanel` | 🟡 Medium | ⬜ |
| 11 — Extract `FileTableCellFactory` | 🟡 Medium | ⬜ |
| 12 — Targeted table reloads | 🟢 Low | ⬜ |
| 13 — Batch size docs | 🟢 Low | ✅ |
| 14 — `runBackground` reuse | 🟢 Low | ✅ |
| 15 — Context menu fix | 🟢 Low | ✅ |
| 16 — Sort by mismatched | 🟢 Low | ✅ |
| 17 — Select All Mismatched | 🟢 Low | ✅ |
| 18 — Type column | 🟢 Low | ✅ |
| 19 — Undo for extension fixes | 🟢 Low | ✅ |
| 20 — Use `UTType` | 🟢 Low | ⬜ |

**Complete: 15/20 (75%)**

### Remaining Open Items (5)

1. **Split `FileListViewModel`** into extensions (Sorting, Import, BulkEdit, Sanitise)
2. **Split `ExifToolService+ReadWrite`** into Read / Write / Sanitise files
3. **Split `PreviewPanel`** into `ExtensionMismatchBanner`, `ActionButtonsView`, `MetadataSectionView`
4. **Targeted table reloads** — use `reloadData(forRowIndexes:columnIndexes:)` instead of full reloads
5. **Migrate to `UTType`** for file type detection

These are all maintainability/performance improvements with no functional impact — safe to defer to a future refactor pass.