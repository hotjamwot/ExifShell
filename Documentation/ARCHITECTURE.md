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
│    bar, status bar, ⌘K/⌘S keyboard shortcuts)  │
└──────┬───────────────────────────┬─────────────┘
       │                           │
┌──────▼──────────┐     ┌─────────▼───────────┐
│  FileTableView   │     │    PreviewPanel      │
│ (editable List   │     │ (Thumbnail + Diff,  │
│  with multi-     │     │  single Save btn)   │
│  select support) │     │                     │
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
       │  var bulkEditValue       │  ← bulk edit
       │  clearAll()              │  ← ⌘K
       │  applyBulkEdit()         │  ← multi-file set
       └──────────┬───────────────┘
                  │ calls
       ┌──────────▼───────────────┐
       │     ExifToolService       │
       │  readDateTimeOriginal()  │  ← single or batch
       │  writeDateTimeOriginal() │
       │  + batch read (from:)    │  ← [URL] → [URL: String?]
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
├── ContentView.swift           # Root view: drop zone ↔ split pane + drop, bulk edit, status, shortcuts
├── Models/
│   └── ImageFile.swift         # @Observable class per image with dirty tracking
├── ViewModels/
│   └── FileListViewModel.swift # @Observable class: state, import (batch read), save, bulk edit, clear
├── Services/
│   └── ExifToolService.swift   # Shell wrapper (auto-resolved path, batch reads & writes)
└── Views/
    ├── DropZoneView.swift      # Visual drop zone (drop logic in ContentView)
    ├── FileTableView.swift     # List with editable DateTimeOriginal + orange dirty + multi-select
    └── PreviewPanel.swift      # Thumbnail + diff review + single Save button
```

## Component Responsibilities

### ImageFile (Model)
- `@Observable` class (not struct) — SwiftUI observes changes automatically.
- Holds the file URL, filename, current `dateTimeOriginal` string, and an `NSImage` thumbnail.
- Tracks `isDirty` state — when `dateTimeOriginal` is modified via `didSet`, `isDirty` auto-flags to `true`.
- `originalDateTimeOriginal` stores the last-saved value for the dirty comparison baseline.
- `markClean()` resets the baseline to the current value and clears the dirty flag.
- Identifiable (UUID) and Hashable for List selection.

### ExifToolService (Service Layer)
- **Path resolution:** Locates `exiftool` at static init time by checking common paths (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/opt/local/bin`) and falling back to `which exiftool`. This ensures the app works from Terminal, Xcode, or a bundled `.app` regardless of PATH.
- **Read (single):** `readDateTimeOriginal(from url:)` — delegates to the batch version.
- **Read (batch):** `readDateTimeOriginal(from urls:)` — calls `exiftool -json -DateTimeOriginal <files...>` once for all files, decodes JSON, returns a `[URL: String?]` dictionary. This is ~50–100× faster for large batches.
- **Write:** Calls `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <file1> <file2> ...` — uses the `EXIF:` group specifier to target the correct EXIF tag (not derived fields like CreateDate or IPTC data).
- Supports batch writes: accepts `[URL]` so multiple files with the same value are sent in a single process invocation.
- Returns a `WriteResult` struct with `success: Bool` and `output: String` (captured stdout/stderr for error reporting).
- All metadata logic is delegated to ExifTool.

### FileListViewModel (ViewModel)
- `@Observable` class with `@MainActor`.
- `var files: [ImageFile]` — the source of truth for the file list.
- `var selectedFile: ImageFile?` — `didSet` triggers `clearFeedback()`, which clears save confirmation and status when navigating to a different file.
- `var selectedFiles: [ImageFile]` — holds multi-selection for bulk edit.
- `var bulkEditValue: String` — the text field value from the bulk edit bar.
- `importFiles(_:)` / `importFolder(_:)` — validates image types via extension check, deduplicates by URL, batch-reads metadata via `ExifToolService.readDateTimeOriginal(from:)`, appends to array.
- `clearAll()` — removes all files and resets state (⌘K shortcut).
- `applyBulkEdit()` — sets `dateTimeOriginal` on all `selectedFiles` to `bulkEditValue`.
- `saveAll()` — the single save method. Groups dirty files by `dateTimeOriginal` value and calls `ExifToolService.writeDateTimeOriginal()` once per group. Updates `lastSaveFeedback` with before/after details.
- `dirtyCount: Int` — computed property for button label and feedback.
- `lastSaveFeedback: SaveFeedback?` — holds the most recent save result for display in the preview panel.

