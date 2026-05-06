import SwiftUI

struct FileTableView: View {
    let viewModel: FileListViewModel
    @State private var selectedIDs: Set<ImageFile.ID> = []

    var body: some View {
        List(selection: $selectedIDs) {
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
        .onChange(of: selectedIDs) { _, newValue in
            // Update single selection for the preview panel (first selected)
            if let firstID = newValue.first {
                viewModel.select(viewModel.files.first { $0.id == firstID })
            } else {
                viewModel.select(nil)
            }
            // Update multi-selection for bulk edit
            viewModel.selectedFiles = viewModel.files.filter { newValue.contains($0.id) }
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