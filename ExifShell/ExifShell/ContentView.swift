import SwiftUI
import UniformTypeIdentifiers

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
                        if let status = viewModel.statusMessage {
                            HStack {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if viewModel.isLoading {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .controlSize(.small)
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
    }

    // MARK: - Bulk Edit Bar (DateTimeOriginal)

    @ViewBuilder
    private var bulkEditBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundColor(.secondary)
                .font(.caption)

            Text("Set DateTimeOriginal for \(viewModel.selectedFiles.count) selected file(s):")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. 2024:01:15 14:30:00", text: $viewModel.bulkEditValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 200)
                .onSubmit { viewModel.applyBulkEdit() }

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