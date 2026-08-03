# ExifShell — Code Review & Improvement Opportunities

This document captures observations from a full codebase walkthrough. It highlights concerns, potential bugs, organisational improvements, and opportunities for making the codebase more efficient and maintainable.

---

## 🔴 Concerns & Potential Issues

### 1. Stale Documentation References

Several documentation references no longer match the code:

| Location | Stale Reference | Current Reality |
|---|---|---|
| `AGENTS.md` — Full Metadata Batch Read | "reading 17 tags" | Now 19 tags (added `-FileType`, `-FileTypeExtension`) |
| `AGENTS.md` — FullExifToolOutput | "11 fields" in `Core` | Now 15 fields (added `fileType`, `fileTypeExtension`) |
| `AGENTS.md` / `ARCHITECTURE.md` | "batches of 80" | `metadataBatchSize = 200` in `FileListViewModel` |
| `AGENTS.md` — ExifTool Commands | Read (full batch) command missing `-FileType` / `-FileTypeExtension` | These tags are now read |

**Recommendation:** Update documentation to match the current code, or better yet, add a CI check that greps for these numbers.

---

### 2. `FileTableView` Cell Reuse — Fragile Warning Label Management

In `FileTableView.swift`, the `dequeueTextCell` method manages the extension-mismatch warning label by:

```swift
let existingWarnings = cell.subviews.filter { $0 is NSTextField && $0 !== cell.textField }
existingWarnings.forEach { $0.removeFromSuperview() }
```

**Problems:**
- This removes **any** `NSTextField` subview that isn't the cell's `textField` — if a future feature adds another text field to the cell, it would be silently removed.
- The trailing constraint added when a warning label is present (`tf.trailingAnchor.constraint(lessThanOrEqualTo: warningLabel.leadingAnchor)`) is **never removed** when the warning is removed. This can cause Auto Layout constraint conflicts on cell reuse.

**Recommendation:** Create a dedicated `FilenameCellView` subclass with a pre-built warning label that is shown/hidden via `isHidden`, rather than dynamically adding/removing subviews.

---

### 3. `FileListViewModel` — Computed Properties Iterate the Full Array

The following computed properties each iterate over `files` on every access:

```swift
var imageCount: Int { files.filter { $0.mediaType == .image }.count }
var videoCount: Int { files.filter { $0.mediaType == .video }.count }
var dirtyCount: Int { files.filter(\.isDirty).count }
var mismatchedCount: Int { files.filter(\.hasMismatchedExtension).count }
```

For tens of thousands of files, these are O(n) on every SwiftUI body evaluation. The `QuickStatsBar` reads all four on every render.

**Recommendation:** Cache these counts and invalidate when `files` changes (via `files.didSet`), or use a single pass that computes all counts at once.

---

### 4. `isSanitising` Defined Mid-File

In `FileListViewModel.swift`, `isSanitising` is declared at line ~595, far from the other operation flags (`isLoading`, `isSaving`, `isRenaming`, `isFixingExtensions`) which are grouped at the top of the class.

**Recommendation:** Move `isSanitising` up with the other operation state flags for consistency.

---

### 5. `clearFeedback()` vs `clearAll()` — State Drift Risk

`clearFeedback()` resets transient state (`lastSaveFeedback`, `lastDescriptionSaveFeedback`, `lastErrorDetail`, `statusMessage`, `operationMessage`, `operationProgress`). But `clearAll()` manually resets a subset of these fields rather than calling `clearFeedback()`. If new transient fields are added in the future, `clearAll()` could miss them.

**Recommendation:** Have `clearAll()` call `clearFeedback()` first, then reset the persistent state.

---

### 6. Image Extensions Duplicated in ViewModel

`FileListViewModel` has a private `imageExtensions` set, while `ExifToolService` has `videoExtensions` as the "single source of truth". This creates an asymmetry — video extensions live in the service layer, image extensions live in the view model.

**Recommendation:** Move `imageExtensions` to `ExifToolService` (e.g. `ExifToolService.imageExtensions`) so both media type extension sets are co-located and the ViewModel doesn't own file-type knowledge.

---

### 7. `FileListViewModel+ExtensionFix.swift` — No Confirmation Before Bulk Rename

The "Fix All" button renames files on disk with no confirmation dialog. While the rename only changes the extension (safe in most cases), it's still a filesystem mutation that could surprise users if they have files with the same base name in the same directory (the code handles this by skipping, but silently).

**Recommendation:** Add a confirmation dialog for "Fix All" when more than a few files are affected, or at minimum show a clear count in the button label (already done) and a post-operation summary.

---

## 🟡 Organisational Improvements

### 8. `FileListViewModel.swift` Is Getting Large (798 lines)

The main ViewModel file handles: sorting, import, selection, bulk edit, date helpers, sanitise, and file type detection. The `+Save` and `+Rename` extensions are good patterns — consider extending this:

