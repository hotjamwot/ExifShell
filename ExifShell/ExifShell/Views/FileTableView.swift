import SwiftUI
import AppKit

// ============================================================================
// FileTableView
// ============================================================================
// The editable file list shown in the left pane of the HSplitView.
// Uses an NSTableView (via NSViewRepresentable) for:
//   - Native column resizing by dragging column-header dividers
//   - Built-in horizontal + vertical scrolling (NSScrollView)
//   - Native sort indicator arrows on column headers
//   - Editable text fields for DateTimeOriginal and Description
//
// Columns:
//   - Filename (read-only, sortable, truncates middle)
//   - DateTimeOriginal (editable, monospaced, orange when dirty)
//   - Description (editable, monospaced, orange when dirty)
//   - Camera (read-only, shows model name, tooltip with Make + Model)
//
// Selection syncs to:
//   - viewModel.selectedFile (first selected → preview panel)
//   - viewModel.selectedFiles (all selected → bulk edit bars)
//
// Sort syncs to:
//   - viewModel.sortKey / viewModel.sortAscending (via column header clicks)
//
// Types consumed:
//   - FileListViewModel (ExifShell/ViewModels/FileListViewModel.swift)
//   - ImageFile (ExifShell/Models/ImageFile.swift)
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
//
// ===== NSTableView Cell Reuse =====
// Cell identifiers are based solely on the column ID (e.g. "filename",
// "dateTimeOriginal", "description") so NSTableView can recycle views
// across rows. tableView.makeView(withIdentifier:owner:) is used to
// dequeue a reusable cell; a new one is only created when the queue
// is empty. This avoids destroying and recreating every cell on each
// reloadData(), which previously happened because identifiers included
// the row index ("\(columnID)_\(row)").
//
// ===== Hover Highlight =====
// A custom HoverableTableRowView is used as the row view, which tracks
// mouse hover via NSTrackingArea and applies a subtle background highlight
// when the mouse is over the row. This gives a polished, native-feeling
// hover effect without affecting selection highlighting.
// ============================================================================

struct FileTableView: View {
    let viewModel: FileListViewModel

    var body: some View {
        // Read sortedFiles here so SwiftUI tracks _sortVersion as a dependency
        // and re-invokes updateNSView whenever the sort cache is invalidated.
        let _ = viewModel.sortedFiles
        FileTableNSView(viewModel: viewModel)
    }
}

// MARK: - NSViewRepresentable

private struct FileTableNSView: NSViewRepresentable {
    let viewModel: FileListViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 26

        let columnDefs: [(id: String, title: String, width: CGFloat, sortKey: String)] = [
            ("filename",          "Filename",              160, "filename"),
            ("dateTimeOriginal",  "Date/Time Original",    180, "dateTimeOriginal"),
            ("description",       "Description",           280, "description"),
            ("camera",            "Camera",                140, "camera"),
            ("type",              "Type",                  80,  "type"),
        ]

        for def in columnDefs {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.width = def.width
            col.minWidth = 80
            col.resizingMask = [.userResizingMask, .autoresizingMask]
            col.sortDescriptorPrototype = NSSortDescriptor(key: def.sortKey, ascending: true)
            tableView.addTableColumn(col)
        }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator
        coordinator.files = viewModel.sortedFiles

        let sortChanged = coordinator.sortKey != viewModel.sortKey
            || coordinator.sortAscending != viewModel.sortAscending
        coordinator.sortKey = viewModel.sortKey
        coordinator.sortAscending = viewModel.sortAscending

        // Preserve selection across reload
        let savedSelection = tableView.selectedRowIndexes

        tableView.reloadData()

        if savedSelection.count > 0 {
            tableView.selectRowIndexes(savedSelection, byExtendingSelection: false)
        }

        // Update sort indicator arrows
        if sortChanged {
            applySortIndicators(tableView)
        }
    }

    private func applySortIndicators(_ tableView: NSTableView) {
        let key: String
        switch viewModel.sortKey {
        case .filename:         key = "filename"
        case .originalDateTime: key = "dateTimeOriginal"
        case .description:      key = "description"
        case .camera:           key = "camera"
        case .mismatched:       key = "type"
        }
        let desired = NSSortDescriptor(key: key, ascending: viewModel.sortAscending)
        if tableView.sortDescriptors.first?.key != key
            || tableView.sortDescriptors.first?.ascending != viewModel.sortAscending {
            tableView.sortDescriptors = [desired]
        }
    }
}

// MARK: - FilenameCellView

