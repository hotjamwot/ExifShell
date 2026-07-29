# AI Context — ExifShell

This file is designed to give an AI assistant (or a future developer) the minimum context needed to understand and modify ExifShell safely and correctly.

## Quick Reference

```
File                             → depends on                     → used by
├── ExifShellApp.swift           → ContentView                    → (none — @main)
├── ContentView.swift            → FileListViewModel              → ExifShellApp
│                                → DropZoneView, FileTableView
│                                → PreviewPanel
│                                → BulkEditDateBar, BulkEditDescriptionBar
├── Models/ImageFile.swift       → FileListViewModel              → FileTableView, PreviewPanel
│                                → ExifToolService (DateSource)
├── ViewModels/
│   ├── FileListViewModel.swift  → ImageFile, ExifToolService     → ContentView, FileTableView, PreviewPanel
│   ├── FileListViewModel+Save.swift → FileListViewModel           → (extension, no direct consumer)
│   └── FileListViewModel+Rename.swift → FileListViewModel         → (extension, no direct consumer)
├── Services/
│   ├── ExifToolService.swift    → (none — static enum)           → FileListViewModel, ImageFile(Rename)
│   ├── ExifToolService+Extensions.swift → ExifToolService        → (extension)
│   ├── ExifToolService+ReadWrite.swift  → ExifToolService        → (extension)
│   └── ExifToolService+Rename.swift     → ExifToolService        → (extension)
└── Views/
    ├── DropZoneView.swift       → FileListViewModel              → ContentView
    ├── FileTableView.swift      → FileListViewModel, ImageFile   → ContentView
    ├── PreviewPanel.swift       → FileListViewModel, ImageFile   → ContentView
    ├── BulkEditDateBar.swift    → FileListViewModel              → ContentView
    └── BulkEditDescriptionBar.swift → FileListViewModel          → ContentView
```

## Project Summary

ExifShell is a native macOS app (SwiftUI) that lets users drag-and-drop images **and videos**, view/edit `DateTimeOriginal` and `Description` metadata, and apply changes via ExifTool. It follows MVVM with a single service layer for shell commands.

Media support:
- **Images**: JPEG, PNG, HEIC, RAW (CR2, CR3, NEF, ARW, DNG, ORF, RW2, SR2), TIFF, GIF, BMP, WebP, ICO, PSD
- **Videos**: MP4, MOV, M4V, AVI, MKV, WMV, FLV, WebM, TS, MTS, M2TS, 3GP, 3G2, OGV, MXF, MPG, MPEG

For images, `DateTimeOriginal` maps to `EXIF:DateTimeOriginal`; for QuickTime videos (MP4, MOV, M4V), it maps to `QuickTime:CreationDate`; for other videos (AVI, MKV, etc.), ExifTool maps it to the container-specific tag. Description works on both, but videos only write to the `Description` tag (not `ImageDescription`/`Caption-Abstract`, which are EXIF/IPTC only).

**Unwritable formats**: AVI, MPG, and MPEG files can be read but not modified by ExifTool. The app detects these and skips them during save operations with a warning. These files are renamed via `FileManager` instead, using in-memory metadata.

---

## File Map

