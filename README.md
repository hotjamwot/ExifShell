# ExifShell

A minimal, high-speed macOS application for inspecting and editing image metadata using **ExifTool** as its backend.

## Philosophy

- **Speed over completeness**
- **Clarity over flexibility**
- **Batch power, single-file precision**
- **WYSIWYG editing** — no mental translation from terminal syntax

## Features

- Drag & drop images or folders
- View and edit `DateTimeOriginal` metadata in a sortable table
- View and edit `Description` metadata — written to Description, ImageDescription & Caption-Abstract on save
- View read-only metadata: CreateDate, ModifyDate, ImageDescription, Caption-Abstract
- **Multi-select with ⌘+click** — edit or remove multiple files at once
- **Bulk edit bar** — when 2+ files are selected, toolbars appear to set DateTimeOriginal or Description on all of them
- Files are **marked dirty** on edit — orange text in the table signals unsaved changes
- **Diff review** — preview panel shows grey (current) → green (proposed) before you save
- **Single Save button** — saves all dirty files in efficient batch writes per unique value for each field
- **Sanitise All** — normalises DateTimeOriginal format, propagates it to CreateDate/ModifyDate, clears offset fields, and copies Description to ImageDescription/Caption-Abstract
- **Delete/Backspace** — remove selected files from the working list
- Thumbnail preview of selected image
- Save confirmation with before/after values (clears on navigation)
- Keyboard shortcuts: `⌘S` (save all), `⌘K` (clear all files), `⌫ Delete` (remove selected)

## How to Run

### From Terminal (Recommended)

```bash
# Clone or cd into the project directory, then:
swift run
```

The app window will appear. This compiles and launches in one step.

### From Xcode

You can open `Package.swift` directly in Xcode and press ▶︎.

> **Note:** If fields appear empty when running from Xcode, Xcode does not inherit your shell PATH. The app now resolves the exiftool binary automatically by checking common install paths (`/opt/homebrew/bin`, `/usr/local/bin`, etc.), so this should no longer be an issue.

## Requirements

- **macOS 14+** (Sonoma)
- **ExifTool** installed and available on `$PATH`:
  ```bash
  brew install exiftool
  ```

## Usage Flow

```
1. Launch app → Empty drop zone appears
2. Drop images or folders → Files load with current metadata (batch-loaded for speed)
3. Click a file to preview → Thumbnail + editable fields + read-only metadata shown
4. Edit the date or description in-place → File marked "• modified" (dirty)
5. Select multiple files (⌘+click) → Bulk edit bars appear for mass updates
6. Press ⌘S → Save all dirty files
   Press ⌘K → Clear all files and return to drop zone
   Press ⌫ Delete → Remove selected files from the list
7. Press "Sanitise All" to normalise dates, clear offsets, and sync descriptions
```

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘S` | Save all dirty files |
| `⌘K` | Clear all files (back to drop zone) |
| `⌘+click` | Toggle multi-select in file list |
| `⌫ Delete` | Remove selected files from list |
| `Return` (in bulk edit field) | Apply bulk edit value |

### Editable Fields

| Field | Saved To |
|-------|----------|
| Date/Time Original | `EXIF:DateTimeOriginal` |
| Description | `Description`, `ImageDescription`, `Caption-Abstract` |

### Read-Only Display Fields (Preview Panel)

- Create Date
- Modify Date
- Image Description
- Caption Abstract

### Sanitise Pipeline

The "Sanitise All" button runs this ExifTool command on all loaded files:

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

This normalises the date format, propagates DateTimeOriginal to other date fields, clears any timezone offsets, and syncs the Description to all description-related tags.

### Dirty State

ExifShell uses an intentional "edit → mark dirty → apply" pattern:

- Editing a file's date or description marks it as **dirty** (orange "• modified" indicator).
- Nothing is written to disk until you explicitly apply.
- The Save button shows the dirty count (e.g. "Save Changes (3 dirty)").
- The Save button is **disabled** when there's nothing to save.
- On successful write, the file is marked clean and the original baseline resets.

This prevents accidental overwrites and enables efficient batch writes
by grouping files with identical values into a single ExifTool process call.

## Performance

### Batch ExifTool Reads

When you drop files, the app processes **all files in a single ExifTool invocation** reading 6 metadata tags at once, rather than spawning one process per file. For 100+ files this is ~50–100× faster than the naive approach.

### ExifTool Path Resolution

The app locates `exiftool` at startup by checking common install paths:
1. `/opt/homebrew/bin/exiftool` (Apple Silicon Homebrew)
2. `/usr/local/bin/exiftool` (Intel Homebrew)
3. `/usr/bin/exiftool` (rare)
4. `/opt/local/bin/exiftool` (MacPorts)
5. Falls back to `which exiftool`

This ensures it works from Terminal, Xcode, or a bundled `.app`.

## Architecture

See [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) for full details.

## Project Structure

```
Sources/
├── ExifShellApp.swift          # App entry point
├── ContentView.swift           # Root view + bulk edit bars + keyboard shortcuts
├── Models/ImageFile.swift      # Data model (with dirty state tracking, 6 metadata fields)
├── ViewModels/FileListViewModel.swift  # State, logic, batch apply, bulk edit, sanitise
├── Services/ExifToolService.swift      # ExifTool wrapper (batch reads + writes + sanitise)
└── Views/
    ├── DropZoneView.swift      # Drag-and-drop
    ├── FileTableView.swift     # Metadata table with multi-select, date + desc columns
    └── PreviewPanel.swift      # Thumbnail + diff + read-only metadata + Save + Sanitise
Documentation/
├── ARCHITECTURE.md             # Architecture overview
├── AI_CONTEXT.md               # AI-friendly edit context
└── BRIEF.md                    # Project vision & roadmap
```

## License

MIT