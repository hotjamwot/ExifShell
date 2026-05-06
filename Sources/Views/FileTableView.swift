import SwiftUI

struct FileTableView: View {
    @ObservedObject var viewModel: FileListViewModel

    var body: some View {
        Table(viewModel.files, selection: $selectedID) {
            TableColumn("Filename") { file in
                Text(file.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120)

            TableColumn("Date/Time Original") { file in
                TextField("", text: binding(for: file))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 180)
        }
        .onChange(of: selectedID) { _, newValue in
            if let id = newValue {
                viewModel.select(viewModel.files.first { $0.id == id })
            } else {
                viewModel.select(nil)
            }
        }
    }

    @State private var selectedID: ImageFile.ID?

    private func binding(for file: ImageFile) -> Binding<String> {
        Binding {
            file.dateTimeOriginal
        } set: { newValue in
            if let idx = viewModel.files.firstIndex(where: { $0.id == file.id }) {
                viewModel.files[idx].dateTimeOriginal = newValue
            }
        }
    }
}