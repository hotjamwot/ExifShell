import SwiftUI

// ============================================================================
// BulkEditDateBar
// ============================================================================
// The bulk edit bar for DateTimeOriginal values. Shown above the file table
// when 2+ files are selected. Supports two modes:
//
//   - Set: Enter a specific date string (e.g. "2024:01:15 14:30:00")
//   - Offset: Add/subtract a time interval from all selected files
//
// Inputs:
//   - viewModel: provides bulkEditMode, bulkEditValue, bulkOffsetAmount,
//     bulkOffsetPositive, bulkOffsetUnit, selectedFiles, applyBulkEdit()
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
// ============================================================================

struct BulkEditDateBar: View {
    @Bindable var viewModel: FileListViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundColor(.secondary)
                .font(.caption)

            Picker("", selection: $viewModel.bulkEditMode) {
                ForEach(FileListViewModel.DateBulkEditMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

            if viewModel.bulkEditMode == .set {
                TextField("e.g. 2024:01:15 14:30:00", text: $viewModel.bulkEditValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 220)
                    .onSubmit { viewModel.applyBulkEdit() }
            } else {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.secondary)
                    .font(.caption)

                Button(action: { viewModel.bulkOffsetPositive.toggle() }) {
                    Text(viewModel.bulkOffsetPositive ? "+" : "−")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                TextField("0", text: $viewModel.bulkOffsetAmount)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 60)
                    .onSubmit { viewModel.applyBulkEdit() }

                Picker("Unit", selection: $viewModel.bulkOffsetUnit) {
                    ForEach(FileListViewModel.BulkOffsetUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 100)
            }

            Button("Apply") {
                viewModel.applyBulkEdit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}