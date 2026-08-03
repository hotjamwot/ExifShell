# ExifShell Architecture

## Overview

ExifShell is a macOS application for inspecting and editing image metadata via ExifTool. It follows a simple **MVVM** pattern (Model-View-ViewModel) with a dedicated service layer for shelling out to ExifTool.

All state management uses Apple's `@Observable` macro (macOS 14+ Observation framework) instead of the older `ObservableObject` protocol — this gives automatic view invalidation and reliable `@Binding` support without boilerplate.

```
┌────────────────────────────────────────────────┐
│                    App (Scene)                  │
│               ExifShellApp.swift                │
└──────────────────┬─────────────────────────────┘
                   │
┌──────────────────▼─────────────────────────────┐
│                 ContentView                     │
│   (Root view, own drop handling, bulk edit     │
│    bars for date & description, status bar,     │
│    ⌘K/⌘S keyboard shortcuts)                   │
└──────┬───────────────────────────┬─────────────┘
       │                           │
┌──────▼──────────┐     ┌─────────▼───────────┐
│  FileTableView   │     │    PreviewPanel      │
│ (editable List   │     │ (Thumbnail + Diff   │
│  with multi-     │     │  for date & desc,   │
│  select support) │     │  read-only metadata,│
 │  – date column   │     │  Save/Rename/       │
 │  – desc column   │     │  Sanitise buttons)  │
└──────┬──────────┘     └─────────┬───────────┘
       │                          │
       └──────────┬───────────────┘
                  │ observes
       ┌──────────▼───────────────┐
       │   FileListViewModel      │
       │  @Observable class       │
       │  var files: [ImageFile]  │
       │  var selectedFile        │
       │  var selectedFiles: []   │  ← multi-select
       │  var bulkEditValue       │  ← bulk edit (date)
       │  clearAll()              │  ← ⌘K
       │  applyBulkEdit()         │  ← bulk set date / offset mode
       │  applyBulkOffset()       │  ← bulk offset date by hours/days/months
       │  applyBulkEditDesc()     │  ← bulk set desc
       │  saveAll()               │  ← saves date + desc
       │  saveSelected()          │  ← saves selected dirty files
       │  renameSelected()        │  ← renames selected files
       └──────────┬───────────────┘
                  │ calls
       ┌──────────▼───────────────┐
       │     ExifToolService       │  (core)
       │  readAllMetadata()       │  ← batch full read
       │  readDateTimeOriginal()  │  ← single or batch
       │  writeDateTimeOriginal() │  ← batch write date
       │  writeDescription()      │  ← batch write desc
       │  sanitise()              │  ← full sanitise pipeline
       │  + exifToolPath          │  ← auto-resolved
       │  + runReadTool/WriteTool │  ← shared process runners
       └──────────┬───────────────┘
                  │
       ┌──────────▼───────────────┐
       │  ExifToolService+Rename  │  (extension)
       │  renameFiles()           │  ← entry point
       │  renameWritableFiles()   │  ← ExifTool-based (tag pre-sorted)
       │  renameUnwritableFiles() │  ← FileManager-based (AVI/MPEG)
       │  detectTagCategories()   │  ← single read, classify files
       │  + RenameInput/Result    │  ← public types
       └──────────┬───────────────┘
                  │ spawns process
       ┌──────────▼───────────────┐
       │       exiftool CLI       │
       │  (external binary)       │
       └──────────────────────────┘
```

## Directory Structure

```
ExifShell/ExifShell/
├── ExifShellApp.swift          # @main app entry point, activation policy
├── ContentView.swift           # Root view: drop zone ↔ split pane + drop, bulk edit bars, status, shortcuts
├── Models/
│   └── ImageFile.swift         # @Observable class per image with dirty tracking for date & description
├── ViewModels/
│   ├── FileListViewModel.swift # @Observable class: state, import (batch full read), save, bulk edit, clear
│   ├── FileListViewModel+Rename.swift  # Rename extension: pre-sorted tag passes, FileManager-based rename for unwritable formats
│   └── FileListViewModel+ExtensionFix.swift  # Extension-fix: rename files whose suffix doesn't match actual content type
├── Services/
│   ├── ExifToolService.swift   # Core shell wrapper: read/write/sanitise, shared process runners, JSON decoders
│   └── ExifToolService+Rename.swift  # Rename extension: pre-sorted tag passes, FileManager-based rename for unwritable formats
└── Views/
    ├── DropZoneView.swift      # Visual drop zone (drop logic in ContentView)
    ├── FileTableView.swift     # NSTableView with editable columns + orange dirty + multi-select + hover highlight
    ├── PreviewPanel.swift      # Thumbnail + diff review (date & desc) + read-only metadata + Save/Rename/Sanitise buttons
    ├── QuickStatsBar.swift     # QuickStatsBar (file count pill) + StatusBarView (status bar wrapper)
    ├── BulkEditDateBar.swift   # Bulk edit bar for DateTimeOriginal (Set/Offset modes)
    └── BulkEditDescriptionBar.swift  # Bulk edit bar for Description
```

