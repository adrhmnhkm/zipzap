import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit

public struct SendView: View {
    public let targetDevice: DeviceInfo
    public var onSendBatch: ([OutgoingFile]) -> Void

    @Environment(\.presentationMode) var presentationMode
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter: Bool = false
    @State private var stagedFiles: [OutgoingFile] = []
    @State private var isProcessingFile: Bool = false
    @State private var statusMessage: String = ""

    public init(targetDevice: DeviceInfo, onSendBatch: @escaping ([OutgoingFile]) -> Void) {
        self.targetDevice = targetDevice
        self.onSendBatch = onSendBatch
    }

    public init(targetDevice: DeviceInfo, onSendFile: @escaping (URL, String, Int64, String) -> Void) {
        self.targetDevice = targetDevice
        self.onSendBatch = { files in
            if let f = files.first {
                onSendFile(f.fileURL, f.fileName, f.fileSize, f.fileType)
            }
        }
    }

    private var totalStagedBytes: Int64 {
        stagedFiles.map(\.fileSize).reduce(0, +)
    }

    private var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalStagedBytes, countStyle: .file)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                .padding(.top, 12)

                // Processing Indicator
                if isProcessingFile {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(statusMessage.isEmpty ? "Menyiapkan berkas..." : statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                // Main Content: Empty state or Staged files list
                if stagedFiles.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        VStack(spacing: 6) {
                            Text("Pilih Berkas untuk Dikirim")
                                .font(.headline)
                            Text("Bisa memilih banyak foto, video, atau dokumen sekaligus.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }

                        // Pickers
                        VStack(spacing: 12) {
                            PhotosPicker(selection: $selectedPhotoItems, matching: .any(of: [.images, .videos])) {
                                HStack(spacing: 12) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.title3)
                                    Text("Pilih Foto atau Video")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(isProcessingFile)
                            .onChange(of: selectedPhotoItems) { _, newItems in
                                if !newItems.isEmpty {
                                    processPhotoItems(newItems)
                                }
                            }

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
                } else {
                    VStack(spacing: 8) {
                        // Action buttons to add more
                        HStack(spacing: 12) {
                            PhotosPicker(selection: $selectedPhotoItems, matching: .any(of: [.images, .videos])) {
                                Label("Tambah Foto/Video", systemImage: "photo.badge.plus")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isProcessingFile)
                            .onChange(of: selectedPhotoItems) { _, newItems in
                                if !newItems.isEmpty {
                                    processPhotoItems(newItems)
                                }
                            }

                            Button(action: {
                                showFileImporter = true
                            }) {
                                Label("Tambah Dokumen", systemImage: "doc.badge.plus")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isProcessingFile)
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)

                        // Staged files list
                        List {
                            Section(
                                header: Text("Antrean Pengiriman (\(stagedFiles.count) berkas)")
                            ) {
                                ForEach(stagedFiles) { file in
                                    HStack(spacing: 12) {
                                        Image(systemName: iconForFileType(file.fileType))
                                            .font(.title3)
                                            .foregroundColor(.accentColor)
                                            .frame(width: 28)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.fileName)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                            Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }

                                        Spacer()

                                        Button(action: {
                                            withAnimation {
                                                stagedFiles.removeAll { $0.id == file.id }
                                            }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .listStyle(InsetGroupedListStyle())

                        // Bottom Sticky Send Bar
                        VStack(spacing: 8) {
                            Divider()
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(stagedFiles.count) Berkas Terpilih")
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                    Text("Total ukuran: \(formattedTotalBytes)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    let filesToSend = self.stagedFiles
                                    presentationMode.wrappedValue.dismiss()
                                    onSendBatch(filesToSend)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "paperplane.fill")
                                        Text("Kirim Sekarang")
                                            .fontWeight(.bold)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                                }
                                .disabled(isProcessingFile || stagedFiles.isEmpty)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        .background(Color(UIColor.secondarySystemBackground))
                    }
                }
            }
            .navigationTitle("Kirim ke Laptop")
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
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    processDocURLs(urls)
                case .failure(let error):
                    print("[SendView] File picker error: \(error)")
                }
            }
        }
    }

    private func iconForFileType(_ fileType: String) -> String {
        if fileType.starts(with: "image/") {
            return "photo.fill"
        } else if fileType.starts(with: "video/") {
            return "film.fill"
        } else if fileType.contains("pdf") {
            return "doc.text.fill"
        } else if fileType.contains("zip") || fileType.contains("archive") {
            return "archivebox.fill"
        } else {
            return "doc.fill"
        }
    }

    private func processPhotoItems(_ items: [PhotosPickerItem]) {
        self.isProcessingFile = true
        self.statusMessage = "Membaca \(items.count) media dari galeri..."

        Task {
            var newOutgoing: [OutgoingFile] = []
            for (idx, item) in items.enumerated() {
                await MainActor.run {
                    self.statusMessage = "Membaca media (\(idx + 1)/\(items.count))..."
                }
                do {
                    if let data = try await item.loadTransferable(type: Data.self) {
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

                        let fileIdRaw = "\(fileName)_\(data.count)".data(using: .utf8)?.base64EncodedString()
                            .replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: "+", with: "-")
                            .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString
                        let fileId = String(fileIdRaw.prefix(32))

                        newOutgoing.append(OutgoingFile(
                            id: fileId,
                            fileURL: tempURL,
                            fileName: fileName,
                            fileSize: Int64(data.count),
                            fileType: mime
                        ))
                    }
                } catch {
                    print("[SendView] Error reading photo item: \(error)")
                }
            }

            await MainActor.run {
                for file in newOutgoing {
                    if !self.stagedFiles.contains(where: { $0.id == file.id }) {
                        self.stagedFiles.append(file)
                    }
                }
                self.selectedPhotoItems = []
                self.isProcessingFile = false
                self.statusMessage = ""
            }
        }
    }

    private func processDocURLs(_ urls: [URL]) {
        self.isProcessingFile = true
        self.statusMessage = "Menyiapkan \(urls.count) dokumen..."

        Task {
            var newOutgoing: [OutgoingFile] = []
            for (idx, url) in urls.enumerated() {
                await MainActor.run {
                    self.statusMessage = "Menyalin dokumen (\(idx + 1)/\(urls.count))..."
                }

                guard url.startAccessingSecurityScopedResource() else { continue }
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
                            // Reuse
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

                    let fileIdRaw = "\(fileName)_\(fileSize)".data(using: .utf8)?.base64EncodedString()
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString
                    let fileId = String(fileIdRaw.prefix(32))

                    newOutgoing.append(OutgoingFile(
                        id: fileId,
                        fileURL: tempURL,
                        fileName: fileName,
                        fileSize: fileSize,
                        fileType: mimeType
                    ))
                } catch {
                    print("[SendView] Error copying document: \(error)")
                }
            }

            await MainActor.run {
                for file in newOutgoing {
                    if !self.stagedFiles.contains(where: { $0.id == file.id }) {
                        self.stagedFiles.append(file)
                    }
                }
                self.isProcessingFile = false
                self.statusMessage = ""
            }
        }
    }
}
