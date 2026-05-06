import SwiftUI

struct PreviewPanel: View {
    let viewModel: FileListViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let file = viewModel.selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        Text(file.filename)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Thumbnail
                        if let image = file.thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 240)
                                .cornerRadius(6)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 160)
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.title2)
                                        .foregroundColor(.secondary)
                                )
                        }

                        // --- Editable Fields ---
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Editable")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            fieldDiffRow(
                                label: "Date/Time Original",
                                original: file.originalDateTimeOriginal,
                                current: file.dateTimeOriginal,
                                isDirty: file.isDirty && file.dateTimeOriginal != file.originalDateTimeOriginal
                            )

                            fieldDiffRow(
                                label: "Description",
                                original: file.originalDescription,
                                current: file.description,
                                isDirty: file.isDirty && file.description != file.originalDescription
                            )
                        }

                        Divider()

                        // --- Read-Only Metadata ---
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Metadata")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            metadataRow(label: "Create Date", value: file.createDate)
                            metadataRow(label: "Modify Date", value: file.modifyDate)
                            metadataRow(label: "Image Description", value: file.imageDescription)
                            metadataRow(label: "Caption Abstract", value: file.captionAbstract)
                        }

                        // --- Save Feedback ---
                        if let feedback = viewModel.lastSaveFeedback {
                            saveFeedbackRow(label: "DTO", feedback: feedback)
                        }
                        if let feedback = viewModel.lastDescriptionSaveFeedback {
                            saveFeedbackRow(label: "Desc", feedback: feedback)
                        }

                        // Save button
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

                        // Sanitise button
                        Button {
                            viewModel.sanitiseAll()
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.isSanitising {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .controlSize(.small)
                                }
                                Image(systemName: "wand.and.stars")
                                Text(viewModel.isSanitising
                                     ? "Sanitising..."
                                     : "Sanitise All")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(viewModel.isSanitising)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        // Status
                        if let status = viewModel.statusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Text("Select a file")
                        .foregroundColor(.secondary)
                    Text("Edit metadata in the table, then review here before saving")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    if viewModel.dirtyCount > 0 {
                        Text("\(viewModel.dirtyCount) file(s) with unsaved changes")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 280)
    }

    // MARK: - Field Views

    /// A clean diff row: label above, then original (strikethrough) → current (green) when dirty.
    @ViewBuilder
    private func fieldDiffRow(label: String, original: String, current: String, isDirty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            if isDirty {
                Text(original.isEmpty ? "(empty)" : original)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.gray)
                    .strikethrough()
                Text(current)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .foregroundColor(.green)
            } else {
                Text(current.isEmpty ? "(empty)" : current)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
        }
    }

    /// A read-only metadata row: label + monospaced value.
    @ViewBuilder
    private func metadataRow(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    /// Save feedback badge.
    @ViewBuilder
    private func saveFeedbackRow(label: String, feedback: FileListViewModel.SaveFeedback) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            Text("\(label): \(feedback.from) → \(feedback.to)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.green)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.green.opacity(0.08))
        )
    }
}