| File | Purpose |
|---|---|
| `ExifShell/ExifShell/ExifShellApp.swift` | `@main` entry point. Sets activation policy, brings app to front, sets default window size (1100×680). |
| `ExifShell/ExifShell/ContentView.swift` | Root view. Shows `DropZoneView` when empty, or `HSplitView` (table + preview) when files loaded. Owns all drop handling, status bar, app-wide keyboard shortcuts (⌘K, ⌘S, ⌫ Delete), and loading overlay. Bulk edit bars (`BulkEditDateBar`, `BulkEditDescriptionBar`) are separate view files. |
| `ExifShell/ExifShell/Models/ImageFile.swift` | `@Observable` class: `url`, `filename`, `mediaType`, `dateTimeOriginal`, `description` (both editable with dirty tracking), plus `readOnly: ReadOnlyMetadata` struct containing read-only fields (`createDate`, `modifyDate`, `imageDescription`, `captionAbstract`, `subject`, `keywords`, `lastKeywordXMP`, `thumbnail`, `duration`, `resolution`, `fileModifyDate`, `dateSource`, `cameraMake`, `cameraModel`). Generates thumbnails for videos via AVAssetImageGenerator. |
| `ExifShell/ExifShell/ViewModels/FileListViewModel.swift` | `@Observable` class: all state (`files[]`, `selectedFile`, `selectedFiles[]`, `bulkEditValue`, `bulkEditDescriptionValue`), import (batch full metadata read), select, save (saves date + description independently, handles image/video tag differences), clear, bulk edit (date & description with separate text fields), sanitise (with Phase 1 pre-write for filesystem-date files), rename. |
| `ExifShell/ExifShell/ViewModels/FileListViewModel+Save.swift` | Extension on `FileListViewModel` containing all save-related logic: `saveAll()`, `saveSelected()`, `saveAllAsync()`, `SaveFeedback`, `SaveGroupResult`, `markFilesClean()`. |
| `ExifShell/ExifShell/ViewModels/FileListViewModel+Rename.swift` | Extension on `FileListViewModel` containing all rename-related logic: `renameAll()`, `renameSelected()`, `renameAllAsync()`. |
| `ExifShell/ExifShell/Services/ExifToolService.swift` | Core shell wrapper: static methods for read/write/sanitise operations. All Process boilerplate centralised into `runReadTool` / `runWriteTool` helpers. Also contains shared infrastructure (`ReadResult`, `WriteResult`, `decoder`, `missingToolError`). |
| `ExifShell/ExifShell/Services/ExifToolService+Extensions.swift` | Extension on `ExifToolService` with media type helpers: `videoExtensions`, `quickTimeExtensions`, `unwritableVideoExtensions`, `splitByMediaType()`, `isUnwritableVideo()`, plus error parsing. |
| `ExifShell/ExifShell/Services/ExifToolService+ReadWrite.swift` | Extension on `ExifToolService` containing all read/write/sanitise operations: `readAllMetadata()` (batch full reads returning `[URL: FileMetadata]` with `DateSource` tracking), `readDateTimeOriginal()` (single/batch), `writeDateTimeOriginal()` (batch, splits images/videos by extension), `writeDescription()` (batch, videos get `-Description=` only), `writeQuickTimeCreationDate()` (sanitise pre-write), `sanitise()` (image-specific or video-specific pipelines). Also contains JSON decoding types: `FileMetadata`, `DateSource`, `DateTimeFallbackOutput`, `FullExifToolOutput` (with auto-synthesised `Core` + property wrappers for flexible fields). |
| `ExifShell/ExifShell/Services/ExifToolService+Rename.swift` | Extension on `ExifToolService` containing all rename-related functionality. Declares `RenameResult`, `RenameInput`, `renameFiles()`, `renameWritableFiles()` (ExifTool-based with pre-sorted tag passes), `renameUnwritableFiles()` (FileManager-based for AVI/MPEG), `detectTagCategories()` (single ExifTool read to classify files), `computeExpectedRenameURL()` (fallback path computation), `parseRenamedPaths()` (regex for `-v` output), `DateTagCategory` enum, and date/description formatters. |
| `ExifShell/ExifShell/Views/DropZoneView.swift` | Visual drop zone (drop handling in ContentView). |
| `ExifShell/ExifShell/Views/FileTableView.swift` | SwiftUI `List` with multi-select (`Set<ImageFile.ID>`), editable camera/date/description columns, orange text when dirty, sortable headers. |
| `ExifShell/ExifShell/Views/PreviewPanel.swift` | Thumbnail + diff review (date & description) + read-only metadata display. Action buttons in 2-column layout: Save Selected/All, Sanitise Selected/All, Rename Selected/All. Shows video badges (media type badge, duration, resolution) for `.video` files. Date/Time Original row shows a source badge (EXIF / CreateDate / File System) indicating where the date value came from. Camera Make/Model shown with SF icons. |
| `ExifShell/ExifShell/Views/BulkEditDateBar.swift` | Bulk edit bar for DateTimeOriginal values. Supports Set (enter a date string) and Offset (add/subtract time). Shown above the file table when 2+ files selected. |
| `ExifShell/ExifShell/Views/BulkEditDescriptionBar.swift` | Bulk edit bar for Description values. Shown below the date bar when 2+ files selected. |

---

## Conventions

