import SwiftUI

public struct TransferProgressView: View {
    @ObservedObject var bgManager = BackgroundManager.shared

    public var fileName: String
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var speedMBs: Double
    public var etaText: String
    public var isResume: Bool
    public var isPaused: Bool
    public var errorMessage: String?
    public var canRetry: Bool
    public var fileCount: Int = 1
    public var completedFiles: Int = 0
    public var onRetry: () -> Void
    public var onCancel: () -> Void

    public var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }

    public var formattedProgress: String {
        let current = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(current) / \(total)"
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if fileCount > 1 {
                            Text("\(completedFiles)/\(fileCount) Berkas")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .cornerRadius(6)
                        }
                        Text(fileName)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    if isResume {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Melanjutkan Transfer (Resume)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                Spacer()
                Text(String(format: "%.1f MB/s", speedMBs))
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(isPaused ? .secondary : .accentColor)
            }

            // Progress Bar
            ProgressView(value: progressFraction)
                .progressViewStyle(LinearProgressViewStyle(tint: isPaused ? .orange : .accentColor))
                .scaleEffect(x: 1, y: 2.5, anchor: .center)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Stats
            HStack {
                Text(formattedProgress)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(etaText.isEmpty ? "Menghitung sisa waktu..." : "ETA: \(etaText)")
                    .font(.caption)
                    .foregroundColor(isPaused ? .orange : .secondary)
            }

            // Error or Interrupted Notice Banner
            if isPaused || errorMessage != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transfer Terhenti")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.orange)
                        Text(errorMessage ?? "Koneksi terputus. Pastikan layar menyala dan Wi-Fi laptop terhubung.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            Divider()

            // Keep Screen On Toggle (FR-06)
            Toggle(isOn: $bgManager.keepScreenOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Layar Tetap Menyala")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Mencegah iOS menidurkan proses transfer berkas besar.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)

            // Action Buttons
            HStack(spacing: 12) {
                if canRetry {
                    Button(action: onRetry) {
                        Label("Lanjutkan Transfer", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(role: .destructive, action: onCancel) {
                    Text("Batalkan")
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}
