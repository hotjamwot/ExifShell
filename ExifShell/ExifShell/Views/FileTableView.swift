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
//
// Selection syncs to:
//   - viewModel.selectedFile (first selected → preview panel)
//   - viewModel.selectedFiles (all selected → bulk edit bars)
//
// Sort syncs to:
//   - viewModel.sortKey / viewModel.sortAscending (via column header clicks)
//
// ===== NSTableView Cell Reuse =====
// Cell identifiers are based solely on the column ID (e.g. "filename",
// "dateTimeOriginal", "description") so NSTableView can recycle views
// across rows. tableView.makeView(withIdentifier:owner:) is used to
// dequeue a reusable cell; a new one is only created when the queue
// is empty. This avoids destroying and recreating every cell on each
// reloadData(), which previously happened because identifiers included
// the row index ("\(columnID)_\(row)").
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
            ("filename",          "Filename",              200, "filename"),
            ("dateTimeOriginal",  "Date/Time Original",    200, "dateTimeOriginal"),
            ("description",       "Description",           300, "description"),
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
        }
        let desired = NSSortDescriptor(key: key, ascending: viewModel.sortAscending)
        if tableView.sortDescriptors.first?.key != key
            || tableView.sortDescriptors.first?.ascending != viewModel.sortAscending {
            tableView.sortDescriptors = [desired]
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
                let cell = dequeueTextCell(tableView: tableView, id: cellID, text: file.filename)
                cell.textField?.lineBreakMode = .byTruncatingMiddle
                cell.textField?.toolTip = file.filename
                return cell

            case "dateTimeOriginal":
                let cell = dequeueEditableCell(tableView: tableView, id: cellID,
                                                text: file.dateTimeOriginal,
                                                dirty: file.isDirty,
                                                columnID: columnID, row: row)
                cell.textField?.toolTip = "DateTimeOriginal (EXIF tag)"
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
            default:                 return
            }
            viewModel.sortAscending = desc.ascending
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

        /// Dequeues or creates a read-only text cell for the given column identifier.
        /// Uses `tableView.makeView(withIdentifier:owner:)` so views are recycled.
        private func dequeueTextCell(tableView: NSTableView,
                                      id: NSUserInterfaceItemIdentifier,
                                      text: String) -> NSTableCellView
        {
            if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
                existing.textField?.stringValue = text
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