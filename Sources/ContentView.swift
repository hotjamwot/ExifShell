import SwiftUI
import UniformTypeIdentifiers

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
                    FileTableView(viewModel: viewModel)
                        .frame(minWidth: 320)

                    PreviewPanel(viewModel: viewModel)
                        .frame(minWidth: 280)
                }
                .frame(minWidth: 600, minHeight: 400)

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
    }

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