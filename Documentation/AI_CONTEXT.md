# AI Context — ExifShell

This file is designed to give an AI assistant (or a future developer) the minimum context needed to understand and modify ExifShell safely and correctly.

## Project Summary

ExifShell is a native macOS app (SwiftUI) that lets users drag-and-drop images, view/edit `DateTimeOriginal` metadata, and apply changes via ExifTool. It follows MVVM with a single service layer for shell commands.

---

## File Map

| File | Purpose |
|---|---|
| `Sources/ExifShellApp.swift` | `@main` entry point. Sets activation policy, brings app to front. |
| `Sources/ContentView.swift` | Root view. Shows `DropZoneView` when empty, or `HSplitView` (table + preview) when files loaded. Owns all drop handling, bulk edit bar, status bar, and app-wide keyboard shortcuts (⌘K, ⌘S). |
| `Sources/Models/ImageFile.swift` | `@Observable` class: `url`, `filename`, `dateTimeOriginal`, `isDirty` state, `thumbnail`. |
| `Sources/ViewModels/FileListViewModel.swift` | `@Observable` class: all state (`files[]`, `selectedFile`, `selectedFiles[]`, `bulkEditValue`), import (batch read), select, save, clear, bulk edit. |
| `Sources/Services/ExifToolService.swift` | Static methods to read/write ExifTool metadata. Shells out via `Process`. Auto-resolves exiftool path. Supports batch reads (`[URL]` → `[URL: String?]`). |
| `Sources/Views/DropZoneView.swift` | Visual drop zone (drop handling in ContentView). |
| `Sources/Views/FileTableView.swift` | SwiftUI `List` with multi-select (`Set<ImageFile.ID>`), editable date column, orange text when dirty. |
| `Sources/Views/PreviewPanel.swift` | Thumbnail + diff review (grey old → green proposed) + single Save button. |

---

## Conventions

### Adding a new metadata field (e.g. `Description`)

1. **`ImageFile.swift`**: Add a new `var description: String` property and include it in the dirty comparison logic.
2. **`ExifToolService.swift`**: Add `readDescription(from:)` and `writeDescription(_:to:)` methods. The read method should accept `[URL]` for batch support. The write method already accepts `[URL]` — just add the new tag.
3. **`FileListViewModel.swift`**: Update `importFiles(_:)` to call the new batch read method. Update `saveAll()` to include the new field in the write call.
4. **`FileTableView.swift`**: Add a new column/row element for the field with a `@Bindable` binding.
5. **`PreviewPanel.swift`**: Add a new diff section for the field.

### Adding a new view
- Create file in `Sources/Views/`.
- Pass `FileListViewModel` as `let` (not `@ObservedObject` — using `@Observable`).
- Add it to `ContentView.swift` or nest inside an existing view.

### ExifTool call pattern
Always support batch reads and writes:

```swift
// BATCH READ — single process call for all URLs
static func readDescription(from urls: [URL]) -> [URL: String?] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exifToolPath)
    process.arguments = ["-json", "-Description"] + urls.map(\.path)
    // capture stdout, decode JSON, return dictionary
}

// BATCH WRITE — single process call for all URLs with same value
static func writeDescription(_ value: String, to urls: [URL]) -> WriteResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exifToolPath)
    var args = ["-overwrite_original", "-EXIF:ImageDescription=\(value)"]
    args.append(contentsOf: urls.map(\.path))
    process.arguments = args
    // capture stdout+stderr, run, return WriteResult
}
```

**Key patterns:**
- **For writes:** Always accept `[URL]` (batch). Single file is just `[url]`.
- **For reads:** Accept `[URL]`, return `[URL: String?]` dictionary.
- **Path:** Use the static `exifToolPath` property, **not** `/usr/bin/env` (which breaks in Xcode).
- **Tag group:** Always use explicit group specifiers like `-EXIF:DateTimeOriginal=`, not `-DateTimeOriginal=`.

---

## ExifTool Commands Used

| Operation | Command |
|---|---|
| Read (single) | Delegates to batch read with `[url]` |
| Read (batch) | `exiftool -json -DateTimeOriginal <file1> <file2> ...` |
| Write (batch) | `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <files...>` |

---

## Key Architecture Points

### @Observable (not ObservableObject)
All models and the view model use the `@Observable` macro (macOS 14+). This means:
- Views use `let viewModel: FileListViewModel` not `@ObservedObject`
- Bindings use `@Bindable var bindableFile = file` then `$bindableFile.dateTimeOriginal`
- No need for `@Published` or `objectWillChange`

### ExifTool Path Resolution
The static property `exifToolPath` is resolved once at startup by checking:
1. `/opt/homebrew/bin/exiftool` (Apple Silicon Homebrew)
2. `/usr/local/bin/exiftool` (Intel Homebrew)
3. `/usr/bin/exiftool`
4. `/opt/local/bin/exiftool` (MacPorts)
5. `which exiftool` fallback

If not found, `missingToolError` returns a descriptive message and all read/write operations return nil/failure.

### Batch Reads
`ExifToolService.readDateTimeOriginal(from urls:)` processes all files in a single process invocation. This is ~50–100× faster for large batches. The single-file variant delegates to the batch version.

### Multi-Select & Bulk Edit
- `FileTableView` uses `Set<ImageFile.ID>` for selection.
- `FileListViewModel.selectedFiles` tracks multi-selection.
- `ContentView` shows a bulk edit bar when `selectedFiles.count > 1`.
- `applyBulkEdit()` sets `dateTimeOriginal` on all selected files.

### Keyboard Shortcuts
- **⌘S** (app-wide via hidden button in ContentView) — saves all dirty files.
- **⌘K** (app-wide via hidden button in ContentView) — clears all files, returns to drop zone.
- **⌘+click** — toggle multi-select in the file table.
- **Return** in the bulk edit text field — apply bulk edit value.

### Dirty State
- `ImageFile.isDirty` set automatically in `didSet` of `dateTimeOriginal`
- `markClean()` resets baseline after successful save
- Table shows orange text for dirty files
- Preview shows grey old → green proposed diff

### Save Logic (Single Button)
- One "Save Changes (N)" button in PreviewPanel + app-wide ⌘S shortcut
- Groups dirty files by identical values for batch writes
- Feedback clears on navigation via `selectedFile.didSet`

---

## Common Edit Scenarios

### "Fix write targeting a different field"
Edit `ExifToolService.swift` — make sure the tag argument uses an explicit group specifier like `-EXIF:DateTimeOriginal=` not just `-DateTimeOriginal=`.

### "Change the orange dirty indicator colour"
Edit `FileTableView.swift` — change `.foregroundColor(isDirty ? .orange : .primary)`.

### "Add a new action button"
- Add a `Button` in `PreviewPanel.swift` or `ContentView.swift`.
- Wire it to a new method in `FileListViewModel.swift`.
- Optionally add a keyboard shortcut using `.keyboardShortcut(...)`.

### "Make the table sortable"
- Change `selectedIDs` to a `SortDescriptor`-based binding in `FileTableView.swift`.
- Sort the `files` array in the ViewModel based on sort keys.

### "Add a progress indicator for large imports"
- `FileListViewModel` already has `var isLoading`.
- Show a `ProgressView` in `ContentView.swift` (status bar already exists).

### "Fix empty fields when running from Xcode"
This is fixed — `ExifToolService.exifToolPath` auto-resolves the binary path. No `/usr/bin/env` or PATH dependency.

---

## Build

```bash
swift run
```

Requires macOS 14+ and `exiftool` on PATH (for the `which` fallback; common Homebrew paths are checked directly).