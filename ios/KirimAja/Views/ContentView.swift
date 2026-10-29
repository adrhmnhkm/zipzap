import SwiftUI
import PhotosUI

/// Main screen for KirimAja on iOS: shows discovered LAN targets (Windows laptops)
/// and triggers sending files.
public struct ContentView: View {
    @StateObject private var bgManager = BackgroundManager.shared
    @State private var discoveredDevices: [DiscoveredPeer] = [
        DiscoveredPeer(alias: "Laptop Windows (Mencari...)", ip: "192.168.1.100", port: 53317, model: "Windows PC")
    ]
    @State private var selectedDevice: DiscoveredPeer?
    @State private var showPicker: Bool = false
    @State private var activeTransfer: ActiveTransferState?

    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header status
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("KirimAja")
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()
                    }
                    Text("Pilih laptop Windows tujuan di jaringan Wi-Fi yang sama untuk mengirim file.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))

                // Active Transfer Card (if currently transferring)
                if let transfer = activeTransfer {
                    TransferProgressView(
                        fileName: transfer.fileName,
                        bytesTransferred: transfer.bytesTransferred,
                        totalBytes: transfer.totalBytes,
                        speedMBs: transfer.speedMBs,
                        etaText: transfer.eta,
                        isResume: transfer.isResume,
                        onCancel: {
                            self.activeTransfer = nil
                            self.bgManager.endTransferBackgroundTask()
                        }
                    )
                }

                // Discovered Devices List
                List {
                    Section(header: Text("Perangkat Windows Terdeteksi")) {
                        ForEach(discoveredDevices) { device in
                            HStack {
                                Image(systemName: "laptopcomputer")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.alias)
                                        .font(.headline)
                                    Text("\(device.ip):\(device.port)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Kirim") {
                                    self.selectedDevice = device
                                    self.showPicker = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showPicker) {
                if let target = selectedDevice {
                    SendView(targetDevice: target, onStartTransfer: { file, size in
                        self.startSending(file: file, size: size, to: target)
                    })
                }
            }
        }
    }

    private func startSending(file: String, size: Int64, to target: DiscoveredPeer) {
        self.showPicker = false
        self.bgManager.beginTransferBackgroundTask(description: "Kirim \(file)")
        self.bgManager.updateIdleTimer(isTransferring: true)

        self.activeTransfer = ActiveTransferState(
            fileName: file,
            bytesTransferred: 0,
            totalBytes: size,
            speedMBs: 24.5,
            eta: "1m 12s",
            isResume: false
        )
    }
}

public struct DiscoveredPeer: Identifiable {
    public let id = UUID()
    public let alias: String
    public let ip: String
    public let port: UInt16
    public let model: String
}

public struct ActiveTransferState {
    public var fileName: String
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var speedMBs: Double
    public var eta: String
    public var isResume: Bool
}
