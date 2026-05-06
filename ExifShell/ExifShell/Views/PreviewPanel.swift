import SwiftUI

struct PreviewPanel: View {
    let viewModel: FileListViewModel

    var body: some View {
        VStack(spacing: 16) {
            if let file = viewModel.selectedFile {
                // Header
                Text(file.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Thumbnail
                if let image = file.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 400, maxHeight: 300)
                        .cornerRadius(8)
                        .shadow(radius: 2)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(maxWidth: 400, maxHeight: 300)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                        )
                }

                // DateTimeOriginal diff overlay
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date/Time Original")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if file.isDirty {
                        // Dirty: show old (grey strikethrough) → new (green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.originalDateTimeOriginal.isEmpty
                                 ? "(empty)" : file.originalDateTimeOriginal)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.gray)
                                .strikethrough()

                            Text(file.dateTimeOriginal)
                                .font(.system(.body, design: .monospaced, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green.opacity(0.06))
                        )
                    } else {
                        // Clean: show current value
                        Text(file.dateTimeOriginal.isEmpty
                             ? "(empty)" : file.dateTimeOriginal)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.06))
                            )
                    }
                }
                .padding(.horizontal)

                // Save feedback
                if let feedback = viewModel.lastSaveFeedback {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(feedback.from) → \(feedback.to)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                }

                // Single Save button
                Button {
                    viewModel.saveAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text(viewModel.dirtyCount > 0
                             ? "Save Changes (\(viewModel.dirtyCount))"
                             : "Save Changes")
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.dirtyCount == 0)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.horizontal)

                // Status
                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Select a file to review")
                        .foregroundColor(.secondary)
                    Text("Edit DateTimeOriginal in the table, then review the diff here before saving")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if viewModel.dirtyCount > 0 {
                        Text("\(viewModel.dirtyCount) file(s) with unsaved changes")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}