### Adding a Read-Only Metadata Field (e.g. Camera Make)

1. **`ExifToolService+ReadWrite.swift`:**
   - Add the ExifTool tag (e.g. `-Make`) to `readAllTags` static let
   - Add `cameraMake: String?` to `FileMetadata` struct
   - Add `cameraMake` to `FullExifToolOutput.Core` CodingKeys (auto-synthesised)
   - Populate `cameraMake` in the metadata dictionary construction in `readAllMetadata()`
   - Add `cameraMake: nil` to `emptyMetadata()`

2. **`ImageFile.swift`:**
   - Add `var cameraMake: String?` to the `ReadOnlyMetadata` struct
   - No init parameter changes needed — `ReadOnlyMetadata()` initialises all to nil

3. **`FileListViewModel.swift`:**
   - Add `file.readOnly.cameraMake = m.cameraMake` in `applyMetadata()`
   - (Optional) Add a sort key in `SortKey` enum + `sortDescriptor` computed property

4. **`FileTableView.swift`:**
   - Add a column definition in `columnDefs`
   - Add `case "cameraMake":` in `tableView(_:viewFor:row:)`
   - Add the column key to `applySortIndicators` and `sortDescriptorsDidChange`

5. **`PreviewPanel.swift`:**
   - Add a `metadataRow(label:value:systemImage:)` call in the Metadata section

### Adding an Editable Metadata Field (e.g. Description)

1. **`ImageFile.swift`**: Add `var description: String` property + baseline tracking + dirty logic
2. **`ExifToolService+ReadWrite.swift`**: Add tag to `readAllTags` + `FileMetadata` + write method accepting `[URL]`
3. **`FileListViewModel.swift`**: Update `applyMetadata()` + save pipeline
4. **`FileTableView.swift`**: Add editable column with `@Bindable` binding
5. **`PreviewPanel.swift`**: Add diff section with `fieldDiffRow`

### Adding a new view
- Create file in `ExifShell/ExifShell/Views/`.
- Pass `FileListViewModel` with `@Bindable var viewModel: FileListViewModel`.
- Add it to `ContentView.swift` or nest inside an existing view.

### Adding a new media type
1. Add extensions to `ExifToolService+Extensions.swift`'s `videoExtensions` set (or create a new set).
2. Update `FileListViewModel.mediaType(for:)` and `isSupportedFile(_:)`.
3. For write operations, add the file type to `ExifToolService.videoExtensions` so `splitByMediaType` handles it.
4. For read operations, the `readAllTags` list in `ExifToolService+ReadWrite.swift` is universal (ExifTool reads all requested tags regardless of file type).
5. For sanitise, add a branch in `ExifToolService.sanitise(_:)` for the new media type.

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
- **Tag group:** Always use explicit group specifiers like `-EXIF:DateTimeOriginal=` for images, `-QuickTime:CreationDate=` for videos.
- **Mixed batches:** Use `splitByMediaType(_:)` to separate images from videos before write/sanitise operations.
- **Write exit codes:** `runWriteTool` treats exit code 1 as success because all write operations use `-m` (ignore minor errors). ExifTool exits with code 1 for minor warnings even when writes succeed — treating it as failure produces false error messages.
- **Read exit codes:** `runReadTool` treats non-empty stdout as success regardless of exit code, since ExifTool can emit valid JSON alongside warning exit codes.

---

## ExifTool Commands Used

