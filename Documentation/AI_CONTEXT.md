# AI Context — ExifShell

This file is designed to give an AI assistant (or a future developer) the minimum context needed to understand and modify ExifShell safely and correctly.

## Project Summary

ExifShell is a native macOS app (SwiftUI) that lets users drag-and-drop images, view/edit `DateTimeOriginal` metadata, and apply changes via ExifTool. It follows MVVM with a single service layer for shell commands.

---

## File Map

| File | Purpose |
|---|---|
| `Sources/ExifShellApp.swift` | `@main` entry point. Sets activation policy, brings app to front. |
| `Sources/ContentView.swift` | Root view. Shows `DropZoneView` when empty, or `HSplitView` (table + preview) when files loaded. Owns all drop handling. |
| `Sources/Models/ImageFile.swift` | `@Observable` class: `url`, `filename`, `dateTimeOriginal`, `isDirty` state, `thumbnail`. |
| `Sources/ViewModels/FileListViewModel.swift` | `@Observable` class: all state (`files[]`, `selectedFile`), import, select, save logic, feedback management. |
| `Sources/Services/ExifToolService.swift` | Static methods to read/write ExifTool metadata. Shells out via `Process`. |
| `Sources/Views/DropZoneView.swift` | Visual drop zone (drop handling in ContentView). |
| `Sources/Views/FileTableView.swift` | SwiftUI `List` with editable date column, orange text when dirty. |
| `Sources/Views/PreviewPanel.swift` | Thumbnail + diff review (grey old → green proposed) + single Save button. |

---

## Conventions

### Adding a new metadata field (e.g. `Description`)

1. **`ImageFile.swift`**: Add a new `var description: String` property and include it in the dirty comparison logic.
2. **`ExifToolService.swift`**: Add `readDescription(from:)` and `writeDescription(_:to:)` methods following the same batch pattern (accept `[URL]`).
3. **`FileListViewModel.swift`**: Update `importFiles(_:)` to call the new read method. Update `saveAll()` to include the new field in the write call.
4. **`FileTableView.swift`**: Add a new column/row element for the field with a `@Bindable` binding.
5. **`PreviewPanel.swift`**: Add a new diff section for the field.

### Adding a new view
- Create file in `Sources/Views/`.
- Pass `FileListViewModel` as `let` (not `@ObservedObject` — using `@Observable`).
- Add it to `ContentView.swift` or nest inside an existing view.

### ExifTool call pattern
Always support batch writes:

```swift
static func writeDescription(_ value: String, to urls: [URL]) -> WriteResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var args = ["exiftool", "-overwrite_original", "-EXIF:ImageDescription=\(value)"]
    args.append(contentsOf: urls.map(\.path))
    process.arguments = args
    // capture stdout+stderr, run, return WriteResult
}
```

- **For writes:** Always accept `[URL]` (batch). Single file is just `[url]`.
- **For reads:** Accept single `URL`, return decoded value or nil.

---

## ExifTool Commands Used

| Operation | Command |
|---|---|
| Read DateTimeOriginal | `exiftool -json -DateTimeOriginal <file>` |
| Write DateTimeOriginal | `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" <files...>` |

---

## Key Architecture Points

### @Observable (not ObservableObject)
All models and the view model use the `@Observable` macro (macOS 14+). This means:
- Views use `let viewModel: FileListViewModel` not `@ObservedObject`
- Bindings use `@Bindable var bindableFile = file` then `$bindableFile.dateTimeOriginal`
- No need for `@Published` or `objectWillChange`

### Dirty State
- `ImageFile.isDirty` set automatically in `didSet` of `dateTimeOriginal`
- `markClean()` resets baseline after successful save
- Table shows orange text for dirty files
- Preview shows grey old → green proposed diff

### Single Save Button
- One "Save Changes (N)" button with `⌘S` shortcut
- Groups dirty files by identical values for batch writes
- Feedback clears on navigation via `selectedFile.didSet`

---

## Common Edit Scenarios

### "Fix write targeting a different field"
Edit `ExifToolService.swift` — make sure the tag argument uses an explicit group specifier like `-EXIF:DateTimeOriginal=` not just `-DateTimeOriginal=`.

### "Change the orange dirty indicator colour"
Edit `FileTableView.swift` — change `.foregroundColor(isDirty ? .orange : .primary)`.

### "Add a new action button"
- Add a `Button` in `PreviewPanel.swift`.
- Wire it to a new method in `FileListViewModel.swift`.
- Optionally add a keyboard shortcut.

### "Make the table sortable"
- Add `sortOrder` state and `.sorted(by:)` in `FileTableView.swift`.
- Sort the `files` array in the ViewModel based on sort keys.

### "Add a progress indicator for large imports"
- `FileListViewModel` already has `var isLoading`.
- Show a `ProgressView` in `DropZoneView` (already done) or as an overlay on the table.

---

## Build

```bash
swift run
```

Requires macOS 14+ and `exiftool` on PATH.