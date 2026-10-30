import Foundation

@MainActor
public class TransferService: NSObject, ObservableObject, URLSessionTaskDelegate {
    public static let shared = TransferService()

    @Published public var activeTransfer: ActiveTransferState?

    private var sendTask: Task<Void, Error>?
    private var currentSessionId: String?
    private var currentFileId: String?
    private var currentTarget: DeviceInfo?
    private var isExplicitlyCancelled: Bool = false
    private var lastUpdateTime = Date()
    private var lastBytesTransferred: Int64 = 0
    private var currentResumeOffset: Int64 = 0
    private var urlSession: URLSession!

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    public func sendFile(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        fileType: String,
        target: DeviceInfo
    ) async throws {
        guard let targetIP = target.ip else {
            throw NSError(domain: "TransferError", code: 400, userInfo: [NSLocalizedDescriptionKey: "IP tujuan tidak valid"])
        }

        let bgManager = BackgroundManager.shared
        bgManager.beginTransferBackgroundTask(description: "Kirim \(fileName)")
        bgManager.updateIdleTimer(isTransferring: true)

        // 1. Generate deterministic fileId based on fileName and fileSize
        let fileIdRaw = "\(fileName)_\(fileSize)".data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString
        let fileId = String(fileIdRaw.prefix(32))

        self.isExplicitlyCancelled = false
        self.currentFileId = fileId
        self.currentTarget = target

        // 2. Query KirimAja resume endpoint to check if desktop already has partial bytes
        var resumeOffset: Int64 = 0
        if let resumeInfoURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/kirimaja/v1/resume-info?file_id=\(fileId)") {
            var checkReq = URLRequest(url: resumeInfoURL)
            checkReq.timeoutInterval = 2.0
            if let (rData, rResp) = try? await URLSession.shared.data(for: checkReq),
               let httpRResp = rResp as? HTTPURLResponse, httpRResp.statusCode == 200 {
                let respStr = String(data: rData, encoding: .utf8) ?? ""
                print("[TransferService] resume-info raw response: \(respStr)")

                var parsedOffset: Int64 = 0
                if let json = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] {
                    if let num = json["offset"] as? NSNumber {
                        parsedOffset = num.int64Value
                    } else if let str = json["offset"] as? String, let val = Int64(str) {
                        parsedOffset = val
                    } else if let intVal = json["offset"] as? Int {
                        parsedOffset = Int64(intVal)
                    }
                }

                if parsedOffset > 0 && parsedOffset < fileSize {
                    resumeOffset = parsedOffset
                    print("[TransferService] Resume detected! Resuming from offset: \(resumeOffset) bytes (total \(fileSize))")
                }
            }
        }

        self.currentResumeOffset = resumeOffset
        let initialEta = resumeOffset > 0 ? "Melanjutkan (\(Int((Double(resumeOffset) / Double(fileSize)) * 100))%)..." : "Menghubungkan..."
        self.activeTransfer = ActiveTransferState(
            fileName: fileName,
            bytesTransferred: resumeOffset,
            totalBytes: fileSize,
            speedMBs: 0.0,
            eta: initialEta,
            isResume: resumeOffset > 0,
            isCompleted: false,
            isPaused: false,
            errorMessage: nil,
            canRetry: false,
            fileURL: fileURL,
            fileType: fileType,
            target: target
        )

        do {
            // 3. Prepare Upload Request with automatic stale session recovery (HTTP 409)
            let meta = FileMetadata(
                id: fileId,
                fileName: fileName,
                size: fileSize,
                fileType: fileType
            )

            let prepareReq = PrepareUploadRequest(
                info: DiscoveryService.shared.myDevice,
                files: [fileId: meta]
            )

            let prepareURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/localsend/v2/prepare-upload")!
            var req = URLRequest(url: prepareURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(prepareReq)
            req.timeoutInterval = 10.0

            var prepareData: Data?
            for attempt in 1...3 {
                let (pData, pResp) = try await URLSession.shared.data(for: req)
                if let httpResp = pResp as? HTTPURLResponse {
                    if httpResp.statusCode == 409 && attempt < 3 {
                        print("[TransferService] Desktop returned 409 Conflict. Clearing stale session on desktop (attempt \(attempt))...")
                        if let cancelURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/localsend/v2/cancel") {
                            var cancelReq = URLRequest(url: cancelURL)
                            cancelReq.httpMethod = "POST"
                            cancelReq.timeoutInterval = 3.0
                            _ = try? await URLSession.shared.data(for: cancelReq)
                        }
                        try await Task.sleep(nanoseconds: 600_000_000)
                        continue
                    }

                    if (200...299).contains(httpResp.statusCode) {
                        prepareData = pData
                        break
                    }
                }
            }

            guard let finalData = prepareData else {
                throw NSError(domain: "TransferError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Target menolak permintaan pengiriman (sesi sibuk)"])
            }

            let prepResponse = try JSONDecoder().decode(PrepareUploadResponse.self, from: finalData)
            guard let token = prepResponse.files[fileId] else {
                throw NSError(domain: "TransferError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Token file tidak ditemukan dari penerima"])
            }
            self.currentSessionId = prepResponse.sessionId
            self.currentTarget = target

            // 4. Create slice in background if resuming from an offset
            let uploadSourceURL: URL
            if resumeOffset > 0 {
                self.activeTransfer?.eta = "Menyiapkan resume..."
                uploadSourceURL = try await Task.detached(priority: .userInitiated) {
                    try TransferService.createUploadSliceSync(from: fileURL, startingAt: resumeOffset, fileName: fileName)
                }.value
            } else {
                uploadSourceURL = fileURL
            }

            // 5. Upload file stream with delegate
            let uploadURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/localsend/v2/upload?sessionId=\(prepResponse.sessionId)&fileId=\(fileId)&token=\(token)")!
            var uploadReq = URLRequest(url: uploadURL)
            uploadReq.httpMethod = "POST"
            uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadReq.setValue("\(resumeOffset)", forHTTPHeaderField: "X-KirimAja-Resume-Offset")
            uploadReq.setValue(fileName, forHTTPHeaderField: "X-File-Name")

            self.lastUpdateTime = Date()
            self.lastBytesTransferred = resumeOffset
            if resumeOffset > 0 {
                self.activeTransfer?.eta = "Melanjutkan transfer..."
            }

            let (uploadData, uploadResp) = try await self.urlSession.upload(for: uploadReq, fromFile: uploadSourceURL, delegate: self)

            // Cleanup slice file if created
            if uploadSourceURL != fileURL {
                try? FileManager.default.removeItem(at: uploadSourceURL)
            }

            guard let upHttpResp = uploadResp as? HTTPURLResponse, (200...299).contains(upHttpResp.statusCode) else {
                let status = (uploadResp as? HTTPURLResponse)?.statusCode ?? 500
                if status == 409 {
                    throw NSError(domain: "TransferError", code: 409, userInfo: [NSLocalizedDescriptionKey: "Transfer dibatalkan"])
                }
                let bodyStr = String(data: uploadData, encoding: .utf8) ?? ""
                throw NSError(domain: "TransferError", code: status, userInfo: [NSLocalizedDescriptionKey: "Gagal mengunggah file ke desktop: \(bodyStr)"])
            }

            // Completed!
            self.activeTransfer?.bytesTransferred = fileSize
            self.activeTransfer?.speedMBs = 0.0
            self.activeTransfer?.eta = "Selesai!"
            self.activeTransfer?.isCompleted = true
            self.activeTransfer?.isPaused = false
            self.activeTransfer?.canRetry = false
            self.activeTransfer?.errorMessage = nil
            bgManager.endTransferBackgroundTask()
            bgManager.updateIdleTimer(isTransferring: false)

            // Auto-clear success card after 3 seconds
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.activeTransfer?.isCompleted == true {
                self.activeTransfer = nil
            }

        } catch {
            let nsErr = error as NSError
            let isCancelled = self.isExplicitlyCancelled || Task.isCancelled || nsErr.code == NSURLErrorCancelled || nsErr.code == 409
            if !isCancelled {
                var state = self.activeTransfer
                state?.isPaused = true
                state?.canRetry = true
                state?.speedMBs = 0.0
                state?.eta = "Terputus"
                state?.errorMessage = "Koneksi terputus: \(error.localizedDescription)"
                self.activeTransfer = state
            } else {
                self.activeTransfer = nil
            }
            bgManager.endTransferBackgroundTask()
            bgManager.updateIdleTimer(isTransferring: false)
            throw error
        }
    }

    public func startSending(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        fileType: String,
        target: DeviceInfo
    ) {
        self.sendTask?.cancel()
        self.sendTask = Task {
            do {
                try await self.sendFile(
                    fileURL: fileURL,
                    fileName: fileName,
                    fileSize: fileSize,
                    fileType: fileType,
                    target: target
                )
            } catch {
                if !Task.isCancelled && (error as NSError).code != NSURLErrorCancelled {
                    print("[TransferService] Transfer failed: \(error)")
                }
            }
        }
    }

    public func resumeActiveTransfer() {
        guard let active = self.activeTransfer,
              let fileURL = active.fileURL,
              let fileType = active.fileType,
              let target = active.target else { return }

        self.activeTransfer?.isPaused = false
        self.activeTransfer?.canRetry = false
        self.activeTransfer?.errorMessage = nil
        self.activeTransfer?.eta = "Menghubungkan kembali..."

        self.startSending(
            fileURL: fileURL,
            fileName: active.fileName,
            fileSize: active.totalBytes,
            fileType: fileType,
            target: target
        )
    }

    nonisolated private static func createUploadSliceSync(from sourceURL: URL, startingAt offset: Int64, fileName: String) throws -> URL {
        guard offset > 0 else { return sourceURL }

        let sliceURL = FileManager.default.temporaryDirectory.appendingPathComponent("slice_\(offset)_\(fileName)")
        if FileManager.default.fileExists(atPath: sliceURL.path) {
            try? FileManager.default.removeItem(at: sliceURL)
        }

        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: UInt64(offset))

        FileManager.default.createFile(atPath: sliceURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: sliceURL)
        defer { try? writeHandle.close() }

        let chunkSize = 1024 * 1024 // 1MB buffer
        while true {
            let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try writeHandle.write(contentsOf: chunk)
        }

        return sliceURL
    }

    public func cancelTransfer() {
        self.isExplicitlyCancelled = true
        let sid = self.currentSessionId
        let fid = self.currentFileId
        let target = self.currentTarget ?? self.activeTransfer?.target

        // 1. Immediately dismiss UI active transfer state
        self.activeTransfer = nil

        // 2. Notify desktop receiver to cancel and delete partial file FIRST before closing upload socket
        if let target = target, let ip = target.ip {
            Task {
                var urlComponents = URLComponents(string: "\(target.effectiveProtocol)://\(ip):\(target.port)/api/localsend/v2/cancel")
                var queryItems: [URLQueryItem] = []
                if let sid = sid {
                    queryItems.append(URLQueryItem(name: "sessionId", value: sid))
                }
                if let fid = fid {
                    queryItems.append(URLQueryItem(name: "fileId", value: fid))
                }
                if !queryItems.isEmpty {
                    urlComponents?.queryItems = queryItems
                }
                if let cancelURL = urlComponents?.url {
                    var cancelReq = URLRequest(url: cancelURL)
                    cancelReq.httpMethod = "POST"
                    cancelReq.timeoutInterval = 3.0
                    _ = try? await URLSession.shared.data(for: cancelReq)
                    print("[TransferService] Sent cancel request to desktop receiver: \(ip), sid: \(sid ?? "none"), fid: \(fid ?? "none")")
                }
            }
        }

        // 3. Cancel the managed Swift Task
        sendTask?.cancel()
        sendTask = nil

        // 4. Abort all active URLSession upload tasks immediately
        urlSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }

        self.currentSessionId = nil
        self.currentFileId = nil
        self.currentTarget = nil
        BackgroundManager.shared.endTransferBackgroundTask()
        BackgroundManager.shared.updateIdleTimer(isTransferring: false)
    }

    // MARK: - URLSessionTaskDelegate Progress
    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor in
            guard var state = self.activeTransfer, !state.isPaused else { return }

            let effectiveBytesTransferred = self.currentResumeOffset + totalBytesSent
            let now = Date()
            let timeDiff = now.timeIntervalSince(self.lastUpdateTime)

            if timeDiff >= 0.3 || effectiveBytesTransferred >= state.totalBytes {
                let bytesDiff = effectiveBytesTransferred - self.lastBytesTransferred
                let speedBytesSec = timeDiff > 0 ? Double(bytesDiff) / timeDiff : 0.0
                let speedMBs = speedBytesSec / (1024.0 * 1024.0)

                let remainingBytes = max(0, state.totalBytes - effectiveBytesTransferred)
                let etaSecs = speedBytesSec > 1024 ? Int(Double(remainingBytes) / speedBytesSec) : 0

                let etaStr: String
                if etaSecs <= 0 {
                    etaStr = "--"
                } else if etaSecs < 60 {
                    etaStr = "\(etaSecs) dtk"
                } else {
                    etaStr = "\(etaSecs / 60)m \(etaSecs % 60)d"
                }

                state.bytesTransferred = effectiveBytesTransferred
                state.speedMBs = speedMBs
                state.eta = etaStr

                self.activeTransfer = state
                self.lastUpdateTime = now
                self.lastBytesTransferred = effectiveBytesTransferred
            }
        }
    }
}