| Operation | Command |
|---|---|
| Read (full batch) | `exiftool -json -DateTimeOriginal -QuickTime:CreationDate -CreateDate -ModifyDate -FileModifyDate -Description -ImageDescription -Caption-Abstract -Subject -Keywords -LastKeywordXMP -Duration -ImageWidth -ImageHeight -Make -Model <files...>` |
| Read (date only) | `exiftool -json -DateTimeOriginal <files...>` |
| Write (date batch, images) | `exiftool -overwrite_original -EXIF:DateTimeOriginal="<value>" -CreateDate="<value>" -ModifyDate="<value>" -OffsetTime= -OffsetTimeOriginal= -OffsetTimeDigitized= <files...>` |
| Write (date batch, QuickTime videos) | `exiftool -overwrite_original -QuickTime:CreationDate="<value>" -CreateDate="<value>" -ModifyDate="<value>" -MediaCreateDate="<value>" -MediaModifyDate="<value>" -TrackCreateDate="<value>" -TrackModifyDate="<value>" -DateTimeOriginal="<value>" <files...>` |
| Write (date batch, other videos) | `exiftool -overwrite_original -DateTimeOriginal="<value>" -CreateDate="<value>" -ModifyDate="<value>" <files...>` |
| Write (desc batch, images) | `exiftool -overwrite_original -Description="<value>" -ImageDescription="<value>" -Caption-Abstract="<value>" <files...>` |
| Write (desc batch, videos) | `exiftool -overwrite_original -Description="<value>" <files...>` |
| Sanitise (images) | `exiftool -overwrite_original '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' '-CreateDate<DateTimeOriginal' '-ModifyDate<DateTimeOriginal' -OffsetTime= -OffsetTimeOriginal= -OffsetTimeDigitized= '-ImageDescription<Description' '-Caption-Abstract<Description' <files...>` |
| Sanitise (QuickTime videos) | `exiftool -overwrite_original '-QuickTime:CreationDate<${QuickTime:CreationDate;DateFmt("%Y:%m:%d %H:%M:%S")}' '-CreateDate<QuickTime:CreationDate' '-ModifyDate<QuickTime:CreationDate' '-MediaCreateDate<QuickTime:CreationDate' '-MediaModifyDate<QuickTime:CreationDate' '-TrackCreateDate<QuickTime:CreationDate' '-TrackModifyDate<QuickTime:CreationDate' <files...>` |
| Sanitise (other videos) | `exiftool -overwrite_original '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' '-CreateDate<DateTimeOriginal' '-ModifyDate<DateTimeOriginal' <files...>` |
| Rename (tag-specific passes) | `exiftool -v -m "-FileName<${CreateDate}_%03.c${Description;if($_){s/'//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g;$_="_ ".$_}}.%e" -d %Y_%m_%d_%H%M <files...>` |

---

## Key Architecture Points

### @Observable (not ObservableObject)
All models and the view model use the `@Observable` macro (macOS 14+). This means:
- Views use `let viewModel: FileListViewModel` not `@ObservedObject`
- Nested views that need bindings use `@Bindable var viewModel: FileListViewModel`
- Bindings use `@Bindable var bindableFile = file` then `$bindableFile.dateTimeOriginal` / `$bindableFile.description`
- No need for `@Published` or `objectWillChange`

### ExifTool Path Resolution
The static property `exifToolPath` is resolved once at startup by checking:
1. PATH entries from `ProcessInfo.processInfo.environment["PATH"]`
2. `/opt/homebrew/bin/exiftool` (Apple Silicon Homebrew)
3. `/usr/local/bin/exiftool` (Intel Homebrew)
4. `/usr/bin/exiftool`
5. `/opt/local/bin/exiftool` (MacPorts)
6. Homebrew `libexec/bin` locations and Cellar fallback paths

This is intentionally more robust than a simple `which exiftool` probe because Xcode can launch the app without the same shell PATH you have in Terminal. If not found, `missingToolError` returns a descriptive message and all read/write operations return nil/failure.

### Full Metadata Batch Read
`ExifToolService.readAllMetadata(from:)` processes all files in a single process invocation, reading 17 tags via the `readAllTags` static let (including `FileModifyDate` for the filesystem fallback, plus `Make`/`Model` for camera metadata). Returns `FileMetadata` with a `dateSource: DateSource?` field indicating which tag provided the `dateTimeOriginal` value (`.dateTimeOriginal`, `.createDate`, or `.fileModifyDate`). Includes video-specific fields: Duration, ImageWidth, ImageHeight, and camera fields: cameraMake, cameraModel.

### ReadOnlyMetadata Struct
Read-only fields are grouped into `ReadOnlyMetadata` struct in `ImageFile.swift`:
- Access via `file.readOnly.createDate`, `file.readOnly.cameraModel`, etc.
- Initialised in `applyMetadata()` in `FileListViewModel` via `ReadOnlyMetadata(createDate: ..., cameraMake: ...)`
- Keypaths for sorting: `\ImageFile.readOnly.cameraModel`
- The `static let empty = ReadOnlyMetadata()` factory provides a nil-defaults value

