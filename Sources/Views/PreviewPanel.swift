import SwiftUI

struct PreviewPanel: View {
    @ObservedObject var viewModel: FileListViewModel

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

                // Metadata diff view
                VStack(alignment: .leading, spacing: 8) {
                    Text("Date/Time Original")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if file.isDirty {
                        // Show diff: old (red) → new (green)
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(file.originalDateTimeOriginal.isEmpty
                                     ? "(empty)" : file.originalDateTimeOriginal)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.red)
                                    .strikethrough()
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)

                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Proposed")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(file.dateTimeOriginal)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.green)
                                    .fontWeight(.semibold)
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.08))
                            .cornerRadius(6)
                        }
                    } else {
                        // Show current value (clean state)
                        Text(file.dateTimeOriginal.isEmpty
                             ? "(empty)" : file.dateTimeOriginal)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.gray.opacity(0.08))
                            .cornerRadius(6)
                    }
                }
                .padding(.horizontal)

                // Save feedback
                if let feedback = viewModel.lastSaveFeedback {
                    VStack(spacing: 4) {
                        Label("Saved successfully", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Before:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(feedback.from)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.red)
                                .strikethrough()

                            Text("After:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(feedback.to)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.green)
                                .fontWeight(.semibold)
                        }
                        .padding(8)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(6)
                    }
                }

                // Apply buttons
                HStack(spacing: 12) {
                    Button("Apply to Selected") {
                        viewModel.applySelected()
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!file.isDirty)

                    Button("Apply to All (\(viewModel.dirtyCount) dirty)") {
                        viewModel.applyAll()
                    }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(viewModel.dirtyCount == 0)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

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
                    Text("Edit DateTimeOriginal in the table, then review changes here before saving")
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