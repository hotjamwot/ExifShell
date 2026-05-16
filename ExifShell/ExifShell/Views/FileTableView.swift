import SwiftUI

struct FileTableView: View {
    let viewModel: FileListViewModel
    @State private var selectedIDs: Set<ImageFile.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 0) {
                Button {
                    viewModel.toggleSort(.filename)
                } label: {
                    HStack(spacing: 6) {
                        Text("Filename")
                        if viewModel.sortKey == .filename {
                            Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                Button {
                    viewModel.toggleSort(.originalDateTime)
                } label: {
                    HStack(spacing: 6) {
                        Text("Date/Time Original")
                        if viewModel.sortKey == .originalDateTime {
                            Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                Button {
                    viewModel.toggleSort(.description)
                } label: {
                    HStack(spacing: 6) {
                        Text("Description")
                        if viewModel.sortKey == .description {
                            Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(minHeight: 20, maxHeight: 28)
            .background(Color.gray.opacity(0.06))

            List(selection: $selectedIDs) {
                ForEach(viewModel.sortedFiles) { file in
                    @Bindable var bindableFile = file
                    TableRowView(
                        filename: file.filename,
                        dateTimeOriginal: $bindableFile.dateTimeOriginal,
                        description: $bindableFile.description,
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
}

// MARK: - Table Row

private struct TableRowView: View {
    let filename: String
    @Binding var dateTimeOriginal: String
    @Binding var description: String
    let isDirty: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            TextField("Date/Time Original", text: $dateTimeOriginal)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isDirty ? .orange : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .help("DateTimeOriginal (EXIF tag)")

            Divider()

            TextField("Description", text: $description)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isDirty ? .orange : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .help("Description — written to Description, ImageDescription & Caption-Abstract on save")
        }
        .padding(.vertical, 2)
    }
}