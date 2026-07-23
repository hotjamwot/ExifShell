import SwiftUI

// ============================================================================
// BulkEditDescriptionBar
// ============================================================================
// The bulk edit bar for Description values. Shown above the file table
// when 2+ files are selected, below the date bulk edit bar.
//
// Inputs:
//   - viewModel: provides bulkEditDescriptionValue, selectedFiles,
//     applyBulkEditDescription()
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
// ============================================================================

struct BulkEditDescriptionBar: View {
    @Bindable var viewModel: FileListViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .foregroundColor(.secondary)
                .font(.caption)

            Text("Set Description")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("Description text...", text: $viewModel.bulkEditDescriptionValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 250)
                .onSubmit {
                    viewModel.applyBulkEditDescription()
                }

            Button("Apply") {
                viewModel.applyBulkEditDescription()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}