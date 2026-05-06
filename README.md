# ExifShell

A minimal, high-speed macOS application for inspecting and editing image metadata using **ExifTool** as its backend.

## Philosophy

- **Speed over completeness**
- **Clarity over flexibility**
- **Batch power, single-file precision**
- **WYSIWYG editing** — no mental translation from terminal syntax

## Minimal Viable Feature Set

- Drag & drop images or folders
- View and edit `DateTimeOriginal` metadata in a sortable table
- **Multi-select with ⌘+click** — edit multiple files at once
- **Bulk edit bar** — when 2+ files are selected, a toolbar appears to set a value on all of them
- Files are **marked dirty** on edit — orange text in the table signals unsaved changes
- **Diff review** — preview panel shows grey (current) → green (proposed) before you save
- **Single Save button** — saves all dirty files in efficient batch writes per unique value
- Thumbnail preview of selected image
- Save confirmation with before/after values (clears on navigation)
- Keyboard shortcuts: `⌘S` (save all), `⌘K` (clear all files)

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
2. Drop images or folders → Files load with current DateTimeOriginal (batch-loaded for speed)
3. Click a file to preview → Thumbnail + editable field shown
4. Edit the date in-place → File marked "• modified" (dirty)
5. Select multiple files (⌘+click) → Bulk edit bar appears for mass updates
6. Press ⌘S → Save all dirty files
   Press ⌘K → Clear all files and return to drop zone
```

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘S` | Save all dirty files |
| `⌘K` | Clear all files (back to drop zone) |
| `⌘+click` | Toggle multi-select in file list |
| `Return` (in bulk edit field) | Apply bulk edit value |

### Dirty State

ExifShell uses an intentional "edit → mark dirty → apply" pattern:

- Editing a file's date marks it as **dirty** (orange "• modified" indicator).
- Nothing is written to disk until you explicitly apply.
- Apply buttons show the dirty count (e.g. "Apply to All (3 dirty)").
- Buttons are **disabled** when there's nothing to save.
- On successful write, the file is marked clean and the original baseline resets.

This prevents accidental overwrites and enables efficient batch writes
by grouping files with identical date values into a single ExifTool process call.

## Performance

### Batch ExifTool Reads

When you drop files, the app processes **all files in a single ExifTool invocation** rather than spawning one process per file. For 100+ files this is ~50–100× faster than the naive approach.

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
├── ContentView.swift           # Root view + bulk edit bar + keyboard shortcuts
├── Models/ImageFile.swift      # Data model (with dirty state tracking)
├── ViewModels/FileListViewModel.swift  # State, logic, batch apply, bulk edit
├── Services/ExifToolService.swift      # ExifTool wrapper (batch reads + writes)
└── Views/
    ├── DropZoneView.swift      # Drag-and-drop
    ├── FileTableView.swift     # Metadata table with multi-select
    └── PreviewPanel.swift      # Thumbnail + diff + apply
Documentation/
├── ARCHITECTURE.md             # Architecture overview
├── AI_CONTEXT.md               # AI-friendly edit context
└── BRIEF.md                    # Project vision & roadmap
```

## License

MIT