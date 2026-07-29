import SwiftUI

// ============================================================================
// QuickStatsBar
// ============================================================================
// A compact stats pill shown in the status bar area that displays:
//   - Total file count
//   - Image count
//   - Video count
//   - Dirty file count (when > 0)
//
// Uses subtle system colours and SF symbols for visual clarity.
// The dirty count pill pulses with a spring animation when it changes.
//
// Types consumed:
//   - FileListViewModel (ExifShell/ViewModels/FileListViewModel.swift)
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
// ============================================================================

struct QuickStatsBar: View {
    let viewModel: FileListViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Total file count
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text("\(viewModel.files.count)")
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundColor(.secondary)

            if viewModel.imageCount > 0 || viewModel.videoCount > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.5))

                // Image count
                if viewModel.imageCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                        Text("\(viewModel.imageCount)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }

                // Video count
                if viewModel.videoCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "film")
                            .font(.system(size: 9))
                        Text("\(viewModel.videoCount)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                }
            }

            // Dirty count pill (only shown when > 0)
            if viewModel.dirtyCount > 0 {
                Text("·")
                    .foregroundColor(.secondary.opacity(0.5))

                HStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.down.badge.clock")
                        .font(.system(size: 9))
                    Text("\(viewModel.dirtyCount) dirty")
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .contentTransition(.numericText())
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.12))
                )
                .transition(.scale.combined(with: .opacity))
                .id(viewModel.dirtyCount) // force re-create for animation on change
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(nsColor: .tertiarySystemFill))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.dirtyCount)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.files.count)
    }
}

// ============================================================================
// StatusBarView
// ============================================================================
// The status bar shown at the bottom of the left pane. Displays:
//   - QuickStatsBar (file counts + dirty pill)
//   - Operation/status messages
//   - Error copy button
//   - Progress indicator (determinate or indeterminate)
//
// Extracted from ContentView to reduce view-body complexity for the
// Swift type-checker.
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
// ============================================================================

struct StatusBarView: View {
    let viewModel: FileListViewModel

    var body: some View {
        if viewModel.statusMessage != nil
            || viewModel.operationMessage != nil
            || viewModel.isLoading
            || viewModel.isSaving
            || viewModel.isRenaming
            || !viewModel.files.isEmpty
        {
            HStack(spacing: 8) {
                if !viewModel.files.isEmpty {
                    QuickStatsBar(viewModel: viewModel)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let message = viewModel.operationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

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

                if let progress = viewModel.operationProgress {
                    ProgressView(value: progress, total: 1.0)
                        .scaleEffect(0.7)
                        .controlSize(.small)
                        .frame(width: 120)
                } else if viewModel.isLoading || viewModel.isSaving || viewModel.isRenaming {
                    ProgressView()
                        .scaleEffect(0.7)
                        .controlSize(.small)
                        .frame(width: 120)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
