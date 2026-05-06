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
│  – date column   │     │  single Save btn)   │
│  – desc column   │     │                     │
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
       └──────────┬───────────────┘
                  │ calls
       ┌──────────▼───────────────┐
       │     ExifToolService       │
       │  readAllMetadata()       │  ← batch full read
       │  readDateTimeOriginal()  │  ← single or batch
       │  writeDateTimeOriginal() │  ← batch write date
       │  writeDescription()      │  ← batch write desc
       │  + exifToolPath          │  ← auto-resolved
       └──────────┬───────────────┘
                  │ spawns process
       ┌──────────▼───────────────┐
       │       exiftool CLI       │
       │  (external binary)       │
       └──────────────────────────┘
```

## Directory Structure

```
Sources/
├── ExifShellApp.swift          # @main app entry point, activation policy
├── ContentView.swift           # Root view: drop zone ↔ split pane + drop, bulk edit bars, status, shortcuts
├── Models/
│   └── ImageFile.swift         # @Observable class per image with dirty tracking for date & description
├── ViewModels/
│   └── FileListViewModel.swift # @Observable class: state, import (batch full read), save, bulk edit, clear
├── Services/
│   └── ExifToolService.swift   # Shell wrapper (auto-resolved path, batch reads & writes for date + desc)
└── Views/
    ├── DropZoneView.swift      # Visual drop zone (drop logic in ContentView)
    ├── FileTableView.swift     # List with editable DateTimeOriginal + Description + orange dirty + multi-select
    └── PreviewPanel.swift      # Thumbnail + diff review (date & desc) + read-only metadata + single Save button
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
- `markClean()` resets both baselines (originalDateTimeOriginal & originalDescription) and clears the dirty flag.
- Identifiable (UUID) and Hashable for List selection.

