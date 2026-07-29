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
//     Bulk edit bars appear in a footer area at the bottom of the left pane
//     when 2+ files are selected. Status bar shows operation progress when active.
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
//   - DropZoneView / FileTableView / PreviewPanel / BulkEditDateBar /
//     BulkEditDescriptionBar (child views)
// ============================================================================

struct ContentView: View {
    @State private var viewModel = FileListViewModel()
    @State private var isTargeted = false

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
                        FileTableView(viewModel: viewModel)
                            .frame(minWidth: 200)

                        if viewModel.selectedFiles.count > 1 {
                            VStack(spacing: 0) {
                                Divider()
                                BulkEditDateBar(viewModel: viewModel)
                                Divider()
                                BulkEditDescriptionBar(viewModel: viewModel)
                            }
                            .background(.ultraThinMaterial)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedFiles.count > 1)
                        }

                        // Status bar
                        StatusBarView(viewModel: viewModel)
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
                Color(nsColor: .windowBackgroundColor).opacity(0.35)
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

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // Use withCheckedContinuation to load each provider sequentially,
        // avoiding the data race from concurrent urls.append() on arbitrary threads.
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await withCheckedContinuation({ continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }) {
                    urls.append(url)
                }
            }

            await MainActor.run {
                let folders = urls.filter { $0.hasDirectoryPath }
                let files = urls.filter { !$0.hasDirectoryPath }

                if !files.isEmpty {
                    viewModel.importFiles(files)
                }
                for folder in folders {
                    viewModel.importFolder(folder)
                }
            }
        }

        return true
    }
}