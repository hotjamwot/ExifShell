# ExifShell Architecture

## Overview

ExifShell is a macOS application for inspecting and editing image metadata via ExifTool. It follows a simple **MVVM** pattern (Model-View-ViewModel) with a dedicated service layer for shelling out to ExifTool.

```
┌────────────────────────────────────────────────┐
│                    App (Scene)                  │
│               ExifShellApp.swift                │
└──────────────────┬─────────────────────────────┘
                   │
┌──────────────────▼─────────────────────────────┐
│                 ContentView                     │
│         (Root view, delegates state)            │
└──────┬───────────────────────────┬─────────────┘
       │                           │
┌──────▼──────────┐     ┌─────────▼───────────┐
│  FileTableView   │     │    PreviewPanel      │
│  (SwiftUI Table) │     │  (Thumbnail + Edit)  │
└──────┬──────────┘     └─────────┬───────────┘
       │                          │
       └──────────┬───────────────┘
                  │ observes
       ┌──────────▼───────────────┐
       │   FileListViewModel      │
       │  @Published var files[]  │
       │  @Published selectedFile │
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
├── ExifShellApp.swift          # @main app entry point
├── ContentView.swift            # Root view: empty drop zone or split pane
├── Models/
│   └── ImageFile.swift         # Data model per image
├── ViewModels/
│   └── FileListViewModel.swift # Business logic, state, apply actions
├── Services/
│   └── ExifToolService.swift   # Shell wrapper for exiftool (read/write)
└── Views/
    ├── DropZoneView.swift      # Drag-and-drop overlay
    ├── FileTableView.swift     # Table with filename + DateTimeOriginal
    └── PreviewPanel.swift      # Thumbnail + editable field + apply buttons
```

## Component Responsibilities

### ImageFile (Model)
- Holds the file URL, filename, current `dateTimeOriginal` string, and an `NSImage` thumbnail.
- Tracks `isDirty` state — when `dateTimeOriginal` is modified, `isDirty` auto-flags to `true` via `didSet`.
- `originalDateTimeOriginal` stores the last-saved value for comparison.
- `markClean()` resets the baseline after a successful write.
- Identifiable (UUID) and Hashable for SwiftUI Table selection.

### ExifToolService (Service Layer)
- **Read:** Calls `exiftool -json -DateTimeOriginal <file>` and decodes the JSON response.
- **Write:** Calls `exiftool -overwrite_original -DateTimeOriginal="<value>" <file1> <file2> ...` — supports batch writes so multiple files with the same value are sent in a single process invocation.
- All metadata logic is delegated to ExifTool. This file should never contain parsing or transformation logic beyond JSON decoding.

### FileListViewModel (ViewModel)
- `@Published var files: [ImageFile]` — the source of truth for the file list.
- `importFiles(_:)` / `importFolder(_:)` — validates image types, reads metadata, appends to array.
- `applySelected()` / `applyAll()` — triggers batch writes via ExifToolService.
- Groups files by date value for efficient batch writes.

### DropZoneView
- Uses `.onDrop(of: [.fileURL])` to accept files and folders.
- Separates dropped items into files vs. directories and dispatches accordingly.
- Shows visual feedback on drag enter/exit.

### FileTableView
- SwiftUI `Table` with two columns: Filename (read-only) and DateTimeOriginal (editable `TextField`).
- Selection triggers the preview panel update.

### PreviewPanel
- Shows the selected file's image (loaded via `NSImage(contentsOf:)`).
- Provides an editable `TextField` for `DateTimeOriginal`.
- Two buttons: "Apply to Selected" (⌘S) and "Apply to All" (⇧⌘S).
- Displays status message after apply operations.

## Data Flow

1. **Import:** User drops files → DropZoneView resolves file URLs → ViewModel calls `ExifToolService.readDateTimeOriginal()` per file → results populate table.
2. **Edit:** User clicks into table cell or preview panel → edits value → binding updates the model in-memory immediately.
3. **Apply:** User presses ⌘S or clicks button → ViewModel groups files by date value → calls `ExifToolService.writeDateTimeOriginal(value, to: urls)` once per group → status message shown.

## Key Design Decisions

### Batch Writes
ExifTool can process multiple files in a single invocation. The service layer accepts `[URL]` for writes. The ViewModel groups files by identical `DateTimeOriginal` values to minimize process spawns.

### No Local Image Database
Images are loaded from their original paths. No caching, no library management. The user's filesystem is the source of truth.

### ExifTool Only
All metadata operations are delegated to `exiftool`. The app never interprets or transforms date strings — it passes them through exactly as entered.

## Dependencies

- **Swift 5.9+ / macOS 14+** — SwiftUI `Table`, `Observation`, `Hashable` conformance.
- **ExifTool** — Must be installed and available on `$PATH`. Not bundled with the app.

## Build & Run

```bash
swift run
```

Or open in Xcode and run.