## Component Responsibilities

### ImageFile (Model)
- `@Observable` class (not struct) — SwiftUI observes changes automatically.
- Holds the file URL, filename, and an `NSImage` thumbnail.
- **Editable fields with dirty tracking:**
  - `dateTimeOriginal` — `didSet` compares against `originalDateTimeOriginal`, auto-flags `isDirty`.
  - `description` — `didSet` compares against `originalDescription`, auto-flags `isDirty`.
- **Read-only display fields:**
  - `createDate: String?` — EXIF CreateDate (not editable, for reference only).
  - `modifyDate: String?` — EXIF ModifyDate (not editable, for reference only).
  - `imageDescription: String?` — EXIF ImageDescription (display-only; synced from description on save).
  - `captionAbstract: String?` — IPTC Caption-Abstract (display-only; synced from description on save).
  - `fileModifyDate: String?` — Filesystem modification timestamp from ExifTool's `File:FileModifyDate`. Used as a last-resort fallback for files with no embedded date tags (e.g. MPG/MPEG).
  - `dateSource: ExifToolService.DateSource?` — Indicates which tag provided the `dateTimeOriginal` value (`.dateTimeOriginal`, `.createDate`, or `.fileModifyDate`). Used by PreviewPanel to show a source badge.
- `markClean()` resets both baselines (originalDateTimeOriginal & originalDescription) and clears the dirty flag.
- Identifiable (UUID) and Hashable for List selection.

