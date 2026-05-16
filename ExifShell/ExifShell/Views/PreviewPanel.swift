import SwiftUI

// ============================================================================
// PreviewPanel
// ============================================================================
// The right pane of the HSplitView, showing a detailed view of the
// currently selected file. Provides diff review, read-only metadata
// display, and action buttons.
//
// Layout (ScrollView):
//   1. Header: filename + multi-select info
//   2. Thumbnail (or placeholder icon)
//   3. Editable fields section with diff display
//      - DateTimeOriginal: grey strikethrough (original) → green bold (current)
//      - Description: grey strikethrough (original) → green bold (current)
//   4. Read-only metadata section (CreateDate, ModifyDate, etc.)
//   5. Save feedback badges (when applicable)
//   6. Action buttons: Save, Sanitise All, Rename All
//   7. Status message
//
// Inputs:
//   - viewModel (reads selectedFile, selectedFiles, lastSaveFeedback, etc.)
//
// Actions:
//   - saveAll() / sanitiseAll() / renameAll() on viewModel
//   - copyCreateDate/ModifyDate to DateTimeOriginal for selected files
// ============================================================================

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

                        if viewModel.selectedFiles.count > 1 {
                            Text("\(viewModel.selectedFiles.count) files selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Copy actions will use each selected file's own source date.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

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

                            // Show only metadata fields that have values
                            if let v = file.createDate, !v.isEmpty {
                                metadataRow(
                                    label: "Create Date",
                                    value: v,
                                    action: viewModel.selectedFiles.contains { $0.createDate?.isEmpty == false } ? {
                                        viewModel.copyCreateDateToDateTimeOriginalSelection()
                                    } : nil
                                )
                            }

                            if let v = file.modifyDate, !v.isEmpty {
                                metadataRow(
                                    label: "Modify Date",
                                    value: v,
                                    action: viewModel.selectedFiles.contains { $0.modifyDate?.isEmpty == false } ? {
                                        viewModel.copyModifyDateToDateTimeOriginalSelection()
                                    } : nil
                                )
                            }

                            if let v = file.imageDescription, !v.isEmpty {
                                metadataRow(label: "Image Description", value: v)
                            }

                            if let v = file.captionAbstract, !v.isEmpty {
                                metadataRow(label: "Caption Abstract", value: v)
                            }

                            if let v = file.subject, !v.isEmpty {
                                metadataRow(label: "Subject", value: v)
                            }

                            if let v = file.keywords, !v.isEmpty {
                                metadataRow(label: "Keywords", value: v)
                            }

                            if let v = file.lastKeywordXMP, !v.isEmpty {
                                metadataRow(label: "Last Keyword XMP", value: v)
                            }
                        }

                        // --- Save Feedback ---
                        if let feedback = viewModel.lastSaveFeedback {
                            saveFeedbackRow(label: "DTO", feedback: feedback)
                        }
                        if let feedback = viewModel.lastDescriptionSaveFeedback {
                            saveFeedbackRow(label: "Desc", feedback: feedback)
                        }

                        if viewModel.operationMessage != nil || viewModel.operationProgress != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                if let message = viewModel.operationMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let progress = viewModel.operationProgress {
                                    ProgressView(value: progress, total: 1.0)
                                        .progressViewStyle(.linear)
                                } else {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                }
                            }
                            .padding(.bottom, 8)
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

                        // Rename button
                        Button {
                            viewModel.renameAll()
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.isRenaming {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .controlSize(.small)
                                }
                                Image(systemName: "pencil.and.list.clipboard")
                                Text(viewModel.isRenaming
                                     ? "Renaming..."
                                     : "Rename All")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(viewModel.isRenaming)
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

    /// A read-only metadata row: label + monospaced value, with an optional action button.
    @ViewBuilder
    private func metadataRow(label: String, value: String?, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value?.isEmpty == false ? value! : "—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Spacer()
            if let action {
                Button(action: action) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(.caption, design: .monospaced))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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