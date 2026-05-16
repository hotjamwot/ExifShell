import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// ContentView
// ============================================================================
// The root view of ExifShell. Manages two states:
//
//   Empty state (files.isEmpty):
//     Shows DropZoneView for initial drag-and-drop.
//
//   Loaded state (files non-empty):
//     HSplitView with FileTableView (left) and PreviewPanel (right).
//     Bulk edit bars appear above the table when 2+ files are selected.
//     Status bar shows operation progress when active.
//
// Responsibilities:
//   - Drag-and-drop: resolves .fileURL providers, separates folders from files
//   - Bulk edit UI: DateTimeOriginal (set/offset) and Description bars
//   - Status bar: operation messages + progress indicator
//   - App-wide keyboard shortcuts (⌘K, ⌘S, ⌫ Delete) via hidden background buttons
//   - Loading overlay with progress when viewModel.isLoading
//
// Types consumed:
//   - FileListViewModel (all state and action methods)
//   - DropZoneView / FileTableView / PreviewPanel (child views)
//
// Design note:
//   Bulk edit bars use @ViewBuilder functions for each mode (date set, date
//   offset, description) rather than a shared component, because each bar
//   has sufficiently different controls (segmented picker, sign toggle, unit
//   picker, text field) that a single generic component would be harder to
//   read than the duplication.
// ============================================================================

struct ContentView: View {
    @State private var viewModel = FileListViewModel()
    @State private var isTargeted = false
    @State private var bulkEditDescriptionValue: String = ""

    var body: some View {
        ZStack {
            if viewModel.files.isEmpty {
                // Empty state: show drop zone
                DropZoneView(viewModel: viewModel)
                    .frame(minWidth: 400, minHeight: 300)
            } else {
                // Loaded state: show table + preview
                HSplitView {
                    VStack(spacing: 0) {
                        // Bulk edit bar — visible when multiple files are selected
                        if viewModel.selectedFiles.count > 1 {
                            bulkEditBar
                            Divider()
                            bulkEditDescriptionBar
                        }

                        FileTableView(viewModel: viewModel)
                            .frame(minWidth: 420)

                        // Status bar
                        if viewModel.statusMessage != nil || viewModel.operationMessage != nil || viewModel.isLoading || viewModel.isSaving || viewModel.isSanitising || viewModel.isRenaming {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let message = viewModel.operationMessage {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let status = viewModel.statusMessage {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if let progress = viewModel.operationProgress {
                                    ProgressView(value: progress, total: 1.0)
                                        .scaleEffect(0.7)
                                        .controlSize(.small)
                                        .frame(width: 120)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .controlSize(.small)
                                        .frame(width: 120)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.05))
                        }
                    }

                    PreviewPanel(viewModel: viewModel)
                        .frame(minWidth: 300)
                }
                .frame(minWidth: 720, minHeight: 400)

                // Drag target overlay — visible even when files loaded
                if isTargeted {
                    Color.accentColor.opacity(0.08)
                        .overlay(
                            Text("Drop to add more files")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        )
                }
            }

            if viewModel.isLoading {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView(viewModel.operationMessage ?? "Loading…")
                        .progressViewStyle(.circular)
                        .scaleEffect(1.2)
                        .padding(.bottom, 4)
                    if let progress = viewModel.operationProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 240)
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
                .shadow(radius: 12)
            }
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: $isTargeted,
            perform: handleDrop
        )
        // App-wide keyboard shortcuts
        .background(
            // ⌘K — Clear all files
            Button("") { viewModel.clearAll() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .background(
            // ⌘S — Save all dirty files (works even when preview panel is not visible)
            Button("") { viewModel.saveAll() }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        )
        .background(
            // ⌦ Delete — Remove selected files from the list
            Button("") { viewModel.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .hidden()
        )
    }

    // MARK: - Bulk Edit Bar (DateTimeOriginal)

    @ViewBuilder
    private var bulkEditBar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $viewModel.bulkEditMode) {
                ForEach(FileListViewModel.DateBulkEditMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            if viewModel.bulkEditMode == .set {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Text("Set DateTimeOriginal for \(viewModel.selectedFiles.count) selected file(s):")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("e.g. 2024:01:15 14:30:00", text: $viewModel.bulkEditValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 220)
                    .onSubmit { viewModel.applyBulkEdit() }
            } else {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Text("Offset DateTimeOriginal for \(viewModel.selectedFiles.count) selected file(s):")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: { viewModel.bulkOffsetPositive.toggle() }) {
                    Text(viewModel.bulkOffsetPositive ? "+" : "−")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("0", text: $viewModel.bulkOffsetAmount)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60)
                    .onSubmit { viewModel.applyBulkEdit() }

                Picker("Unit", selection: $viewModel.bulkOffsetUnit) {
                    ForEach(FileListViewModel.BulkOffsetUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 100)
            }

            Button("Apply") {
                viewModel.applyBulkEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: - Bulk Edit Bar (Description)

    @ViewBuilder
    private var bulkEditDescriptionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .foregroundColor(.secondary)
                .font(.caption)

            Text("Set Description for \(viewModel.selectedFiles.count) selected file(s):")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Description text...", text: $bulkEditDescriptionValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 250)
                .onSubmit {
                    viewModel.bulkEditValue = bulkEditDescriptionValue
                    viewModel.applyBulkEditDescription()
                }

            Button("Apply") {
                viewModel.bulkEditValue = bulkEditDescriptionValue
                viewModel.applyBulkEditDescription()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.06))
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    urls.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let folders = urls.filter { $0.hasDirectoryPath }
            let files = urls.filter { !$0.hasDirectoryPath }

            if !files.isEmpty {
                viewModel.importFiles(files)
            }
            for folder in folders {
                viewModel.importFolder(folder)
            }
        }

        return true
    }
}