/// A dedicated cell view for the Filename column that includes a pre-built
/// warning label (⚠️) for extension mismatches.
///
/// The warning label is always present as a subview but toggled via `isHidden`.
/// This avoids the fragile pattern of dynamically adding/removing subviews
/// during cell reuse, which previously removed ANY `NSTextField` subview
/// that wasn't the cell's `textField` and leaked Auto Layout constraints
/// when the warning was removed.
private final class FilenameCellView: NSTableCellView {
    /// The warning label shown when the file has a mismatched extension.
    private let warningLabel = NSTextField(labelWithString: "⚠️")

    /// Constraint references so we can toggle without creating duplicates.
    private var warningTrailingConstraint: NSLayoutConstraint?
    private var warningCenterYConstraint: NSLayoutConstraint?
    private var textToWarningConstraint: NSLayoutConstraint?
    private var textToTrailingConstraint: NSLayoutConstraint?

    /// Sets the warning label's visibility without adding/removing subviews.
    /// When hidden, the text field's trailing constraint returns to the
    /// cell's trailing edge (the warning constraints are deactivated).
    var isWarningVisible: Bool = false {
        didSet {
            guard isWarningVisible != oldValue else { return }
            warningLabel.isHidden = !isWarningVisible

            warningTrailingConstraint?.isActive = isWarningVisible
            warningCenterYConstraint?.isActive = isWarningVisible
            textToWarningConstraint?.isActive = isWarningVisible
            textToTrailingConstraint?.isActive = !isWarningVisible
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        tf.lineBreakMode = .byTruncatingMiddle

        addSubview(tf)
        textField = tf

        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        warningLabel.isHidden = true
        addSubview(warningLabel)

        // Pre-build all constraints but keep the warning ones inactive
        // until isWarningVisible = true.
        textToTrailingConstraint = tf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        warningTrailingConstraint = warningLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        warningCenterYConstraint = warningLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        textToWarningConstraint = tf.trailingAnchor.constraint(lessThanOrEqualTo: warningLabel.leadingAnchor, constant: -4)

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
            textToTrailingConstraint!,
        ])

        // Pre-build the warning label (hidden by default).
        // Its constraints are inactive so hidden cells don't participate in layout.
        warningLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the cell's text and warning visibility for reuse.
    func configure(text: String, warningText: String?, warningToolTip: String?) {
        textField?.stringValue = text
        if let warningText {
            warningLabel.stringValue = warningText
            warningLabel.toolTip = warningToolTip
            isWarningVisible = true
        } else {
            isWarningVisible = false
        }
    }
}

// MARK: - HoverableTableRowView

/// A custom NSTableRowView that highlights on mouse hover.
/// Uses NSTrackingArea to detect mouse enter/exit and applies a subtle
/// background color change. The highlight is independent of selection state.
private class HoverableTableRowView: NSTableRowView {
    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove existing tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveApp, .assumeInside]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func drawBackground(in rect: NSRect) {
        // Let NSTableView draw the alternating row background first
        super.drawBackground(in: rect)

        // If hovered and not selected, draw a subtle highlight
        if isHovered && !isSelected {
            NSColor.selectedControlColor.withAlphaComponent(0.12).setFill()
            rect.fill(using: .sourceOver)
        }
    }

    override var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }
}

// MARK: - Coordinator (DataSource + Delegate)

extension FileTableNSView {

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        let viewModel: FileListViewModel
        weak var tableView: NSTableView?
        var files: [ImageFile] = []
        var sortKey: FileListViewModel.SortKey = .filename
        var sortAscending = true

        init(viewModel: FileListViewModel) {
            self.viewModel = viewModel
        }

        // MARK: Data Source

        func numberOfRows(in tableView: NSTableView) -> Int {
            files.count
        }

        // MARK: Delegate — Cell View