### Table Refresh from Bulk Edits
The file table uses a cached `sortedFiles` property in the ViewModel. Bulk edit methods (`applyBulkEditDescription`, `applyBulkSet`, `applyBulkOffset`, `copyDateFieldToDateTimeOriginal`) call `invalidateSort()` after modifying file values to trigger a table refresh. The `FileTableView.body` reads `viewModel.sortedFiles` so SwiftUI observes `_sortVersion` changes and re-invokes `updateNSView` → `tableView.reloadData()`.

### Camera Metadata
Camera Make and Model are read-only fields read from ExifTool's `-Make` and `-Model` tags during the full metadata batch read. They are stored in `ImageFile.readOnly.cameraMake` and `ImageFile.readOnly.cameraModel`. In the table, the "Camera" column displays the camera model name (most identifiable), with the full `Make Model` shown in a tooltip. The preview panel shows both fields as separate read-only rows with SF icons (`camera` and `camera.viewfinder`). A `.camera` sort key sorts files by model name alphabetically.

### Media Type Detection
Media type is determined from file extension:
- `FileListViewModel.mediaType(for:)` returns `.image` or `.video`
- `ExifToolService.splitByMediaType(_:)` splits URLs into three buckets: images, QuickTime videos (MP4/MOV/M4V), and other videos
- QuickTime videos get `QuickTime:CreationDate` for date writes and sanitise, images get `EXIF:DateTimeOriginal`
- Other videos (MKV, WebM, FLV, etc.) use `DateTimeOriginal` (mapped to the container-specific tag by ExifTool)

### FullExifToolOutput Decoder Architecture
`FullExifToolOutput` uses a two-part decoding strategy:
- **`Core` struct**: Auto-synthesised `Decodable` for simple string fields (11 fields: sourceFile, dates, description, camera)
- **Flexible property wrappers**: `@FlexibleStringArray` (String-or-[String]), `@FlexibleDuration` (String-or-Double seconds), `@FlexibleString` (String-or-Int)
- Missing optional fields are decoded with `decodeIfPresent` so a file that lacks `Subject`, `Keywords`, `Duration`, `ImageWidth`, or `ImageHeight` does not cause the whole batch read to fail
- This eliminates ~50 lines of manual decoding boilerplate while staying resilient to ExifTool output variations

### Multi-Select & Bulk Edit
- `FileTableView` uses `Set<ImageFile.ID>` for selection.
- `FileListViewModel.selectedFiles` tracks multi-selection.
- `ContentView` shows two bulk edit bars when `selectedFiles.count > 1`:
  - `BulkEditDateBar` (accent-tinted) — sets DateTimeOriginal on all selected files.
  - `BulkEditDescriptionBar` (green-tinted) — sets Description on all selected files.

### Delete / Remove Selected Files
- `FileListViewModel.removeSelected()` removes all files whose IDs are in `selectedFiles`.
- `ContentView` has a hidden button bound to `⌫ Delete` keyboard shortcut (no modifier).
- This is distinct from `⌘K` (clear all) — delete only removes selected files.

### Sanitise Pipeline
- `ExifToolService.sanitise(_ urls:)` runs the full sanitise in one ExifTool invocation per media type:
  - **Images**: Normalises DateTimeOriginal format via `DateFmt("%Y:%m:%d %H:%M:%S")`, propagates to CreateDate/ModifyDate, clears OffsetTime* tags, syncs Description to ImageDescription/Caption-Abstract
  - **QuickTime Videos**: Normalises QuickTime:CreationDate via `DateFmt`, propagates to CreateDate/ModifyDate, syncs Description (no offset tags)
  - **Other Videos (MKV, WebM, AVI, etc.)**: Normalises DateTimeOriginal via `DateFmt`, propagates to CreateDate/ModifyDate, syncs Description
