# ExifShell — Change Log

Brief, concise record of changes made to ExifShell. Append a few lines at the end of each session.

Format:
```
## [YYYY-MM-DD] — Session Title
### Added
- ...
### Fixed
- ...
### Changed
- ...
```

---

## [2026-08-14] — DTO Fix: Strip Fractional Seconds

### Fixed
- `ExifToolService.normalizeToExifDateForFix` (new): Strips fractional seconds (e.g. `2024:09:28 17:08:43.93` → `2024:09:28 17:08:43`). iPhone/camera EXIF dates often include milliseconds after the seconds, which previously caused the "Fix DTO" action to report "skipped — could not be normalised" because the cleaned value was identical to the original.
- `ImageFile.cleanedDateTimeOriginal`: Now uses `normalizeToExifDateForFix` so fractional seconds are stripped ONLY when the user explicitly runs the "Fix DTO" action — never silently on import. The read path (`normalizeToExifDate`) intentionally preserves fractional seconds so the ⚠️ flag still appears and the user reviews the change before saving.

### Changed
- `ImageFile.dateFixDescription`: Now mentions that the expected format is `YYYY:MM:DD HH:MM:SS` with no milliseconds or timezone offset, making the error message clearer for users.

---

## [2026-03-08] — Code Review Implementation

### Added
- `FileTableView`: New "Type" column showing the actual detected file type (e.g. JPEG, HEIC, PNG), orange when the filename suffix doesn't match.
- `FileTableView`: Right-click context menu with "Fix Extension" (for mismatched files) and "Sort by Mismatched".
- `FileListViewModel`: New `.mismatched` sort key — sorts mismatched files to the top/bottom.
- `FileListViewModel`: `selectAllMismatched()` — selects all files with mismatched extensions.
- `FileListViewModel`: `selectAllMismatched()` wired to a clickable mismatch pill in `QuickStatsBar`.
- `FileListViewModel`: Undo support for extension fixes — `lastExtensionFixUndo`, `canUndoExtensionFix`, `undoExtensionFix()`.
- `PreviewPanel`: "Undo" button in the mismatch banner when an extension fix can be reverted.
- `PreviewPanel`: Confirmation dialog for "Fix All" (`showFixAllConfirmation` + `.alert`).
- `ExifToolService`: `imageExtensions` set, `isSupportedFile(_:)`, and `mediaType(for:)` — single source of truth for media type detection.

### Fixed
- `FileTableView`: Fragile warning-label management in `dequeueTextCell` — replaced with dedicated `FilenameCellView` using pre-built warning label + pre-allocated constraint references (no more subview scavenging or Auto Layout constraint leaks).
- `FileListViewModel`: `imageCount`, `videoCount`, `dirtyCount`, `mismatchedCount` were O(n) on every body evaluation — now cached via `_cachedStats`/`_statsVersion` with single-pass `recomputeStats()`.
- `FileListViewModel`: `isSanitising` moved up with the other operation flags.
- `FileListViewModel`: `clearAll()` now calls `clearFeedback()` first to prevent state drift.
- `FileListViewModel+Rename`: direct `Task.detached` replaced with shared `runBackground` helper.
- `ARCHITECTURE.md`: Stale "batches of 80" references updated to 200; read command now lists all actual tags.

### Changed
- `ExifToolService+Extensions.swift`: `let s` replaces `var s` in `normalizeToExifDate` (warning fix).
- `FileListViewModel.swift`: Removed private `imageExtensions` set and `mediaType`/`isSupportedFile` methods — now delegates to `ExifToolService`.
- `PreviewPanel`: `viewModel` is now `@Bindable` (was `let`) to support the `$viewModel.showFixAllConfirmation` binding.
- `CODE_REVIEW.md`: Rewritten as a status tracker — 15/20 items completed, 5 open items documented for future refactor passes.

---

## [2026-08-13] — Pipe-Draining Deadlock Fix & Preview Panel Width

### Fixed
- `ExifToolService`: `runReadTool`/`runWriteTool` deadlocked on large batches (100+ files). `waitUntilExit()` was called before reading stdout/stderr, so when output exceeded the ~64KB pipe buffer the child blocked on `write()` and never exited — the app appeared to hang and required a force-quit. Both runners now drain stdout/stderr on background queues via `DispatchGroup` while waiting for exit.

### Changed
- `ContentView`: Preview Panel now opens at its minimum width (~1/3) instead of the default 50/50 split — set `idealWidth` on the table pane (600) and preview pane (300) in the `HSplitView`.

---

## [2026-08-13] — Fix Date/Time Format (DTO) Feature

### Added
- `ImageFile`: `dateNeedsFix` — flags a DateTimeOriginal that isn't in EXIF `YYYY:MM:DD HH:MM:SS` format (e.g. ISO 8601 or trailing timezone); `cleanedDateTimeOriginal` returns the normalised value; `dateFixDescription` explains the issue.
- `FileListViewModel+DTOFix` (new): `fixDTOSelected()` / `fixDTOAll()` — dirty-save normalisation of the in-memory `dateTimeOriginal` (no immediate disk write; user reviews the diff and commits via Save). `selectAllNeedsDTOFix()` selects all invalid-date files.
- `PreviewPanel`: "Invalid Date Format" banner (mirrors the Extension Mismatch banner) with "Fix Selected (N)" / "Fix All (N)" buttons and a caption explaining the dirty-save flow.
- `FileTableView`: ⚠️ prefix + orange styling on the Date column for invalid dates, tooltip "Invalid date format — use the Fix Date/Time action in the preview to correct", and a "Fix Date/Time Format" context-menu item.
- `QuickStatsBar`: "invalid date" count pill (calendar.badge.exclamationmark) that selects all invalid-date files; `isFixingDTO` shown in the status bar.
- `FileStats`: `dtoFixCount` cached in `recomputeStats()`.

### Changed
- `ExifToolService+ReadWrite`: `writeDateTimeOriginal` now clears stray `XMP:DateTimeOriginal` and `IPTC:DateTimeOriginal` tags so the corrected EXIF value isn't shadowed on re-read.
- `FileListViewModel`: `dtoFixCount` computed property lives in the main class (accesses private `_statsVersion`/`_cachedStats`).