        func tableView(_ tableView: NSTableView,
                        viewFor tableColumn: NSTableColumn?,
                        row: Int) -> NSView?
        {
            guard let columnID = tableColumn?.identifier.rawValue,
                  row < files.count else { return nil }

            let file = files[row]
            // Stable identifier based solely on column ID, not row index.
            // This lets NSTableView reuse cells across rows.
            let cellID = NSUserInterfaceItemIdentifier(columnID)

            switch columnID {

            case "filename":
                let cell = dequeueFilenameCell(
                    tableView: tableView,
                    id: cellID,
                    text: file.filename,
                    warningText: file.hasMismatchedExtension ? "⚠️" : nil,
                    warningToolTip: file.mismatchDescription
                )
                cell.textField?.toolTip = file.hasMismatchedExtension
                    ? "\(file.mismatchDescription ?? "Extension mismatch") — click Fix Extension in the preview to correct"
                    : file.filename
                return cell

            case "camera":
                // Show camera model only (most identifiable), fall back to make if no model
                let displayText = file.readOnly.cameraModel ?? file.readOnly.cameraMake ?? "—"
                let cell = dequeueTextCell(tableView: tableView, id: cellID, text: displayText)
                cell.textField?.lineBreakMode = .byTruncatingMiddle
                cell.textField?.toolTip = {
                    switch (file.readOnly.cameraMake, file.readOnly.cameraModel) {
                    case let (make?, model?): return "\(make) \(model)"
                    case let (make?, nil):    return make
                    case let (nil, model?):   return model
                    default:                  return nil
                    }
                }()
                return cell

            case "type":
                // Show the actual detected file type (e.g. "JPEG", "HEIC", "PNG").
                // When there's a mismatch, show the actual type in orange.
                let displayText = file.readOnly.actualFileType ?? "—"
                let cell = dequeueTextCell(tableView: tableView, id: cellID, text: displayText)
                cell.textField?.textColor = file.hasMismatchedExtension ? .orange : .labelColor
                cell.textField?.toolTip = file.hasMismatchedExtension
                    ? "Actual type: \(displayText) — filename suffix doesn't match"
                    : "Actual file type detected by ExifTool"
                return cell

            case "dateTimeOriginal":
                // Prepend warning emoji when the date format is invalid
                let displayText = file.dateNeedsFix ? "⚠️ \(file.dateTimeOriginal)" : file.dateTimeOriginal
                let cell = dequeueEditableCell(tableView: tableView, id: cellID,
                                                text: displayText,
                                                dirty: file.isDirty || file.dateNeedsFix,
                                                columnID: columnID, row: row)
                cell.textField?.toolTip = file.dateNeedsFix
                    ? "Invalid date format — use the Fix Date/Time action in the preview to correct"
                    : "DateTimeOriginal (EXIF tag)"
                return cell

            case "description":
                let cell = dequeueEditableCell(tableView: tableView, id: cellID,
                                                text: file.description,
                                                dirty: file.isDirty,
                                                columnID: columnID, row: row)
                cell.textField?.toolTip = "Description — written to Description, ImageDescription & Caption-Abstract on save"
                return cell

            default:
                return nil
            }
        }

        func tableView(_ tableView: NSTableView,
                        shouldEdit tableColumn: NSTableColumn?,
                        row: Int) -> Bool
        {
            guard let id = tableColumn?.identifier.rawValue else { return false }
            return id == "dateTimeOriginal" || id == "description"
        }

        // MARK: Delegate — Sort