- `FileListViewModel.sanitiseSelected()` operates on the **currently selected files** (from `selectedFiles`). It first saves any dirty files, then runs a **Phase 1 pre-write** for files whose `dateSource == .fileModifyDate` — these have no embedded date tag on disk, so the main sanitise pipeline would silently do nothing. Each file's own in-memory dateTimeOriginal is written (timezone stripped via `ExifToolService.stripTimezone()`) to the appropriate tag (QuickTime:CreationDate for QuickTime videos, DateTimeOriginal for other videos/images), grouped by stripped value for batching. Then the main pipeline processes files in **batches of 80** with live determinate progress (`"Sanitising (X/Y)..."`), skips unwritable formats (AVI, MPEG) with a warning, then re-reads all metadata from disk to refresh the display.
- `FileListViewModel.sanitiseAll()` runs the same sanitise pipeline for all loaded files, not just selected files.
 - The "Sanitise Selected" button appears in the PreviewPanel alongside Save and Rename buttons, using the `wand.and.rays` SF Symbol.
 - **Note:** The `-Description<Description` self-copy has been removed from video sanitise commands — videos only have one `Description` tag, making the self-copy a no-op that could produce warnings in some containers.

### Rename Pipeline
- Rename logic lives in `ExifToolService+Rename.swift` as an extension on `ExifToolService`.
- **Entry point**: `renameFiles(_ inputs:, progressHandler:)` accepts `[RenameInput]` (URL + in-memory dateTimeOriginal + description).
- **Split**: Writable files (all formats except AVI/MPEG) go to `renameWritableFiles()`; unwritable files (AVI, MPEG) go to `renameUnwritableFiles()` which renames via `FileManager` using in-memory metadata.
- **Pre-sort optimisation**: Instead of running 3 blind ExifTool passes (filtered by `-if`), `detectTagCategories()` runs a single ExifTool read to classify files by which date tag they have (`CreateDate`, `DateTimeOriginal`, or `FileModifyDate`). Then only the needed passes are dispatched — for a batch where every file has CreateDate (the common case), this means 1 ExifTool pass instead of 3.
- **Each pass** runs: `exiftool -v -m "-FileName<${TAG}_%03.c{Description;...}.%e" -d %Y_%m_%d_%H%M <files...>` with the appropriate tag (`CreateDate`, `DateTimeOriginal`, or `FileModifyDate`).
- **Path mapping**: ExifTool's `-v` output is parsed via the regex `'([^']+)'\s*-+>\s*'([^']+)'`. Each mapped new path is validated with `FileManager.default.fileExists(atPath:)` to discard false positives. For files where the regex missed a mapping (the old path no longer exists but wasn't captured), `computeExpectedRenameURL()` calculates the expected destination using in-memory metadata + a per-directory counter.
- `FileListViewModel.renameAll()` first saves any dirty files, then processes files in **batches of 80** with live determinate progress (`"Renaming (X/Y)..."`), and updates the in-memory URL for each renamed file from the path mapping returned by ExifTool.

### Video Thumbnails
- `ImageFile.generateThumbnail(for:mediaType:)` extracts the first frame using `AVAssetImageGenerator` for videos.
- If frame extraction fails, `thumbnail` is `nil` and `PreviewPanel` shows a `film` icon with "Video" text.
- Duration is parsed from ExifTool's `-Duration` output (handles both string "0:02:30" and numeric seconds).

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

### Save & Rename Logic (Selected vs All)
 - PreviewPanel has a 2-column button layout: "Save Selected (N)" | "Save All (N)" and "Rename Selected" | "Rename All", plus "Sanitise Selected" full width
 - `saveAll()` / `saveSelected()` — both use `saveAllAsync(only:)` with an optional file list parameter. When `only` is provided, only those files are considered.
 - `renameAll()` / `renameSelected()` — both use `renameAllAsync(only:)` with the same pattern
 - Independently groups date-changed files by value and desc-changed files by value for batch writes
 - Tracks separate save feedback for date and description
 - Feedback clears on navigation via `selectedFile.didSet`
 - App-wide `⌘S` shortcut is bound to `saveAll()`

---

## Common Edit Scenarios

### "Fix write targeting a different field"
Edit `ExifToolService+ReadWrite.swift` — make sure the tag argument uses an explicit group specifier like `-EXIF:DateTimeOriginal=` for images or `-QuickTime:CreationDate=` for videos, not just `-DateTimeOriginal=`.

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

### "Add a new video format"
1. Add the extension to both `FileListViewModel.videoExtensions` and `ExifToolService.videoExtensions` (in `ExifToolService+Extensions.swift`).
2. If the format uses QuickTime containers, add it to `ExifToolService.quickTimeExtensions`.
3. If ExifTool cannot write to the format (e.g. AVI/RIFF), add it to `ExifToolService.unwritableVideoExtensions`.
4. `splitByMediaType` and `mediaType(for:)` will handle the rest automatically.

