# AI Context — ExifShell

This file is designed to give an AI assistant (or a future developer) the minimum context needed to understand and modify ExifShell safely and correctly.

## Project Summary

ExifShell is a native macOS app (SwiftUI) that lets users drag-and-drop images, view/edit `DateTimeOriginal` metadata, and apply changes via ExifTool. It follows MVVM with a single service layer for shell commands.

---

## File Map

| File | Purpose |
|---|---|
| `Sources/ExifShellApp.swift` | `@main` entry point. Window group setup. |
| `Sources/ContentView.swift` | Root view. Shows `DropZoneView` when empty, or `HSplitView` (table + preview) when files loaded. |
| `Sources/Models/ImageFile.swift` | Data model: `url`, `filename`, `dateTimeOriginal`, `thumbnail`, `isDirty` state tracking. |
| `Sources/ViewModels/FileListViewModel.swift` | All state (`files[]`, `selectedFile`, `statusMessage`). Import, select, apply logic. |
| `Sources/Services/ExifToolService.swift` | Static methods to read/write ExifTool metadata. Shells out via `Process`. |
| `Sources/Views/DropZoneView.swift` | Drag-and-drop handler. Accepts files/folders. |
| `Sources/Views/FileTableView.swift` | SwiftUI `Table` with editable date column. |
| `Sources/Views/PreviewPanel.swift` | Thumbnail + edit field + apply buttons. |

---

## Conventions

### Adding a new metadata field (e.g. `Description`)

1. **`ImageFile.swift`**: Add a new `var description: String` property.
2. **`ExifToolService.swift`**: Add `readDescription(from:)` and `writeDescription(_:to:)` methods.
3. **`FileListViewModel.swift`**: Update `importFiles(_:)` to call the new read method. Add apply logic if needed.
4. **`FileTableView.swift`**: Add a new `TableColumn` for the field.
5. **`PreviewPanel.swift`**: Add a new `TextField` for the field.
6. **`ImageFile` initializer** may need updating.

### Adding a new view
- Create file in `Sources/Views/`.
- Pass `FileListViewModel` as `@ObservedObject`.
- Add it to `ContentView.swift` or nest inside an existing view.

### ExifTool call pattern
Always follow this pattern in `ExifToolService`:

```swift
static func someOperation(_ param: String, to urls: [URL]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // Build arguments list
    var args = ["exiftool", "-overwrite_original", "-TagName=\(param)"]
    args.append(contentsOf: urls.map(\.path))
    process.arguments = args
    // Run + return success/failure
    ...
}
```

- **For writes:** Always support `[URL]` (batch). Single file is just `[url]`.
- **For reads:** Accept single `URL`, return decoded value or nil.

---

## ExifTool Commands Used

| Operation | Command |
|---|---|
| Read DateTimeOriginal | `exiftool -json -DateTimeOriginal <file>` |
| Write DateTimeOriginal | `exiftool -overwrite_original -DateTimeOriginal="<value>" <files...>` |

---

## Common Edit Scenarios

### "Change the date format validation"
- Edit the `TextField` binding in `FileTableView.swift` or `PreviewPanel.swift`.
- ExifTool accepts EXIF date format: `YYYY:MM:DD HH:MM:SS`. The app does not currently validate this — it passes user input directly to ExifTool.

### "Add a new action button"
- Add a `Button` in `PreviewPanel.swift`.
- Wire it to a new method in `FileListViewModel.swift`.
- Optionally add a keyboard shortcut.

### "Make the table sortable"
- Add `sortOrder` state and `Table` sorting modifiers in `FileTableView.swift`.
- Sort the `files` array in the ViewModel based on sort keys.

### "Add a progress indicator for large imports"
- `FileListViewModel` already has `@Published var isLoading`.
- Show a `ProgressView` in `DropZoneView` (already done) or as an overlay on the table.

---

## Build

```bash
swift run
```

Requires macOS 14+ and `exiftool` on PATH.