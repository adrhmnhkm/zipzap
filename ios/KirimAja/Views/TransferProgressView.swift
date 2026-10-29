import SwiftUI

public struct TransferProgressView: View {
    @ObservedObject var bgManager = BackgroundManager.shared
    
    public var fileName: String
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var speedMBs: Double
    public var etaText: String
    public var isResume: Bool
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
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileName)
                        .font(.headline)
                        .lineLimit(1)
                    
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
                    .foregroundColor(.accentColor)
            }

            // Progress Bar
            ProgressView(value: progressFraction)
                .progressViewStyle(LinearProgressViewStyle())
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
                    .foregroundColor(.secondary)
            }

            Divider()

            // Keep Screen On Toggle (FR-06)
            Toggle(isOn: $bgManager.keepScreenOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Layar Tetap Menyala")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Mencegah iOS menidurkan proses transfer file besar.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)

            // Cancel Button
            Button(role: .destructive, action: onCancel) {
                Text("Batalkan Pengiriman")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
        .padding()
    }
}