### ExifToolService (Service Layer)
- **Path resolution:** Locates `exiftool` at static init time by checking common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/local/bin`) and falling back to `which exiftool`. This ensures the app works from Terminal, Xcode, or a bundled `.app` regardless of PATH.
- **Read (full batch):** `readAllMetadata(from:)` — calls `exiftool -json -DateTimeOriginal -CreateDate -ModifyDate -Description -ImageDescription -Caption-Abstract <files...>` once for all files, decodes JSON, returns `[URL: FileMetadata]`.
- **Read (date only batch):** `readDateTimeOriginal(from:)` — legacy method, same pattern but only reads DateTimeOriginal.
- **Write (date):** Calls `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <file1> <file2> ...` — uses the `EXIF:` group specifier to target the correct EXIF tag.
- **Write (description):** Calls `exiftool -overwrite_original -Description="<value>" -ImageDescription="<value>" -Caption-Abstract="<value>" <files...>` — writes the same value to all three description-related tags in one call.
- Supports batch writes: accepts `[URL]` so multiple files with the same value are sent in a single process invocation.
- Returns a `WriteResult` struct with `success: Bool` and `output: String` (captured stdout/stderr for error reporting).
- All metadata logic is delegated to ExifTool.

### FileListViewModel (ViewModel)
- `@Observable` class with `@MainActor`.
- `var files: [ImageFile]` — the source of truth for the file list.
- `var selectedFile: ImageFile?` — `didSet` triggers `clearFeedback()`, which clears save confirmation and status when navigating to a different file.
- `var selectedFiles: [ImageFile]` — holds multi-selection for bulk edit.
- `var bulkEditValue: String` — the text field value from the bulk edit bars (shared for date & description).
- `lastSaveFeedback: SaveFeedback?` — holds the most recent DateTimeOriginal save result.
- `lastDescriptionSaveFeedback: SaveFeedback?` — holds the most recent Description save result.
- `importFiles(_:)` / `importFolder(_:)` — validates image types via extension check, deduplicates by URL, batch-reads full metadata via `ExifToolService.readAllMetadata(from:)`, populates all fields including createDate, modifyDate, description, imageDescription, captionAbstract.
- `clearAll()` — removes all files and resets state (⌘K shortcut).
- `applyBulkEdit()` — sets `dateTimeOriginal` on all `selectedFiles` to `bulkEditValue`.
- `applyBulkEditDescription()` — sets `description` on all `selectedFiles` to `bulkEditValue`.
- `saveAll()` — the single save method:
  1. Separately identifies files with date changes vs description changes.
  2. Groups dirty date files by value → `writeDateTimeOriginal()` per group.
  3. Groups dirty description files by value → `writeDescription()` per group.
  4. Only marks a file clean if ALL its field writes succeeded.
  5. Updates independent feedback for date and description saves.
- `dirtyCount: Int` — computed property for button label and feedback.

### DropZoneView
- Purely visual. Shows the empty-state icon and instructions when no files are loaded.
- All drag-and-drop handling is at the `ContentView` level so it works in all states.

### FileTableView
- SwiftUI `List` (not `Table` — `List` gives reliable bindings with `@Observable`).
- Uses `Set<ImageFile.ID>` for `selection`, enabling multi-select via ⌘+click.
- Uses `@Bindable` to create a `$binding` for each file's `dateTimeOriginal` and `description`.
- **Orange text:** Both the DateTimeOriginal and Description `TextField` use `.foregroundColor(isDirty ? .orange : .primary)` to clearly indicate unsaved changes.
- **Three columns:** Filename | DateTimeOriginal (editable) | Description (editable).
- Selection syncs to both `viewModel.selectedFile` (preview) and `viewModel.selectedFiles` (bulk edit) via `onChange(of: selectedIDs)`.

### PreviewPanel
- Wrapped in `ScrollView` to accommodate all metadata.
- Shows thumbnail (loaded via `NSImage(contentsOf:)`).
- **Editable Fields section:**
  - DateTimeOriginal diff view when dirty (grey strikethrough → green bold).
  - Description diff view when dirty (grey strikethrough → green bold).
- **Read-Only Metadata section:**
  - Create Date (from `CreateDate` EXIF tag).
  - Modify Date (from `ModifyDate` EXIF tag).
  - ImageDescription (from `ImageDescription` EXIF tag).
  - Caption-Abstract (from `Caption-Abstract` IPTC tag).
- **Save feedback:** Two independent badges — "DTO: old → new" for date changes and "Desc: old → new" for description changes. Both clear on navigation.
- **Single Save button:** One button labelled "Save Changes (N)" showing the dirty count. Disabled when nothing is dirty. Keyboard shortcut: `⌘S`.

### ContentView (Root)
- Manages the empty state (DropZoneView) vs loaded state (HSplitView with table + preview).
- **Two bulk edit bars** (visible when `viewModel.selectedFiles.count > 1`):
  1. **DateTimeOriginal bar** (accent-tinted): text field + "Apply" button for bulk date editing.
  2. **Description bar** (green-tinted): text field + "Apply" button for bulk description editing.
- **Status bar:** Shows the current `statusMessage` and a `ProgressView` when loading.
- **Drop handling:** `onDrop(of:)` resolves URLs, separates files from folders, and calls the ViewModel.
- **App-wide keyboard shortcuts:** Two hidden `.background(Button(...).keyboardShortcut(...))` modifiers:
  - `⌘K` → `viewModel.clearAll()`
  - `⌘S` → `viewModel.saveAll()`

## Data Flow

1. **Import:** User drops files → `ContentView.onDrop` resolves URLs → ViewModel filters by extension, deduplicates, batch-reads full metadata via `ExifToolService.readAllMetadata(from:)` (single process call) → populates all fields including date, description, create/modify dates, imageDescription, captionAbstract.
2. **Edit (single):** User clicks into the DateTimeOriginal or Description `TextField` → edits value → binding writes to the `@Observable` model → `didSet` on the respective field marks file dirty → UI auto-updates.
3. **Edit (bulk):** User selects multiple files (⌘+click) → bulk edit bars appear → types a value → presses Enter or "Apply" → `applyBulkEdit()` or `applyBulkEditDescription()` sets value on selected files.
4. **Review:** Preview panel shows grey (original) → green (proposed) diff for both date and description. Read-only metadata displayed below.
5. **Save:** User presses `⌘S` → ViewModel groups dirty files by unique values for each field → `writeDateTimeOriginal()` called per date group, `writeDescription()` called per description group → on all-success, `markClean()` resets each file.
6. **Clear:** User presses `⌘K` → `clearAll()` removes all files, returns to drop zone.

## Key Design Decisions

### Batch Reads
ExifTool can process multiple files in a single invocation. The service layer accepts `[URL]` for both reads and writes, reducing process spawn overhead dramatically. The full metadata read fetches 6 tags in one pass.

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

## Dependencies

- **Swift 5.9+ / macOS 14+** — `@Observable`, SwiftUI `List`, `Hashable`.
- **ExifTool** — Must be installed. Not bundled with the app.

## Build & Run

```bash
swift run
```

Or open `Package.swift` in Xcode and run.

## Keyboard Shortcuts

| Shortcut | Scope | Action |
|----------|-------|--------|
| `⌘S` | App-wide | Save all dirty files |
| `⌘K` | App-wide | Clear all files / drop zone |
| `⌘+click` | Table | Toggle multi-select |
| `⌫ Delete` | App-wide | Remove selected files from list |
| `Return` | Bulk edit bar | Apply bulk edit value |

## Sanitise Pipeline

The "Sanitise All" button in the Preview Panel runs a single ExifTool invocation that:

1. **Normalises DateTimeOriginal** — reformats to `%Y:%m:%d %H:%M:%S` via `DateFmt`
2. **Propagates date** — copies DateTimeOriginal → CreateDate, ModifyDate
3. **Clears offsets** — removes OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
4. **Syncs descriptions** — copies Description → ImageDescription, Caption-Abstract

After the sanitise completes, the ViewModel re-reads all metadata from disk so the display is fully refreshed. Dirty state is cleared since the writes went directly to disk.

### ExifTool Command

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

This is exposed via `ExifToolService.sanitise(_ urls:)` and triggered by `FileListViewModel.sanitiseAll()`.

## Delete / Remove Files

Select one or more files (⌘+click for multi-select) and press `⌫ Delete` to remove them from the working list. The shortcut is bound app-wide in `ContentView.swift` via a hidden button, calling `FileListViewModel.removeSelected()`.
