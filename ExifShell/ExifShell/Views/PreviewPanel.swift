import SwiftUI

struct PreviewPanel: View {
    let viewModel: FileListViewModel

    var body: some View {
        VStack(spacing: 16) {
            if let file = viewModel.selectedFile {
                ScrollView {
                    VStack(spacing: 16) {
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

                        // --- Editable Fields Section ---

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Editable Fields")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            // DateTimeOriginal diff overlay
                            fieldDiffView(
                                label: "Date/Time Original",
                                original: file.originalDateTimeOriginal,
                                current: file.dateTimeOriginal,
                                isDirty: file.isDirty && file.dateTimeOriginal != file.originalDateTimeOriginal
                            )

                            // Description diff overlay
                            fieldDiffView(
                                label: "Description",
                                original: file.originalDescription,
                                current: file.description,
                                isDirty: file.isDirty && file.description != file.originalDescription
                            )
                        }
                        .padding(.horizontal)

                        // --- Read-Only Fields Section ---

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Read-Only Metadata")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)

                            readOnlyFieldView(label: "Create Date", value: file.createDate)
                            readOnlyFieldView(label: "Modify Date", value: file.modifyDate)
                            readOnlyFieldView(label: "ImageDescription", value: file.imageDescription)
                            readOnlyFieldView(label: "Caption-Abstract", value: file.captionAbstract)
                        }
                        .padding(.horizontal)

                        // --- Save Feedback Section ---

                        // DateTimeOriginal save feedback
                        if let feedback = viewModel.lastSaveFeedback {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("DTO: \(feedback.from) → \(feedback.to)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(6)
                        }

                        // Description save feedback
                        if let feedback = viewModel.lastDescriptionSaveFeedback {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Desc: \(feedback.from) → \(feedback.to)")
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
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 8) {
                    Text("Select a file to review")
                        .foregroundColor(.secondary)
                    Text("Edit metadata in the table, then review the diff here before saving")
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

    // MARK: - Field Views

    /// Renders a field with original→current diff when dirty.
    @ViewBuilder
    private func fieldDiffView(label: String, original: String, current: String, isDirty: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            if isDirty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(original.isEmpty ? "(empty)" : original)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.gray)
                        .strikethrough()

                    Text(current)
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
                Text(current.isEmpty ? "(empty)" : current)
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
    }

    /// Renders a read-only metadata field.
    @ViewBuilder
    private func readOnlyFieldView(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value?.isEmpty == false ? value! : "(not set)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.04))
                )
        }
    }
}