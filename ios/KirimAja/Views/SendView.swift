import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit

public struct SendView: View {
    public let targetDevice: DeviceInfo
    public var onSendFile: (URL, String, Int64, String) -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showFileImporter: Bool = false
    @State private var isProcessingFile: Bool = false
    @State private var statusMessage: String = ""

    public init(targetDevice: DeviceInfo, onSendFile: @escaping (URL, String, Int64, String) -> Void) {
        self.targetDevice = targetDevice
        self.onSendFile = onSendFile
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Target banner
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "laptopcomputer")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(targetDevice.alias)
                                .font(.headline)
                                .fontWeight(.bold)
                            Text("\(targetDevice.ip ?? "LAN"):\(targetDevice.port) • \(targetDevice.deviceModel ?? "Windows PC")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)

                if isProcessingFile {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(statusMessage.isEmpty ? "Menyiapkan berkas..." : statusMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 24)
                }

                // Pickers
                VStack(spacing: 16) {
                    // 1. Photos & Videos Picker
                    PhotosPicker(selection: $selectedPhotoItem, matching: .any(of: [.images, .videos])) {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title3)
                            Text("Pilih Foto atau Video dari Galeri")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(isProcessingFile)
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        if let item = newItem {
                            processPhotoItem(item)
                        }
                    }

                    // 2. Files App Picker
                    Button(action: {
                        showFileImporter = true
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.title3)
                            Text("Pilih Berkas Dokumen (Files App)")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .disabled(isProcessingFile)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Kirim ke PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let selectedURL = urls.first else { return }
                    processDocURL(selectedURL)
                case .failure(let error):
                    print("[SendView] File picker error: \(error)")
                }
            }
        }
    }

    private func processPhotoItem(_ item: PhotosPickerItem) {
        self.isProcessingFile = true
        self.statusMessage = "Membaca media dari galeri..."

        Task {
            do {
                // Try to load as data
                if let data = try await item.loadTransferable(type: Data.self) {
                    // Guess extension
                    let ext: String
                    let mime: String
                    if let contentType = item.supportedContentTypes.first {
                        ext = contentType.preferredFilenameExtension ?? "jpg"
                        mime = contentType.preferredMIMEType ?? "image/jpeg"
                    } else {
                        ext = "jpg"
                        mime = "image/jpeg"
                    }

                    let sample = data.prefix(8192)
                    let hash = SHA256.hash(data: sample)
                    let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
                    let fileName = "IMG_\(hashHex)_\(data.count).\(ext)"

                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                    if !FileManager.default.fileExists(atPath: tempURL.path) {
                        try data.write(to: tempURL)
                    }

                    await MainActor.run {
                        self.isProcessingFile = false
                        self.presentationMode.wrappedValue.dismiss()
                        self.onSendFile(tempURL, fileName, Int64(data.count), mime)
                    }
                } else {
                    await MainActor.run {
                        self.isProcessingFile = false
                        self.statusMessage = "Gagal membaca berkas media"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isProcessingFile = false
                    self.statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func processDocURL(_ url: URL) {
        self.isProcessingFile = true
        self.statusMessage = "Menyalin berkas dokumen..."

        guard url.startAccessingSecurityScopedResource() else {
            self.isProcessingFile = false
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileName = url.lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                if let attr = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
                   let existingSize = attr[.size] as? Int64,
                   let originalAttr = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let originalSize = originalAttr[.size] as? Int64,
                   existingSize == originalSize && originalSize > 0 {
                    // Reuse cached file
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: url, to: tempURL)
                }
            } else {
                try FileManager.default.copyItem(at: url, to: tempURL)
            }

            let attr = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let fileSize = attr[.size] as? Int64 ?? 0
            let ext = url.pathExtension.lowercased()
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"

            self.isProcessingFile = false
            self.presentationMode.wrappedValue.dismiss()
            self.onSendFile(tempURL, fileName, fileSize, mimeType)
        } catch {
            self.isProcessingFile = false
            self.statusMessage = "Gagal memproses dokumen: \(error.localizedDescription)"
        }
    }
}
