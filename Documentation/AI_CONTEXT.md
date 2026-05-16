# AI Context — ExifShell

This file is designed to give an AI assistant (or a future developer) the minimum context needed to understand and modify ExifShell safely and correctly.

## Project Summary

ExifShell is a native macOS app (SwiftUI) that lets users drag-and-drop images, view/edit `DateTimeOriginal` and `Description` metadata, and apply changes via ExifTool. It follows MVVM with a single service layer for shell commands.

---

## File Map

| File | Purpose |
|---|---|
| `Sources/ExifShellApp.swift` | `@main` entry point. Sets activation policy, brings app to front, sets default window size (1100×680). |
| `Sources/ContentView.swift` | Root view. Shows `DropZoneView` when empty, or `HSplitView` (table + preview) when files loaded. Owns all drop handling, two bulk edit bars (date & description), status bar, app-wide keyboard shortcuts (⌘K, ⌘S, ⌫ Delete), and loading overlay. |
| `Sources/Models/ImageFile.swift` | `@Observable` class: `url`, `filename`, `dateTimeOriginal`, `description` (both editable with dirty tracking), read-only `createDate`, `modifyDate`, `imageDescription`, `captionAbstract`, `subject`, `keywords`, `lastKeywordXMP`, `thumbnail`. |
| `Sources/ViewModels/FileListViewModel.swift` | `@Observable` class: all state (`files[]`, `selectedFile`, `selectedFiles[]`, `bulkEditValue`), import (batch full metadata read), select, save (saves date + description independently via extracted `saveDateGroups`/`saveDescriptionGroups`), clear, bulk edit (date & description), sanitise, rename. |
| `Sources/Services/ExifToolService.swift` | Static methods to read/write ExifTool metadata. All Process boilerplate centralised into `runExifTool(with:)` helper. Auto-resolves exiftool path. Supports batch full reads (`readAllMetadata` returns `[URL: FileMetadata]`), batch date writes, batch description writes, `sanitise()`, and `renameFiles()`. |
| `Sources/Views/DropZoneView.swift` | Visual drop zone (drop handling in ContentView). |
| `Sources/Views/FileTableView.swift` | SwiftUI `List` with multi-select (`Set<ImageFile.ID>`), editable date + description columns, orange text when dirty, sortable headers. |
| `Sources/Views/PreviewPanel.swift` | Thumbnail + diff review (date & description) + read-only metadata display + Save / Sanitise All / Rename All buttons. |

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
    var args = ["-overwrite_original", "-Description=\(value)", "-ImageDescription=\(value)", "-Caption-Abstract=\(value)"]
    args.append(contentsOf: urls.map(\.path))
    process.arguments = args
    // capture stdout+stderr, run, return WriteResult
}
```

**Key patterns:**
- **For writes:** Always accept `[URL]` (batch). Single file is just `[url]`.
- **For reads:** Accept `[URL]`, return `[URL: String?]` dictionary (or `[URL: FileMetadata]` for full reads).
- **Path:** Use the static `exifToolPath` property, **not** `/usr/bin/env` (which breaks in Xcode).
- **Tag group:** Always use explicit group specifiers like `-EXIF:DateTimeOriginal=`, not `-DateTimeOriginal=`.

---

## ExifTool Commands Used

| Operation | Command |
|---|---|
| Read (full batch) | `exiftool -json -DateTimeOriginal -CreateDate -ModifyDate -Description -ImageDescription -Caption-Abstract <file1> <file2> ...` |
| Read (date only) | `exiftool -json -DateTimeOriginal <file1> <file2> ...` |
| Write (date batch) | `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <files...>` |
| Write (desc batch) | `exiftool -overwrite_original -Description="<value>" -ImageDescription="<value>" -Caption-Abstract="<value>" <files...>` |
| Sanitise (batch) | `exiftool -overwrite_original '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' '-CreateDate<DateTimeOriginal' '-ModifyDate<DateTimeOriginal' -OffsetTime= -OffsetTimeOriginal= -OffsetTimeDigitized= '-ImageDescription<Description' '-Caption-Abstract<Description' <files...>` |

---

## Key Architecture Points

### @Observable (not ObservableObject)
All models and the view model use the `@Observable` macro (macOS 14+). This means:
- Views use `let viewModel: FileListViewModel` not `@ObservedObject`
- Bindings use `@Bindable var bindableFile = file` then `$bindableFile.dateTimeOriginal` / `$bindableFile.description`
- No need for `@Published` or `objectWillChange`

### ExifTool Path Resolution
The static property `exifToolPath` is resolved once at startup by checking:
1. `/opt/homebrew/bin/exiftool` (Apple Silicon Homebrew)
2. `/usr/local/bin/exiftool` (Intel Homebrew)
3. `/usr/bin/exiftool`
4. `/opt/local/bin/exiftool` (MacPorts)
5. `which exiftool` fallback

If not found, `missingToolError` returns a descriptive message and all read/write operations return nil/failure.

### Full Metadata Batch Read
`ExifToolService.readAllMetadata(from:)` processes all files in a single process invocation, reading 6 tags at once. This is used for initial import.

### Multi-Select & Bulk Edit
- `FileTableView` uses `Set<ImageFile.ID>` for selection.
- `FileListViewModel.selectedFiles` tracks multi-selection.
- `ContentView` shows two bulk edit bars when `selectedFiles.count > 1`:
  - Date bar (accent-tinted) — sets DateTimeOriginal on all selected files.
  - Description bar (green-tinted) — sets Description on all selected files.

### Delete / Remove Selected Files
- `FileListViewModel.removeSelected()` removes all files whose IDs are in `selectedFiles`.
- `ContentView` has a hidden button bound to `⌫ Delete` keyboard shortcut (no modifier).
- This is distinct from `⌘K` (clear all) — delete only removes selected files.

### Sanitise Pipeline
- `ExifToolService.sanitise(_ urls:)` runs the full sanitise in one ExifTool invocation:
  - Normalises DateTimeOriginal format via `DateFmt`
  - Propagates DateTimeOriginal → CreateDate, ModifyDate
  - Clears OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
  - Copies Description → ImageDescription, Caption-Abstract
- `FileListViewModel.sanitiseAll()` first saves any dirty files, then runs sanitise on all loaded files, then re-reads metadata and resets dirty state.
- The "Sanitise All" button in PreviewPanel is disabled while running and shows a ProgressView.

### Keyboard Shortcuts
- **⌘S** (app-wide via hidden button in ContentView) — saves all dirty files.
- **⌘K** (app-wide via hidden button in ContentView) — clears all files, returns to drop zone.
- **⌫ Delete** (app-wide via hidden button in ContentView) — removes selected files.
- **⌘+click** — toggle multi-select in the file table.
- **Return** in the bulk edit text field — apply bulk edit value.

### Dirty State
- `ImageFile.isDirty` set automatically in `didSet` of `dateTimeOriginal` and `description`
- `markClean()` resets both baselines after successful save
- Table shows orange text for dirty files
- Preview shows grey old → green proposed diff for both date and description

### Save Logic (Single Button)
- One "Save Changes (N)" button in PreviewPanel + app-wide ⌘S shortcut
- Independently groups date-changed files by value and desc-changed files by value for batch writes
- Tracks separate save feedback for date and description
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