import SwiftUI

struct FileTableView: View {
    let viewModel: FileListViewModel
    @State private var selectedID: ImageFile.ID?

    var body: some View {
        List(selection: $selectedID) {
            ForEach(viewModel.files) { file in
                @Bindable var bindableFile = file
                TableRowView(
                    filename: file.filename,
                    dateTimeOriginal: $bindableFile.dateTimeOriginal,
                    isDirty: file.isDirty
                )
                .id(file.id)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .onChange(of: selectedID) { _, newValue in
            if let id = newValue {
                viewModel.select(viewModel.files.first { $0.id == id })
            } else {
                viewModel.select(nil)
            }
        }
    }
}

// MARK: - Table Row

private struct TableRowView: View {
    let filename: String
    @Binding var dateTimeOriginal: String
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)

            Divider()

            TextField("Date/Time Original", text: $dateTimeOriginal)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isDirty ? .orange : .primary)
                .frame(minWidth: 180)
        }
        .padding(.vertical, 2)
    }
}