- `FileListViewModel+Sorting.swift` — sort key enum, sort descriptors, `sortedFiles`
- `FileListViewModel+Import.swift` — `importFiles`, `importFolder`, `loadMetadata`, `applyMetadata`
- `FileListViewModel+BulkEdit.swift` — `applyBulkEdit`, `applyBulkSet`, `applyBulkOffset`, `applyBulkEditDescription`
- `FileListViewModel+Sanitise.swift` — `sanitiseSelected`, `sanitiseAll`, `sanitiseFiles`

### 9. `ExifToolService+ReadWrite.swift` Is Very Large (725+ lines)

This single extension file contains: `FileMetadata`, `DateSource`, JSON decoders, property wrappers, read methods, write methods, and sanitise. Consider splitting:

- `ExifToolService+Read.swift` — `readAllMetadata`, `readDateTimeOriginal`, JSON decoding types
- `ExifToolService+Write.swift` — `writeDateTimeOriginal`, `writeDescription`, `writeQuickTimeCreationDate`
- `ExifToolService+Sanitise.swift` — `sanitise`

### 10. `PreviewPanel.swift` Is 560+ Lines

The view handles: header, thumbnail, extension mismatch banner, editable fields, metadata display, save feedback, action buttons, and status. Consider extracting:

- `ExtensionMismatchBanner.swift` — the orange warning banner with Fix buttons
- `ActionButtonsView.swift` — the Save/Sanitise/Rename button rows
- `MetadataSectionView.swift` — the read-only metadata display

### 11. `FileTableView.swift` Coordinator Is 300+ Lines

The `Coordinator` class handles data source, delegate, cell factories, editing, and hover. Consider extracting cell factory methods into a separate `FileTableCellFactory` type.

---

## 🟢 Efficiency Opportunities

### 12. Targeted Table Reloads

`FileTableView.updateNSView` calls `tableView.reloadData()` on every `invalidateSort()` — even for single-cell edits. For large collections, this is expensive.

**Recommendation:** Track which rows changed and use `reloadData(forRowIndexes:columnIndexes:)` for targeted updates.

### 13. Batch Size Documentation Mismatch

The code uses `metadataBatchSize = 200` but documentation repeatedly says "batches of 80". The actual value is fine — the docs are just stale. But consider making this configurable or at least documenting the actual value.

### 14. `runBackground` Could Be Reused

`FileListViewModel.runBackground` uses `Task.detached(priority: .userInitiated)`. The rename pipeline in `FileListViewModel+Rename.swift` uses `Task.detached(priority: .userInitiated)` directly instead of the helper. Consolidate for consistency.

---

## 🔵 Feature Opportunities

### 15. Right-Click Context Menu for Individual Extension Fix

The table currently only shows a ⚠️ icon with a tooltip. A right-click context menu on the filename column could offer "Fix Extension" for the individual file, complementing the bulk "Fix Selected" / "Fix All" buttons in the preview panel.

### 16. Filter / Sort by Mismatched Files

Add a sort key or filter toggle to show only files with mismatched extensions. This would help users quickly identify all problem files in a large collection.

### 17. "Select All Mismatched" Action

A button in the status bar or preview panel to select all files with mismatched extensions, making bulk fixing even faster.

### 18. Show Actual File Type in Table

Add a "Type" column (or extend the Camera column tooltip) to show the actual detected file type (e.g. "JPEG", "HEIC", "PNG") even when there's no mismatch. This gives users more visibility into their files.

### 19. Undo Support for Extension Fixes

Since extension fixes are simple renames, they could be trivially reversible. Consider keeping a list of `(oldURL, newURL)` pairs and offering an "Undo" action after a fix operation.

### 20. Use `UTType` for File Type Detection

The app currently uses hardcoded extension sets. macOS's `UniformTypeIdentifiers` framework provides `UTType(filenameExtension:)` which is more robust and future-proof. This would also handle case-insensitivity and aliases (e.g. `jpeg` vs `jpg`) automatically.

---

## 📋 Summary Priority List

| Priority | Item | Effort | Impact |
|---|---|---|---|
| 🔴 High | Fix stale documentation (17→19 tags, 80→200 batch) | Low | Prevents confusion |
| 🔴 High | Fix `dequeueTextCell` constraint leak | Low | Prevents Auto Layout bugs |
| 🔴 High | Move `isSanitising` with other flags | Low | Consistency |
| 🟡 Medium | Cache computed counts | Medium | Performance for large collections |
| 🟡 Medium | Move `imageExtensions` to service layer | Low | Single source of truth |
| 🟡 Medium | Split `FileListViewModel` into extensions | Medium | Maintainability |
| 🟡 Medium | Split `ExifToolService+ReadWrite` | Medium | Maintainability |
| 🟢 Low | Add context menu for individual fix | Low | UX improvement |
| 🟢 Low | Add filter/sort for mismatched files | Medium | UX improvement |
| 🟢 Low | Add undo for extension fixes | Low | Safety |
| 🟢 Low | Use `UTType` for detection | Medium | Robustness |