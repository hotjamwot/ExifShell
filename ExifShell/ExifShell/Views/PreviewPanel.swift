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
//   6. Action buttons: Save, Rename All
//   7. Status message
//
// Note: The old "Sanitise All" button has been removed because Save now
// incorporates sanitise behaviour (writing DateTimeOriginal also writes
// CreateDate, ModifyDate, and clears offset tags).
//
// Inputs:
//   - viewModel (reads selectedFile, selectedFiles, lastSaveFeedback, etc.)
//
// Actions:
//   - saveAll() / renameAll() on viewModel
//   - copyCreateDate/ModifyDate to DateTimeOriginal for selected files
//
// Types consumed:
//   - FileListViewModel (ExifShell/ViewModels/FileListViewModel.swift)
//   - ImageFile (ExifShell/Models/ImageFile.swift)
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
// ============================================================================

struct PreviewPanel: View {
    let viewModel: FileListViewModel

    /// Tracks whether the save icon should animate.
    @State private var isSaveAnimating = false

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

                        Text(file.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.selectedFiles.count > 1 {
                            Text("\(viewModel.selectedFiles.count) files selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Video-specific metadata badge
                        if file.mediaType == .video {
                            HStack(spacing: 8) {
                                Label("Video", systemImage: "film")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let duration = file.readOnly.duration, !duration.isEmpty {
                                    Label(duration, systemImage: "clock")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let resolution = file.readOnly.resolution, !resolution.isEmpty {
                                    Label(resolution, systemImage: "rectangle")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Thumbnail
                        if let image = file.thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 240)
                                .cornerRadius(6)
                        } else if file.mediaType == .video {
                            // Video with no thumbnail fallback
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 160)
                                .overlay(
                                    VStack(spacing: 8) {
                                        Image(systemName: "film")
                                            .font(.system(size: 36))
                                            .foregroundColor(.secondary)
                                        Text("Video")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                )
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
                            fieldDiffRow(
                                label: file.editableDateTagLabel,
                                original: file.originalDateTimeOriginal,
                                current: file.dateTimeOriginal,
                                isDirty: file.isDirty && file.dateTimeOriginal != file.originalDateTimeOriginal,
                                sourceLabel: file.dateSourceLabel,
                                needsSanitise: file.needsSanitise
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
                            if let v = file.readOnly.createDate, !v.isEmpty {
                                metadataRow(
                                    label: "Create Date",
                                    value: v,
                                    action: viewModel.selectedFiles.contains { $0.readOnly.createDate?.isEmpty == false } ? {
                                        viewModel.copyCreateDateToDateTimeOriginalSelection()
                                    } : nil
                                )
                            }

                            if let v = file.readOnly.modifyDate, !v.isEmpty {
                                metadataRow(
                                    label: "Modify Date",
                                    value: v,
                                    action: viewModel.selectedFiles.contains { $0.readOnly.modifyDate?.isEmpty == false } ? {
                                        viewModel.copyModifyDateToDateTimeOriginalSelection()
                                    } : nil
                                )
                            }

                            if let v = file.readOnly.imageDescription, !v.isEmpty {
                                metadataRow(label: "Image Description", value: v)
                            }

                            if let v = file.readOnly.captionAbstract, !v.isEmpty {
                                metadataRow(label: "Caption Abstract", value: v)
                            }

                            if let v = file.readOnly.subject, !v.isEmpty {
                                metadataRow(label: "Subject", value: v)
                            }

                            if let v = file.readOnly.cameraMake, !v.isEmpty {
                                metadataRow(label: "Camera Make", value: v, systemImage: "camera")
                            }

                            if let v = file.readOnly.cameraModel, !v.isEmpty {
                                metadataRow(label: "Camera Model", value: v, systemImage: "camera.viewfinder")
                            }

                            if let v = file.readOnly.keywords, !v.isEmpty {
                                metadataRow(label: "Keywords", value: v)
                            }

                            if let v = file.readOnly.lastKeywordXMP, !v.isEmpty {
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

                        // Save row: Save Selected | Save All
                        HStack(spacing: 8) {
                            Button {
                                viewModel.saveSelected()
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.isSaving {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .controlSize(.small)
                                    }
                                    Image(systemName: "square.and.arrow.down")
                                    Text(viewModel.selectedDirtyCount > 0
                                         ? "Save Selected (\(viewModel.selectedDirtyCount))"
                                         : "Save Selected")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.selectedDirtyCount == 0 || viewModel.isSaving)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Button {
                                viewModel.saveAll()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: viewModel.isSaving
                                        ? "square.and.arrow.down.on.square"
                                        : (viewModel.dirtyCount > 0 ? "square.and.arrow.down.badge.clock" : "square.and.arrow.down"))
                                        .symbolEffect(.bounce, value: isSaveAnimating)
                                        .symbolEffect(.pulse, isActive: viewModel.isSaving)
                                    Text(viewModel.dirtyCount > 0
                                         ? "Save All (\(viewModel.dirtyCount))"
                                         : "Save All")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(viewModel.dirtyCount == 0 || viewModel.isSaving)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }

                        // Sanitise row: Sanitise Selected | Sanitise All
                        HStack(spacing: 8) {
                            Button {
                                viewModel.sanitiseSelected()
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.isSanitising {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .controlSize(.small)
                                    }
                                    Image(systemName: viewModel.isSanitising
                                        ? "wand.and.stars"
                                        : "wand.and.rays")
                                        .symbolEffect(.bounce, value: viewModel.isSanitising)
                                        .symbolEffect(.pulse, isActive: viewModel.isSanitising)
                                    Text(viewModel.isSanitising
                                         ? "Sanitising..."
                                         : "Sanitise Selected")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.isSanitising || viewModel.selectedFiles.isEmpty)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Button {
                                viewModel.sanitiseAll()
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.isSanitising {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .controlSize(.small)
                                    }
                                    Image(systemName: viewModel.isSanitising
                                        ? "wand.and.stars"
                                        : "wand.and.rays")
                                        .symbolEffect(.bounce, value: viewModel.isSanitising)
                                        .symbolEffect(.pulse, isActive: viewModel.isSanitising)
                                    Text(viewModel.isSanitising
                                         ? "Sanitising..."
                                         : "Sanitise All")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.isSanitising || viewModel.files.isEmpty)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }

                        // Rename row: Rename Selected | Rename All
                        HStack(spacing: 8) {
                            Button {
                                viewModel.renameSelected()
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
                                         : "Rename Selected")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.isRenaming)
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

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
                                        .symbolEffect(.bounce, value: viewModel.isRenaming)
                                        .symbolEffect(.pulse, isActive: viewModel.isRenaming)
                                    Text(viewModel.isRenaming
                                         ? "Renaming..."
                                         : "Rename All")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(viewModel.isRenaming)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }

                        // Status
                        if let status = viewModel.statusMessage {
                            HStack(spacing: 6) {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if viewModel.lastErrorDetail != nil {
                                    Button {
                                        if let detail = viewModel.lastErrorDetail {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(detail, forType: .string)
                                        }
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help("Copy error details to clipboard")
                                }
                            }
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
                        Label("\(viewModel.dirtyCount) file(s) with unsaved changes",
                              systemImage: "square.and.arrow.down.badge.clock")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 280)
        .onChange(of: viewModel.isSaving) { oldVal, newVal in
            if newVal {
                isSaveAnimating = true
                // Reset after a short delay so it can trigger again next time
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    isSaveAnimating = false
                }
            }
        }
    }

    // MARK: - Field Views

    /// A clean diff row: label above, then original (strikethrough) → current (green) when dirty.
    /// When `dateSource` is provided, shows a small badge indicating where the date came from.
    /// `needsSanitise` shows a warning badge if the date format is non-standard (e.g. XMP ISO 8601).
    @ViewBuilder
    private func fieldDiffRow(label: String, original: String, current: String, isDirty: Bool, sourceLabel: String? = nil, needsSanitise: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !current.isEmpty, let source = sourceLabel {
                    Text(source)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.12))
                        )
                }
                // Show a sanitise warning badge if the date format is non-standard
                // (e.g. XMP ISO 8601 dates like "2010-03-27T01:40:19+00:00")
                if needsSanitise {
                    Text("⚠️ Sanitise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.12))
                        )
                        .help("Date format needs sanitising — run Sanitise Selected")
                }
            }

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

    /// A read-only metadata row: label + monospaced value, with an optional action button
    /// and optional SF icon. When both an SF icon and action are present, the icon renders
    /// inline next to the label for visual context (e.g. 📷 for camera fields).
    @ViewBuilder
    private func metadataRow(label: String, value: String?, systemImage: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let image = systemImage {
                        Image(systemName: image)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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

    /// Save feedback badge with animated checkmark.
    @ViewBuilder
    private func saveFeedbackRow(label: String, feedback: FileListViewModel.SaveFeedback) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
                .symbolEffect(.bounce, options: .repeating)
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
