# ExifShell — Project Brief

## 🎯 Purpose

ExifShell is a minimal, high-speed macOS application for inspecting and editing image metadata using ExifTool as its backend.

The goal is to make editing metadata — especially `DateTimeOriginal` and `Description` — as fast, intuitive, and low-friction as renaming a file in Finder.

This tool replaces repetitive terminal workflows with a visual interface while preserving the power and flexibility of ExifTool.

---

## ⚡ Core Philosophy

* **Speed over completeness**
* **Clarity over flexibility**
* **Batch power, single-file precision**
* **WYSIWYG editing (no mental translation from terminal syntax)**

If a feature slows down the act of editing metadata, it should not exist.

---

## 👤 Primary Use Case

A user is managing tens of thousands of images with inconsistent or incorrect metadata.

They need to:

* Inspect metadata quickly
* Correct time/date fields
* Add descriptions
* Sync metadata fields
* Apply changes across multiple files efficiently

---

## 🔁 Current Workflow (Problem)

The current process involves:

1. Running terminal commands to inspect metadata
2. Manually parsing output
3. Running separate commands to:

   * Fix dates
   * Adjust timezones
   * Sync fields
   * Add descriptions
4. Repeating this process across thousands of files

### Pain Points

* Slow iteration loop
* High cognitive load (parsing terminal output)
* Error-prone (formatting, overwrites)
* No visual feedback
* Difficult to batch with confidence

---

## 🚀 Desired Outcome

A tool where the user can:

* Drag in files or folders
* Instantly see key metadata
* Click a file and preview it
* Edit fields inline
* Apply changes immediately or in batch

With zero need to think about:

* ExifTool syntax
* Date formatting
* Field syncing rules

---

## 🧭 User Journey

### 1. Import

* User drags files or folders into the app
* Files are recursively loaded

---

### 2. Inspect

* Files appear in a table view:

  * Filename
  * DateTimeOriginal
  * Description (Phase 2)
* Selecting a file shows:

  * Thumbnail preview
  * Editable metadata fields

---

### 3. Edit

* User clicks into a field (e.g. DateTimeOriginal)
* Edits value directly
* App automatically formats input correctly

---

### 4. Apply

User can:

* Apply changes to selected files
* Apply changes to all files
* Use keyboard shortcut (⌘S)

---

### 5. Batch Operations (Phase 2)

* Sync DateTimeOriginal → CreateDate → ModifyDate
* Copy between fields
* Clear offsets
* Apply descriptions across multiple files

---

## 🧱 Feature Roadmap

---

### 🟢 Phase 1 — Minimal Viable Tool

**Goal:** Replace terminal for basic date editing

#### Features

* Drag & drop files/folders
* File list (table):

  * Filename
  * DateTimeOriginal
* File selection (single and multi-select via ⌘+click)
* Thumbnail preview (single image)
* Editable DateTimeOriginal field (inline in table)
* **Bulk edit** — set DateTimeOriginal on multiple selected files at once
* Batch ExifTool reads — all files processed in a single command for speed
* Apply changes:

  * ⌘S (app-wide shortcut)
  * Save button in preview panel
* ⌘K — clear all files / reset to drop zone

#### Backend (via ExifTool)

* Read:

  ```bash
  exiftool -json FILE
  ```
* Write:

  ```bash
  exiftool -overwrite_original -DateTimeOriginal="..." FILE
  ```

---

### 🟡 Phase 2 — Productivity Layer

**Goal:** Eliminate repetitive metadata operations

#### Additional Fields

* CreateDate
* ModifyDate
* Description

#### Features

* Smart actions:

  * Sync all date fields
  * Copy CreateDate → DateTimeOriginal
  * Clear OffsetTime fields
* Description writing across EXIF/IPTC/XMP
* Column sorting in file table

#### Example Write Logic

```bash
exiftool -overwrite_original \
'-CreateDate<DateTimeOriginal' \
'-ModifyDate<DateTimeOriginal' \
FILE
```

---

### 🔵 Phase 3 — Advanced Automation (Optional)

**Goal:** Automate complex workflows

#### Potential Features

* GPS → timezone offset correction
* Bulk metadata sanitisation
* Missing metadata detection
* Filename generation based on metadata

#### Example Use Cases

* Identify files missing DateTimeOriginal
* Normalize all metadata formats
* Apply timezone corrections based on location

---

## 🧰 Parallel Tooling (Shell Layer)

ExifShell does not replace shell scripts—it complements them.

Power operations remain in terminal:

### Find missing metadata

```bash
exiftool -r -if 'not $DateTimeOriginal' -filename DIR/
```

### Clean XMP data

```bash
exiftool -overwrite_original -XMP:All= DIR/
```

### Sync date fields

```bash
exiftool -r -overwrite_original \
'-CreateDate<DateTimeOriginal' \
'-ModifyDate<DateTimeOriginal' DIR/
```

---

## 🧠 Key Design Decisions

### 1. Minimal UI

* No clutter
* No unnecessary metadata fields
* No overwhelming panels

---

### 2. Finder-like Interaction

* Click to select
* Click to edit
* Press Enter to confirm

---

### 3. Controlled Scope

* Focus on metadata editing only
* No GPS editing (handled externally via GeoTag)
* No DAM features (no library management)

---

### 4. Trust ExifTool

All metadata logic is delegated to ExifTool.

ExifShell is:

> A visual control layer, not a metadata engine

---

## ⚠️ Non-Goals

* Full digital asset management system
* Replacement for tools like:

  * Adobe Bridge
  * Photo Mechanic
* Advanced image organisation workflows
* Cloud syncing or database storage

---

## 🔥 Success Criteria

* Editing metadata is faster than using Terminal
* User can process hundreds of images per session without fatigue
* No need to reference ExifTool documentation during normal use
* The tool feels invisible — just an extension of Finder

---

## 🧭 Guiding Question

> Does this feature make editing metadata faster and simpler?

If not, it should not be built.