### ExifToolService (Service Layer — Core)
- **Path resolution:** Locates `exiftool` at static init time by checking common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/local/bin`) and falling back to `which exiftool`. This ensures the app works from Terminal, Xcode, or a bundled `.app` regardless of PATH.
- **Read (full batch):** `readAllMetadata(from:)` — calls `exiftool -json -DateTimeOriginal -QuickTime:CreationDate -CreateDate -ModifyDate -FileModifyDate -Description -ImageDescription -Caption-Abstract -Subject -Keywords -LastKeywordXMP -Duration -ImageWidth -ImageHeight -Make -Model -FileType -FileTypeExtension <files...>` once for all files, decodes JSON, returns `[URL: FileMetadata]`. The `FileMetadata` struct includes a `dateSource: DateSource?` field that tracks whether `dateTimeOriginal` came from the embedded tag, `CreateDate`, or the filesystem `FileModifyDate`.
- **Read (date only batch):** `readDateTimeOriginal(from:)` — legacy method, same pattern but only reads DateTimeOriginal.
- **Write (date):** Splits images/videos via `splitByMediaType`. Images get `-EXIF:DateTimeOriginal=`, `-CreateDate=`, `-ModifyDate=`, and cleared offset tags. QuickTime videos get `-QuickTime:CreationDate=`, `-CreateDate=`, `-ModifyDate=`, `-DateTimeOriginal=`. Other videos get generic `-DateTimeOriginal=`, `-CreateDate=`, `-ModifyDate=`.
- **Write (description):** Calls `exiftool -overwrite_original -Description="<value>" -ImageDescription="<value>" -Caption-Abstract="<value>" <files...>` for images. Videos only get `-Description=`.
- **Sanitise:** Normalises date formats via `DateFmt`, propagates across all date tags, clears offset tags (images), syncs descriptions. Operates per media type in a single ExifTool invocation.
- **Shared infrastructure:** `runReadTool` / `runWriteTool` centralise Process boilerplate. `ReadResult`, `WriteResult` structs for return values. `decoder`, `missingToolError`, `exifToolPath` are all `internal` (default) — accessible across files within the module (needed by the rename extension).
- **JSON decoding:** `DateTimeFallbackOutput` (public, for rename extension) and `FullExifToolOutput` (private, full metadata read) decode ExifTool's JSON output.
- **Media type helpers:** `videoExtensions`, `quickTimeExtensions`, `unwritableVideoExtensions`, `splitByMediaType`, `isUnwritableVideo`.

### ExifToolService+Rename (Service Layer — Rename Extension)
- All rename logic lives in `extension ExifToolService` in a separate file.
- **`renameFiles(_ inputs:, progressHandler:)`** — public entry point. Accepts `[RenameInput]` (URL + in-memory dateTimeOriginal + description). Splits into writable (ExifTool) vs unwritable (FileManager for AVI/MPEG) paths.
- **`detectTagCategories()`** — runs a single ExifTool read to classify files by which date tag they have (`CreateDate`, `DateTimeOriginal`, or `FileModifyDate`). This pre-sort eliminates blind passes.
- **`renameWritableFiles()`** — ExifTool-based rename. Only dispatches ExifTool passes for tag categories that actually exist in the batch. Each pass runs `-v -m "-FileName<${TAG}_%03.c{Description;...}.%e" -d fmt`. Path mappings are extracted from `-v` output via regex and validated against the filesystem. Fallback `computeExpectedRenameURL()` handles files the regex missed.
- **`renameUnwritableFiles()`** — FileManager-based rename for AVI/MPEG. Generates target filenames in Swift from in-memory metadata, handles collisions with counter incrementing.
- **Public types:** `RenameResult` (success + output + path mapping), `RenameInput` (url + dateTimeOriginal + description).
- **Formatters:** `renameInputFormatter`, `renameOutputFormatter`, `formatDateForRename()`, `sanitizeDescriptionForRename()`.

### FileListViewModel (ViewModel)
- `@Observable` class with `@MainActor`.
- `var files: [ImageFile]` — the source of truth for the file list.
- `var selectedFile: ImageFile?` — `didSet` triggers `clearFeedback()`, which clears save confirmation and status when navigating to a different file.
- `var selectedFiles: [ImageFile]` — holds multi-selection for bulk edit.
- `var bulkEditValue: String` — the text field value from the DateTimeOriginal bulk edit bar.
- `var bulkEditDescriptionValue: String` — the text field value from the Description bulk edit bar (separate from the date value).
- `lastSaveFeedback: SaveFeedback?` — holds the most recent DateTimeOriginal save result.
- `lastDescriptionSaveFeedback: SaveFeedback?` — holds the most recent Description save result.
- `importFiles(_:)` / `importFolder(_:)` — validates image types via extension check, deduplicates by URL, batch-reads full metadata via `ExifToolService.readAllMetadata(from:)` in chunks of 200 files with live determinate progress, populates all fields including createDate, modifyDate, description, imageDescription, captionAbstract.
- `clearAll()` — removes all files and resets state (⌘K shortcut).
- `applyBulkEdit()` — sets `dateTimeOriginal` on all `selectedFiles` to `bulkEditValue`.
- `applyBulkEditDescription()` — sets `description` on all `selectedFiles` to `bulkEditValue`.
- `saveAll()` — the single save method:
  1. Separately identifies files with date changes vs description changes.
  2. Groups dirty date files by value → `writeDateTimeOriginal()` per group.
  3. Groups dirty description files by value → `writeDescription()` per group.
  4. Only marks a file clean if ALL its field writes succeeded.
  5. Updates independent feedback for date and description saves.
- `sanitiseSelected()` — operates on the **currently selected files** (`selectedFiles`). Saves dirty files first, then runs a **Phase 1 pre-write** for files whose `dateSource == .fileModifyDate` (these have no embedded date tag on disk, so the main sanitise pipeline would silently do nothing). The pre-write writes each file's own in-memory date value (timezone stripped) to a proper `DateTimeOriginal`/`QuickTime:CreationDate` tag, then the main pipeline processes files in **batches of 200** with live determinate progress (`"Sanitising (X/Y)..."`), skips unwritable formats (AVI, MPEG) with a warning, then re-reads all metadata from disk to refresh the display.
- `sanitiseAll()` — runs the same sanitise pipeline for all loaded files, not just selected files.
- `renameAll()` — saves dirty files first, then processes files in **batches of 200** with live determinate progress (`"Renaming (X/Y)..."`), calls `ExifToolService.renameFiles()` with the in-memory metadata content, updates the in-memory URL for each renamed file from the returned path mapping.

### DropZoneView
- Purely visual. Shows the empty-state icon and instructions when no files are loaded.
- All drag-and-drop handling is at the `ContentView` level so it works in all states.

### QuickStatsBar & StatusBarView
- **QuickStatsBar**: A compact capsule pill showing total file count, image count (📷), video count (🎬), an animated orange dirty count pill, and an orange "N mismatch" pill when files with mismatched extensions are loaded. The dirty/mismatch pills spring in/out as counts change and use `.contentTransition(.numericText())` for smooth number animations.
- **StatusBarView**: The status bar at the bottom of the left pane. Wraps QuickStatsBar + operation/status messages + error copy button + progress indicator (determinate or indeterminate). Extracted from ContentView into its own view to reduce SwiftUI view-body complexity for the Swift type-checker.

### FileTableView
- Wraps an `NSTableView` via `NSViewRepresentable` for native column resizing, scroll, and sort indicators.
- Uses `Set<ImageFile.ID>` for `selection`, enabling multi-select via ⌘+click.
- Body reads `viewModel.sortedFiles` as an observation dependency — this causes SwiftUI to re-invoke `updateNSView` → `tableView.reloadData()` whenever `invalidateSort()` is called (on any data mutation, including bulk edits).
- **Sortable headers:** Filename, DateTimeOriginal, Description, and Camera columns are clickable with native sort indicator arrows. Sort state syncs to `viewModel.sortKey` / `viewModel.sortAscending`.
- **Orange text:** Editable cells use `.textColor = dirty ? .orange : .labelColor` to visually indicate unsaved changes.
- **Four columns:** Filename (read-only) | DateTimeOriginal (editable) | Description (editable) | Camera (read-only, model name with Make+Model tooltip).
- **Extension mismatch indicator:** A ⚠️ icon appears at the trailing edge of the Filename column when a file's actual content type (detected by ExifTool) doesn't match its filename suffix (e.g. JPEG with `.heic` suffix). Tooltip explains the mismatch.
- **Hover highlight:** Uses a custom `HoverableTableRowView` (NSTableRowView subclass) with NSTrackingArea to draw a subtle background highlight on mouse hover (non-selected rows only).
- Selection syncs to both `viewModel.selectedFile` (preview) and `viewModel.selectedFiles` (bulk edit).
- Cells are dequeued/recycled using `NSTableView.makeView(withIdentifier:owner:)` for performance.

### PreviewPanel
- Wrapped in `ScrollView` to accommodate all metadata.
- Shows thumbnail (loaded via `NSImage(contentsOf:)`).
- **Extension Mismatch banner:** When the selected file's actual content type doesn't match its filename suffix, an orange banner appears above the editable fields with a description and "Fix Selected" / "Fix All" buttons.
- **Editable Fields section:**
  - DateTimeOriginal diff view when dirty (grey strikethrough → green bold). When a `dateSource` is available, an orange source badge is shown next to the label: "EXIF" for embedded dates, "CreateDate" for CreateDate fallback, or "File System" for filesystem dates.
  - Description diff view when dirty (grey strikethrough → green bold).
- **Read-Only Metadata section:**
  - Create Date (from `CreateDate` EXIF tag).
  - Modify Date (from `ModifyDate` EXIF tag).
  - File Modify Date (from `File:FileModifyDate`) — only shown when it's not already used as the dateTimeOriginal source (to avoid duplication).
  - ImageDescription (from `ImageDescription` EXIF tag).
  - Caption-Abstract (from `Caption-Abstract` IPTC tag).
  - Subject (from `Subject`, joined into a string when present).
- Shows a selection summary when multiple files are selected, and copy actions use each selected file's own source date.
- **Save feedback:** Two independent badges — "DTO: old → new" for date changes and "Desc: old → new" for description changes. Both clear on navigation.
- **Action buttons** in a 2-column layout:
  - Row 1: "Save Selected (N)" (bordered) | "Save All (N)" (prominent/blue, `⌘S`)
  - Row 2: "Rename Selected" (bordered) | "Rename All" (prominent/blue)
  - Row 3: "Sanitise Selected" (full width, bordered)
 - "Selected" buttons only appear when files are selected. Disabled when no dirty files (for save) or no selection.

### ContentView (Root)
- Manages the empty state (DropZoneView) vs loaded state (HSplitView with table + preview).
- **Two bulk edit bars** (visible when `viewModel.selectedFiles.count > 1`):
  1. **DateTimeOriginal bar** (accent-tinted): text field + "Apply" button for bulk date editing.
  2. **Description bar** (green-tinted): text field + "Apply" button for bulk description editing.
- **Status bar:** Delegated to `StatusBarView` (in `QuickStatsBar.swift`), which shows the QuickStatsBar pill, operation/status messages, error copy button, and a `ProgressView` when loading/saving.
- **Drop handling:** `onDrop(of:)` resolves URLs, separates files from folders, and calls the ViewModel.
- **App-wide keyboard shortcuts:** Hidden `.background(Button(...).keyboardShortcut(...))` modifiers:
  - `⌘K` → `viewModel.clearAll()`
  - `⌘S` → `viewModel.saveAll()`
  - `⌫ Delete` → `viewModel.removeSelected()`

## Data Flow

1. **Import:** User drops files → `ContentView.onDrop` resolves URLs → ViewModel filters by extension, deduplicates, immediately appends placeholder `ImageFile` entries to the list → reads metadata in batches of 200 via `loadMetadata(for:)` → updates `operationProgress` and `operationMessage` after each batch → populates all fields including date, description, create/modify/file-modify dates, imageDescription, captionAbstract, subject. For files with no embedded date tags (MPG/MPEG), `dateTimeOriginal` is populated from the filesystem `FileModifyDate` as a last resort, with `dateSource` set to `.fileModifyDate`.
2. **Edit (single):** User clicks into the DateTimeOriginal or Description `TextField` → edits value → binding writes to the `@Observable` model → `didSet` on the respective field marks file dirty → UI auto-updates.
3. **Edit (bulk):** User selects multiple files (⌘+click) → bulk edit bars appear → types a value → presses Enter or "Apply" → `applyBulkEdit()` or `applyBulkEditDescription()` sets value on selected files, which calls `invalidateSort()` to trigger a table refresh.
4. **Review:** Preview panel shows grey (original) → green (proposed) diff for both date and description. Read-only metadata displayed below.
5. **Save:** User presses `⌘S` → ViewModel groups dirty files by unique values for each field → `writeDateTimeOriginal()` called per date group, `writeDescription()` called per description group → on all-success, `markClean()` resets each file.
6. **Clear:** User presses `⌘K` → `clearAll()` removes all files, returns to drop zone.

## Key Design Decisions

### Batch Reads
ExifTool can process multiple files in a single invocation. The service layer accepts `[URL]` for both reads and writes, reducing process spawn overhead dramatically. Metadata is loaded in chunks of 200 files so rows appear immediately and the UI can track determinate progress as each batch completes.

### ExifTool Path Resolution
The app does not rely on PATH propagation (which breaks in Xcode). Instead it checks common Homebrew/MacPorts install paths at startup and falls back to `which`.

### Multi-Select & Bulk Edit
The file table uses SwiftUI `List` with `Set<ImageFile.ID>` selection. The ViewModel tracks both `selectedFile` (for preview) and `selectedFiles` (for bulk edit). Two bulk edit bars appear in ContentView when 2+ files are selected — one for date, one for description.

### Dirty State Pattern
Editing either field marks a file dirty — nothing is written to disk until the user explicitly saves. This prevents accidental overwrites.

### Description Writes All Description Tags
When the user edits the Description field and saves, ExifShell writes the same value to `Description`, `ImageDescription`, and `Caption-Abstract`. This ensures consistency across EXIF/IPTC/XMP description fields.

### No Local Image Database
Images are loaded from their original paths. No caching, no library management. The user's filesystem is the source of truth.

### ExifTool Only
All metadata operations are delegated to `exiftool`. The app never interprets or transforms date strings — it passes them through exactly as entered.

### @Observable over ObservableObject
Using the `@Observable` macro (macOS 14+) instead of `@Published`/`ObservableObject` avoids the "field jumps back on enter" bug that plagues struct-based bindings in SwiftUI `List`/`Table` views. Reference types with `@Observable` give rock-solid two-way bindings.

### Explicit EXIF Tag Targeting
Date write commands use `-EXIF:DateTimeOriginal=` rather than `-DateTimeOriginal=`. This prevents ExifTool from writing to related fields (CreateDate, ModifyDate, IPTC date/time fields) when it auto-derives them from the tag name.

### Rename Pre-Sort Optimisation
Instead of running 3 blind ExifTool passes (filtered by `-if`), `detectTagCategories()` runs a single ExifTool read to classify files by which date tag they have. Then only the needed passes are dispatched. For the common case (all files have CreateDate), this reduces 3 ExifTool launches to 1.

### Rename Path Mapping with Filesystem Validation
ExifTool's `-v` output is parsed via regex, and each claimed new path is validated with `FileManager.default.fileExists(atPath:)` to discard false positives. For files the regex misses, `computeExpectedRenameURL()` uses in-memory metadata + per-directory counter as a fallback.

### FileManager-based Rename for Unwritable Formats
AVI and MPEG files cannot be written to by ExifTool. The rename pipeline detects these via `isUnwritableVideo()` and renames them via `FileManager.moveItem()` using in-memory metadata (saved-in-progress DateTimeOriginal and Description values).

## Dependencies

- **Swift 5.9+ / macOS 14+** — `@Observable`, SwiftUI `List`, `Hashable`.
- **ExifTool** — Must be installed. Not bundled with the app.

## Build & Run

```bash
xcodebuild -project ExifShell.xcodeproj -scheme ExifShell build
```

Or open `ExifShell.xcodeproj` in Xcode and run.

## Keyboard Shortcuts

| Shortcut | Scope | Action |
|----------|-------|--------|
| `⌘S` | App-wide | Save all dirty files |
| `⌘K` | App-wide | Clear all files / drop zone |
| `⌘+click` | Table | Toggle multi-select |
| `⌫ Delete` | App-wide | Remove selected files from list |
| `Return` | Bulk edit bar | Apply bulk edit value |

## Sanitise Pipeline

The "Sanitise Selected" button in the Preview Panel runs an ExifTool invocation that normalises date formats, propagates dates across all date tags, clears offset time tags (images), and syncs descriptions.

### What it fixes

Files with XMP-style ISO 8601 dates (e.g. `2010-03-27T01:40:19+00:00`) cannot be parsed by the app's `exifDateFormatter` (`yyyy:MM:dd HH:mm:ss`), causing the Offset feature to silently skip them. Sanitise reformats these to proper EXIF/QuickTime format.

### Operations per media type

**Images:**
1. **Normalises DateTimeOriginal** — reformats to `%Y:%m:%d %H:%M:%S` via `DateFmt`
2. **Propagates date** — copies DateTimeOriginal → CreateDate, ModifyDate
3. **Clears offsets** — removes OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
4. **Syncs descriptions** — copies Description → ImageDescription, Caption-Abstract

**QuickTime Videos (MP4/MOV/M4V):**
1. **Normalises QuickTime:CreationDate** — reformats to `%Y:%m:%d %H:%M:%S` via `DateFmt`
2. **Propagates date** — copies QuickTime:CreationDate → CreateDate, ModifyDate
3. **Syncs descriptions** — copies Description (no offset tags — not applicable)

**Other Videos (AVI, MKV, etc.):**
1. **Normalises DateTimeOriginal** — reformats to `%Y:%m:%d %H:%M:%S` via `DateFmt`
2. **Propagates date** — copies DateTimeOriginal → CreateDate, ModifyDate
3. **Syncs descriptions** — copies Description

### ExifTool Commands

**Images:**
```bash
exiftool -overwrite_original \
  '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' \
  '-CreateDate<DateTimeOriginal' \
  '-ModifyDate<DateTimeOriginal' \
  -OffsetTime= \
  -OffsetTimeOriginal= \
  -OffsetTimeDigitized= \
  '-ImageDescription<Description' \
  '-Caption-Abstract<Description'
```

**QuickTime Videos:**
```bash
exiftool -overwrite_original \
  '-QuickTime:CreationDate<${QuickTime:CreationDate;DateFmt("%Y:%m:%d %H:%M:%S")}' \
  '-CreateDate<QuickTime:CreationDate' \
  '-ModifyDate<QuickTime:CreationDate'
```

**Other Videos:**
```bash
exiftool -overwrite_original \
  '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' \
  '-CreateDate<DateTimeOriginal' \
  '-ModifyDate<DateTimeOriginal'
```

This is exposed via `ExifToolService.sanitise(_ urls:)` and triggered by `FileListViewModel.sanitiseSelected()`. The "Sanitise Selected" button appears in the PreviewPanel alongside Save and Rename buttons.

## Delete / Remove Files

Select one or more files (⌘+click for multi-select) and press `⌫ Delete` to remove them from the working list. The shortcut is bound app-wide in `ContentView.swift` via a hidden button, calling `FileListViewModel.removeSelected()`.