### "AVI/MPG/MPEG files can't be written"
ExifTool has a known limitation: it cannot write to RIFF/AVI or MPEG containers. This is handled at two levels:
- `ExifToolService.isUnwritableVideo()` identifies AVI, MPG, and MPEG files by extension
- `FileListViewModel.saveAllAsync()` filters them out before writing and shows a warning: "⚠️ N file(s) skipped (ExifTool cannot write AVI/MPEG containers)."
- These files remain dirty (not marked clean) since their changes weren't saved
- During rename, unwritable files are instead renamed via `FileManager` using `renameUnwritableFiles()`, which generates the target filename in Swift from in-memory metadata.

### "MPG/MPEG files have no embedded date — how do they get a DateTimeOriginal?"
MPG and MPEG files typically have no `DateTimeOriginal`, `CreateDate`, or `ModifyDate` EXIF tags. The app uses a three-level fallback chain in `readAllMetadata()`:
1. `DateTimeOriginal` (preferred — embedded EXIF date)
2. `CreateDate` (fallback for videos without DateTimeOriginal)
3. `FileModifyDate` (last resort — filesystem modification timestamp from ExifTool's `File:FileModifyDate` tag)

When `FileModifyDate` is used, the `dateSource` property is set to `.fileModifyDate`, and the Preview Panel shows an orange "File System" badge next to the Date/Time Original label to indicate the date came from the filesystem, not embedded metadata. The rename pipeline also has a third pass (`FileModifyDate`) for files with no embedded date tags.

### "Copy error details to clipboard"
Error messages from failed save/rename operations are stored in `viewModel.lastErrorDetail`. A copy button (doc.on.doc icon) appears next to error status messages in both the ContentView status bar and PreviewPanel. Clicking it copies the full ExifTool error output to the clipboard via `NSPasteboard`.

### "Fix empty fields when running from Xcode"
This is fixed — `ExifToolService.exifToolPath` auto-resolves the binary path. No `/usr/bin/env` or PATH dependency.

---

## Search Patterns

| What you're looking for | Grep pattern | File |
|---|---|---|
| Where ExifTool reads Make/Model tags | `-Make` or `-Model` | `ExifToolService+ReadWrite.swift` |
| Where `readAllTags` static let is defined | `readAllTags` | `ExifToolService+ReadWrite.swift` |
| Where Camera column is rendered | `case "camera"` | `FileTableView.swift` |
| Where Camera metadata is shown in preview | `cameraMake` or `.camera.viewfinder` | `PreviewPanel.swift` |
| Where sort keys are defined | `enum SortKey` | `FileListViewModel.swift` |
| Where ExifTool process is spawned | `runReadTool` or `runWriteTool` | `ExifToolService.swift` |
| Where `ReadOnlyMetadata` is defined | `struct ReadOnlyMetadata` | `ImageFile.swift` |
| Where `applyMetadata()` maps service→model | `applyMetadata` | `FileListViewModel.swift` |
| Where save pipeline lives | `saveAllAsync` | `FileListViewModel+Save.swift` |
| Where rename pipeline lives | `renameFiles` | `ExifToolService+Rename.swift` |
| Where bulk edit bars are used | `BulkEditDateBar` or `BulkEditDescriptionBar` | `ContentView.swift` |
| Where video extensions are listed | `videoExtensions` | `ExifToolService+Extensions.swift` |
| Where `dateSource` badge text is generated | `dateSourceLabel` | `ImageFile.swift` |

---

## Build

```bash
# Build Release + copy to ~/Downloads + open the app
make

# Build only (Release)
make build

# Copy the already-built .app to ~/Downloads
make install

# Build, install to ~/Downloads, and open
make run

# Remove the app from ~/Downloads
make clean
```

The Makefile uses `xcodebuild` under the hood — no Xcode GUI required. It dynamically resolves the `DerivedData` build output path so the `install` target always copies the correct `.app`.

Requires macOS 14+ and `exiftool` on PATH (for the `which` fallback; common Homebrew paths are checked directly).
