import SwiftUI

/// Visual drop zone shown when no files are loaded.
/// Drop handling is owned by ContentView.
struct DropZoneView: View {
    let viewModel: FileListViewModel

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("Drop images or folders here")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Supports JPEG, PNG, TIFF, HEIC, RAW and more")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            )
            .padding()

            if viewModel.isLoading {
                ProgressView("Loading metadata...")
                    .padding()
            }
        }
    }
}