### DropZoneView
- Purely visual. Shows the empty-state icon and instructions when no files are loaded.
- All drag-and-drop handling is at the `ContentView` level so it works in all states.

### FileTableView
- SwiftUI `List` (not `Table` — `List` gives reliable bindings with `@Observable`).
- Uses `Set<ImageFile.ID>` for `selection`, enabling multi-select via ⌘+click.
- Uses `@Bindable` to create a `$binding` for each file's `dateTimeOriginal`.
- **Orange text:** The DateTimeOriginal `TextField` uses `.foregroundColor(isDirty ? .orange : .primary)` to clearly indicate unsaved changes.
- Selection syncs to both `viewModel.selectedFile` (preview) and `viewModel.selectedFiles` (bulk edit) via `onChange(of: selectedIDs)`.

### PreviewPanel
- Shows thumbnail (loaded via `NSImage(contentsOf:)`).
- **Diff view when dirty:** Displays original value in grey strikethrough above the proposed value in green bold, with a green-tinted background.
- **Clean state:** Shows the current value in plain text on a grey background.
- **Save feedback:** After a successful save, shows a green badge with `"old → new"` — this clears automatically when navigating to a different file.
- **Single Save button:** One button labelled "Save Changes (N)" showing the dirty count. Disabled when nothing is dirty. Keyboard shortcut: `⌘S`.

### ContentView (Root)
- Manages the empty state (DropZoneView) vs loaded state (HSplitView with table + preview).
- **Bulk edit bar:** When `viewModel.selectedFiles.count > 1`, shows a HStack with a text field and "Apply" button above the table.
- **Status bar:** Shows the current `statusMessage` and a `ProgressView` when loading.
- **Drop handling:** `onDrop(of:)` resolves URLs, separates files from folders, and calls the ViewModel.
- **App-wide keyboard shortcuts:** Two hidden `.background(Button(...).keyboardShortcut(...))` modifiers:
  - `⌘K` → `viewModel.clearAll()`
  - `⌘S` → `viewModel.saveAll()`

## Data Flow

1. **Import:** User drops files → `ContentView.onDrop` resolves URLs → ViewModel filters by extension, deduplicates, batch-reads metadata via `ExifToolService.readDateTimeOriginal(from:)` (single process call) → results populate list.
2. **Edit (single):** User clicks into the DateTimeOriginal `TextField` → edits value → binding writes to the `@Observable` model → `didSet` marks file dirty → UI auto-updates.
3. **Edit (bulk):** User selects multiple files (⌘+click) → bulk edit bar appears → types a value → presses Enter or "Apply" → `applyBulkEdit()` sets value on all selected files.
4. **Review:** Preview panel shows grey (current) → green (proposed) diff.
5. **Save:** User presses `⌘S` → ViewModel groups dirty files by value → `ExifToolService.writeDateTimeOriginal()` called once per group → on success, `markClean()` resets each file.
6. **Clear:** User presses `⌘K` → `clearAll()` removes all files, returns to drop zone.

## Key Design Decisions

### Batch Reads
ExifTool can process multiple files in a single invocation. The service layer accepts `[URL]` for both reads and writes, reducing process spawn overhead dramatically.

### ExifTool Path Resolution
The app does not rely on PATH propagation (which breaks in Xcode). Instead it checks common Homebrew/MacPorts install paths at startup and falls back to `which`.

### Multi-Select & Bulk Edit
The file table uses SwiftUI `List` with `Set<ImageFile.ID>` selection. The ViewModel tracks both `selectedFile` (for preview) and `selectedFiles` (for bulk edit). A bulk edit bar appears in ContentView when 2+ files are selected.

### Dirty State Pattern
Editing marks a file dirty — nothing is written to disk until the user explicitly saves. This prevents accidental overwrites.

### No Local Image Database
Images are loaded from their original paths. No caching, no library management. The user's filesystem is the source of truth.

### ExifTool Only
All metadata operations are delegated to `exiftool`. The app never interprets or transforms date strings — it passes them through exactly as entered.

### @Observable over ObservableObject
Using the `@Observable` macro (macOS 14+) instead of `@Published`/`ObservableObject` avoids the "field jumps back on enter" bug that plagues struct-based bindings in SwiftUI `List`/`Table` views. Reference types with `@Observable` give rock-solid two-way bindings.

### Explicit EXIF Tag Targeting
Write commands use `-EXIF:DateTimeOriginal=` rather than `-DateTimeOriginal=`. This prevents ExifTool from writing to related fields (CreateDate, ModifyDate, IPTC date/time fields) when it auto-derives them from the tag name.

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
| `Return` | Bulk edit bar | Apply bulk edit value |