        func tableView(_ tableView: NSTableView,
                        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor])
        {
            guard let desc = tableView.sortDescriptors.first,
                  let key = desc.key else { return }

            switch key {
            case "filename":         viewModel.sortKey = .filename
            case "dateTimeOriginal": viewModel.sortKey = .originalDateTime
            case "description":      viewModel.sortKey = .description
            case "camera":           viewModel.sortKey = .camera
            case "type":             viewModel.sortKey = .mismatched
            default:                 return
            }
            viewModel.sortAscending = desc.ascending
        }

        // MARK: Delegate — Row View (Hover Highlight)

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            // Return a custom row view with hover tracking.
            // NSTableView handles recycling internally for row views.
            return HoverableTableRowView()
        }

        // MARK: Delegate — Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView else { return }

            let matched = tv.selectedRowIndexes.compactMap { idx -> ImageFile? in
                idx < files.count ? files[idx] : nil
            }

            viewModel.select(matched.first)
            viewModel.selectedFiles = matched
        }

        // MARK: Editing

        @objc private func textFieldEdited(_ sender: NSTextField) {
            let row = sender.tag
            guard row < files.count else { return }
            let file = files[row]
            let newValue = sender.stringValue

            switch sender.identifier?.rawValue {
            case "dateTimeOriginal" where file.dateTimeOriginal != newValue:
                file.dateTimeOriginal = newValue
            case "description" where file.description != newValue:
                file.description = newValue
            default:
                return
            }

            // Mark this field dirty immediately
            sender.textColor = .orange
            // Also update the sibling editable column in the same row
            markRowDirty(row: row)
        }

        /// Sets the text color of both editable columns in a row to orange.
        private func markRowDirty(row: Int) {
            guard let tv = tableView,
                  let rowView = tv.rowView(atRow: row, makeIfNecessary: false) else { return }

            for colIdx in 0..<tv.tableColumns.count {
                let colID = tv.tableColumns[colIdx].identifier.rawValue
                if colID == "dateTimeOriginal" || colID == "description",
                   let cell = rowView.view(atColumn: colIdx) as? NSTableCellView,
                   let tf = cell.textField {
                    tf.textColor = .orange
                }
            }
        }

        // MARK: Cell Factories — With NSTableView Reuse

        /// Dequeues or creates a plain read-only text cell for the given column identifier.
        /// Uses `tableView.makeView(withIdentifier:owner:)` so views are recycled.
        private func dequeueTextCell(tableView: NSTableView,
                                      id: NSUserInterfaceItemIdentifier,
                                      text: String,
                                      textColor: NSColor? = nil,
                                      toolTip: String? = nil) -> NSTableCellView
        {
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                existing.textField?.stringValue = text
                if let textColor {
                    existing.textField?.textColor = textColor
                }
                if let toolTip {
                    existing.textField?.toolTip = toolTip
                }
                return existing
            }

            let cell = NSTableCellView()
            cell.identifier = id

            let tf = NSTextField(labelWithString: text)
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: NSFont.systemFontSize)
            tf.lineBreakMode = .byTruncatingMiddle

            cell.addSubview(tf)
            cell.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: Context Menu

        func tableView(_ tableView: NSTableView, menuForRows rows: IndexSet) -> NSMenu? {
            guard let firstRow = rows.first, firstRow < files.count else { return nil }
            let file = files[firstRow]

            let menu = NSMenu()

            if file.hasMismatchedExtension {
                let fixItem = NSMenuItem(
                    title: "Fix Extension",
                    action: #selector(fixExtensionForRow(_:)),
                    keyEquivalent: ""
                )
                fixItem.target = self
                fixItem.tag = firstRow
                fixItem.toolTip = file.mismatchDescription
                menu.addItem(fixItem)
                menu.addItem(.separator())
            }

            if file.dateNeedsFix {
                let fixDTOItem = NSMenuItem(
                    title: "Fix Date/Time Format",
                    action: #selector(fixDTOForRow(_:)),
                    keyEquivalent: ""
                )
                fixDTOItem.target = self
                fixDTOItem.tag = firstRow
                fixDTOItem.toolTip = file.dateFixDescription
                menu.addItem(fixDTOItem)
                menu.addItem(.separator())
            }

            // Provide sort-by-type for the current file's actual type
            let sortItem = NSMenuItem(
                title: "Sort by Mismatched",
                action: #selector(sortByMismatched(_:)),
                keyEquivalent: ""
            )
            sortItem.target = self
            menu.addItem(sortItem)

            return menu
        }

        @objc private func fixExtensionForRow(_ sender: NSMenuItem) {
            let row = sender.tag
            guard row < files.count else { return }
            let file = files[row]
            Task { await viewModel.fixExtensionsAsync(only: [file]) }
        }

        @objc private func fixDTOForRow(_ sender: NSMenuItem) {
            let row = sender.tag
            guard row < files.count else { return }
            let file = files[row]
            Task { await viewModel.fixDTOAsync(only: [file]) }
        }

        @objc private func sortByMismatched(_ sender: NSMenuItem) {
            viewModel.sortKey = .mismatched
            viewModel.sortAscending = true
        }

        /// Dequeues or creates a `FilenameCellView` for the Filename column.
        /// Uses `tableView.makeView(withIdentifier:owner:)` so views are recycled.
        /// The cell contains a pre-built warning label that is shown/hidden
        /// via `isHidden` rather than dynamically adding/removing subviews.
        private func dequeueFilenameCell(tableView: NSTableView,
                                          id: NSUserInterfaceItemIdentifier,
                                          text: String,
                                          warningText: String?,
                                          warningToolTip: String?) -> FilenameCellView
        {
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? FilenameCellView {
                existing.configure(text: text, warningText: warningText, warningToolTip: warningToolTip)
                return existing
            }

            let cell = FilenameCellView()
            cell.identifier = id
            cell.configure(text: text, warningText: warningText, warningToolTip: warningToolTip)
            return cell
        }

        /// Dequeues or creates an editable cell for the given column identifier.
        /// Uses `tableView.makeView(withIdentifier:owner:)` so views are recycled.
        private func dequeueEditableCell(tableView: NSTableView,
                                          id: NSUserInterfaceItemIdentifier,
                                          text: String,
                                          dirty: Bool,
                                          columnID: String,
                                          row: Int) -> NSTableCellView
        {
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView,
               let existingTF = existing.textField
            {
                existingTF.stringValue = text
                existingTF.textColor = dirty ? .orange : .labelColor
                existingTF.tag = row
                return existing
            }

            let cell = NSTableCellView()
            cell.identifier = id

            let tf = NSTextField()
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.stringValue = text
            tf.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            tf.isEditable = true
            tf.isBordered = false
            tf.isBezeled = false
            tf.drawsBackground = false
            tf.isSelectable = true
            tf.focusRingType = .exterior
            tf.backgroundColor = .clear
            tf.textColor = dirty ? .orange : .labelColor

            tf.target = self
            tf.action = #selector(textFieldEdited(_:))
            tf.tag = row
            tf.identifier = NSUserInterfaceItemIdentifier(columnID)

            cell.addSubview(tf)
            cell.textField = tf

            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }
}