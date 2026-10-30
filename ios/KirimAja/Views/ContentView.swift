import SwiftUI

public struct ContentView: View {
    @StateObject private var discovery = DiscoveryService.shared
    @StateObject private var transfer = TransferService.shared

    @State private var selectedDevice: DeviceInfo?
    @State private var showManualIPDialog: Bool = false
    @State private var manualIPInput: String = ""
    @State private var manualConnectStatus: String = ""
    @State private var isConnectingManual: Bool = false

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top Status Header
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        Text("KirimAja")
                            .font(.title2)
                            .fontWeight(.bold)
                        Spacer()

                        Button(action: {
                            discovery.scanNetwork()
                            discovery.broadcastPresence()
                        }) {
                            HStack(spacing: 4) {
                                if discovery.isScanning {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Pindai")
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(discovery.isScanning)
                    }

                    HStack {
                        Image(systemName: "wifi")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("IP iPhone: \(discovery.myLocalIP)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()

                        Button("Input IP Manual") {
                            showManualIPDialog = true
                        }
                        .font(.caption)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))

                // Active Transfer Banner
                if let active = transfer.activeTransfer {
                    TransferProgressView(
                        fileName: active.fileName,
                        bytesTransferred: active.bytesTransferred,
                        totalBytes: active.totalBytes,
                        speedMBs: active.speedMBs,
                        etaText: active.isCompleted ? "Selesai!" : active.eta,
                        isResume: active.isResume,
                        onCancel: {
                            transfer.cancelTransfer()
                        }
                    )
                }

                // Discovered Devices List
                List {
                    Section(
                        header: HStack {
                            Text("Laptop Windows Terdeteksi (\(discovery.discoveredPeers.count))")
                            Spacer()
                            if discovery.isScanning {
                                Text("Memindai...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    ) {
                        if discovery.discoveredPeers.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 16)
                                Text("Belum Ada Laptop Terdeteksi")
                                    .font(.headline)
                                Text("Pastikan aplikasi KirimAja di Windows sudah dibuka dan terhubung ke jaringan Wi-Fi yang sama.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)

                                Button(action: {
                                    showManualIPDialog = true
                                }) {
                                    Label("Hubungkan Langsung via IP", systemImage: "link")
                                        .font(.subheadline)
                                }
                                .padding(.top, 4)
                                .padding(.bottom, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(discovery.discoveredPeers) { device in
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                        .font(.title2)
                                        .foregroundColor(.accentColor)
                                        .frame(width: 36)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.alias)
                                            .font(.headline)
                                        Text("\(device.ip ?? "LAN"):\(device.port) • \(device.deviceModel ?? "Windows PC")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button("Kirim") {
                                        self.selectedDevice = device
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .refreshable {
                    discovery.scanNetwork()
                    discovery.broadcastPresence()
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $selectedDevice) { target in
                SendView(targetDevice: target) { fileURL, fileName, fileSize, mimeType in
                    Task {
                        do {
                            try await transfer.sendFile(
                                fileURL: fileURL,
                                fileName: fileName,
                                fileSize: fileSize,
                                fileType: mimeType,
                                target: target
                            )
                        } catch {
                            print("[ContentView] Transfer failed: \(error)")
                        }
                    }
                }
            }
            .sheet(isPresented: $showManualIPDialog) {
                NavigationStack {
                    VStack(spacing: 20) {
                        Text("Masukkan IP Laptop Windows")
                            .font(.headline)
                            .padding(.top)

                        Text("Lihat alamat IP yang tertera di aplikasi KirimAja pada desktop Windows Anda.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        TextField("Contoh: 192.168.1.100", text: $manualIPInput)
                            .keyboardType(.decimalPad)
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                            .padding(.horizontal)

                        if !manualConnectStatus.isEmpty {
                            Text(manualConnectStatus)
                                .font(.caption)
                                .foregroundColor(manualConnectStatus.contains("Gagal") ? .red : .green)
                        }

                        Button(action: {
                            isConnectingManual = true
                            manualConnectStatus = "Menghubungkan..."
                            Task {
                                let success = await discovery.connectManual(ip: manualIPInput)
                                isConnectingManual = false
                                if success {
                                    manualConnectStatus = "Berhasil terhubung!"
                                    try? await Task.sleep(nanoseconds: 800_000_000)
                                    showManualIPDialog = false
                                } else {
                                    manualConnectStatus = "Gagal menghubungkan. Periksa kembali IP dan firewall laptop."
                                }
                            }
                        }) {
                            if isConnectingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Hubungkan")
                                    .fontWeight(.bold)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                        .disabled(manualIPInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnectingManual)

                        Spacer()
                    }
                    .navigationTitle("IP Manual")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Tutup") {
                                showManualIPDialog = false
                            }
                        }
                    }
                }
            }
            .onAppear {
                discovery.startDiscovery()
            }
        }
    }
}
