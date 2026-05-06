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
│         (Root view, own drop handling)          │
└──────┬───────────────────────────┬─────────────┘
       │                           │
┌──────▼──────────┐     ┌─────────▼───────────┐
│  FileTableView   │     │    PreviewPanel      │
│  (editable List) │     │  (Thumbnail + Diff)  │
└──────┬──────────┘     └─────────┬───────────┘
       │                          │
       └──────────┬───────────────┘
                  │ observes
       ┌──────────▼───────────────┐
       │   FileListViewModel      │
       │  @Observable class       │
       │  var files: [ImageFile]  │
       │  var selectedFile        │
       └──────────┬───────────────┘
                  │ calls
       ┌──────────▼───────────────┐
       │     ExifToolService       │
       │  readDateTimeOriginal()  │
       │  writeDateTimeOriginal() │
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
├── ContentView.swift            # Root view: empty drop zone or split pane + drop handling
├── Models/
│   └── ImageFile.swift         # @Observable class per image with dirty tracking
├── ViewModels/
│   └── FileListViewModel.swift # @Observable class: state, import, save, feedback
├── Services/
│   └── ExifToolService.swift   # Shell wrapper for exiftool (read/write)
└── Views/
    ├── DropZoneView.swift      # Visual drop zone (drop logic in ContentView)
    ├── FileTableView.swift     # List with editable DateTimeOriginal + orange dirty indicator
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
- **Read:** Calls `exiftool -json -DateTimeOriginal <file>` and decodes the JSON response.
- **Write:** Calls `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <file1> <file2> ...` — uses the `EXIF:` group specifier to target the correct EXIF tag (not derived fields like CreateDate or IPTC data).
- Supports batch writes: accepts `[URL]` so multiple files with the same value are sent in a single process invocation.
- Returns a `WriteResult` struct with `success: Bool` and `output: String` (captured stdout/stderr for error reporting).
- All metadata logic is delegated to ExifTool.

### FileListViewModel (ViewModel)
- `@Observable` class with `@MainActor`.
- `var files: [ImageFile]` — the source of truth for the file list.
- `var selectedFile: ImageFile?` — `didSet` triggers `clearFeedback()`, which clears save confirmation and status when navigating to a different file.
- `importFiles(_:)` / `importFolder(_:)` — validates image types via extension check, deduplicates by URL, reads metadata, appends to array.
- `saveAll()` — the single save method. Groups dirty files by `dateTimeOriginal` value and calls `ExifToolService.writeDateTimeOriginal()` once per group. Updates `lastSaveFeedback` with before/after details.
- `dirtyCount: Int` — computed property for button label and feedback.
- `lastSaveFeedback: SaveFeedback?` — holds the most recent save result for display in the preview panel.

### DropZoneView
- Purely visual. Shows the empty-state icon and instructions when no files are loaded.
- All drag-and-drop handling is at the `ContentView` level so it works in all states.

### FileTableView
- SwiftUI `List` (not `Table` — `List` gives reliable bindings with `@Observable`).
- Uses `@Bindable` to create a `$binding` for each file's `dateTimeOriginal`.
- **Orange text:** The DateTimeOriginal `TextField` uses `.foregroundColor(isDirty ? .orange : .primary)` to clearly indicate unsaved changes.
- Selection syncs to `viewModel.selectedFile` via `onChange(of: selectedID)`.

### PreviewPanel
- Shows thumbnail (loaded via `NSImage(contentsOf:)`).
- **Diff view when dirty:** Displays original value in grey strikethrough above the proposed value in green bold, with a green-tinted background.
- **Clean state:** Shows the current value in plain text on a grey background.
- **Save feedback:** After a successful save, shows a green badge with `"old → new"` — this clears automatically when navigating to a different file.
- **Single Save button:** One button labelled "Save Changes (N)" showing the dirty count. Disabled when nothing is dirty. Keyboard shortcut: `⌘S`.

## Data Flow

1. **Import:** User drops files → `ContentView.onDrop` resolves URLs → ViewModel filters by extension, deduplicates, calls `ExifToolService.readDateTimeOriginal()` per file → results populate list.
2. **Edit:** User clicks into the DateTimeOriginal `TextField` in the list → edits value → binding writes to the `@Observable` model → `didSet` marks file dirty → UI auto-updates (orange text, preview diff appears).
3. **Review:** Preview panel shows grey (current) → green (proposed) diff with the exact before/after values.
4. **Save:** User presses `⌘S` or clicks "Save Changes" → ViewModel groups dirty files by value → `ExifToolService.writeDateTimeOriginal(value, to: urls)` called once per group → on success, `markClean()` resets each file → feedback shown → navigating away clears feedback.

## Key Design Decisions

### Batch Writes
ExifTool can process multiple files in a single invocation. The service layer accepts `[URL]` for writes. The ViewModel groups dirty files by identical `DateTimeOriginal` values to minimize process spawns.

### Dirty State Pattern
Editing marks a file dirty — nothing is written to disk until the user explicitly saves. This prevents accidental overwrites. Dirty files show orange text in the table and a diff in the preview panel.

### No Local Image Database
Images are loaded from their original paths. No caching, no library management. The user's filesystem is the source of truth.

### ExifTool Only
All metadata operations are delegated to `exiftool`. The app never interprets or transforms date strings — it passes them through exactly as entered.

### @Observable over ObservableObject
Using the `@Observable` macro (macOS 14+) instead of `@Published`/`ObservableObject` avoids the "field jumps back on enter" bug that plagues struct-based bindings in SwiftUI `List`/`Table` views. References types with `@Observable` give rock-solid two-way bindings.

### Explicit EXIF Tag Targeting
Write commands use `-EXIF:DateTimeOriginal=` rather than `-DateTimeOriginal=`. This prevents ExifTool from writing to related fields (CreateDate, ModifyDate, IPTC date/time fields) when it auto-derives them from the tag name.

## Dependencies

- **Swift 5.9+ / macOS 14+** — `@Observable`, SwiftUI `List`, `Hashable`.
- **ExifTool** — Must be installed and available on `$PATH` (`brew install exiftool`). Not bundled with the app.

## Build & Run

```bash
swift run
```

Or open in Xcode and run.