import Foundation

@MainActor
public class TransferService: NSObject, ObservableObject, URLSessionTaskDelegate {
    public static let shared = TransferService()

    @Published public var activeTransfer: ActiveTransferState?

    private var sendTask: Task<Void, Error>?
    private var currentSessionId: String?
    private var activeFiles: [OutgoingFile] = []
    private var currentTarget: DeviceInfo?
    private var isExplicitlyCancelled: Bool = false
    private var lastUpdateTime = Date()
    private var lastBytesTransferred: Int64 = 0
    private var fileResumeOffsets: [String: Int64] = [:]
    private var fileProgressMap: [String: Int64] = [:]
    private var completedFilesCount: Int = 0
    private var urlSession: URLSession!

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - Multi-File Batch Transfer (Parallel)
    public func sendBatch(
        files: [OutgoingFile],
        target: DeviceInfo
    ) async throws {
        guard !files.isEmpty else { return }
        guard let targetIP = target.ip else {
            throw NSError(domain: "TransferError", code: 400, userInfo: [NSLocalizedDescriptionKey: "IP tujuan tidak valid"])
        }

        let bgManager = BackgroundManager.shared
        let desc = files.count == 1 ? "Kirim \(files[0].fileName)" : "Kirim \(files.count) Berkas"
        bgManager.beginTransferBackgroundTask(description: desc)
        bgManager.updateIdleTimer(isTransferring: true)

        self.isExplicitlyCancelled = false
        self.currentTarget = target
        self.activeFiles = files

        let totalBatchBytes = files.map(\.fileSize).reduce(0, +)

        // 1. Check KirimAja resume endpoint for each file
        var resumeOffsets: [String: Int64] = [:]
        var totalInitialResume: Int64 = 0

        for file in files {
            if let resumeURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/kirimaja/v1/resume-info?file_id=\(file.id)") {
                var checkReq = URLRequest(url: resumeURL)
                checkReq.timeoutInterval = 2.0
                if let (rData, rResp) = try? await URLSession.shared.data(for: checkReq),
                   let httpRResp = rResp as? HTTPURLResponse, httpRResp.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] {
                        var parsed: Int64 = 0
                        if let num = json["offset"] as? NSNumber { parsed = num.int64Value }
                        else if let s = json["offset"] as? String, let v = Int64(s) { parsed = v }
                        else if let i = json["offset"] as? Int { parsed = Int64(i) }

                        if parsed > 0 && parsed < file.fileSize {
                            resumeOffsets[file.id] = parsed
                            totalInitialResume += parsed
                        }
                    }
                }
            }
        }

        self.fileResumeOffsets = resumeOffsets
        self.fileProgressMap = resumeOffsets
        self.completedFilesCount = 0

        let initialEta = totalInitialResume > 0 ? "Melanjutkan..." : "Menghubungkan..."
        let title = files.count == 1 ? files[0].fileName : "\(files.count) Berkas"
        self.activeTransfer = ActiveTransferState(
            fileName: title,
            bytesTransferred: totalInitialResume,
            totalBytes: totalBatchBytes,
            speedMBs: 0.0,
            eta: initialEta,
            isResume: totalInitialResume > 0,
            isCompleted: false,
            isPaused: false,
            errorMessage: nil,
            canRetry: false,
            target: target,
            fileCount: files.count,
            completedFiles: 0,
            batchFiles: files
        )

        do {
            // 2. Prepare upload
            var filesMap: [String: FileMetadata] = [:]
            for f in files {
                filesMap[f.id] = FileMetadata(
                    id: f.id,
                    fileName: f.fileName,
                    size: f.fileSize,
                    fileType: f.fileType
                )
            }
            let prepareReq = PrepareUploadRequest(
                info: DiscoveryService.shared.myDevice,
                files: filesMap
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
            self.currentSessionId = prepResponse.sessionId

            self.lastUpdateTime = Date()
            self.lastBytesTransferred = totalInitialResume
            if totalInitialResume > 0 {
                self.activeTransfer?.eta = "Melanjutkan transfer..."
            }

            // 3. Concurrent Parallel Upload ("jalan bareng") with worker pool (max 3 simultaneous streams)
            let maxConcurrent = min(3, files.count)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var fileIterator = files.makeIterator()

                for _ in 0..<maxConcurrent {
                    if let file = fileIterator.next(), let token = prepResponse.files[file.id] {
                        group.addTask {
                            try await self.uploadSingleFile(
                                file: file,
                                sessionId: prepResponse.sessionId,
                                token: token,
                                target: target,
                                targetIP: targetIP
                            )
                        }
                    }
                }

                while try await group.next() != nil {
                    if let file = fileIterator.next(), let token = prepResponse.files[file.id] {
                        group.addTask {
                            try await self.uploadSingleFile(
                                file: file,
                                sessionId: prepResponse.sessionId,
                                token: token,
                                target: target,
                                targetIP: targetIP
                            )
                        }
                    }
                }
            }

            // All files completed successfully!
            self.activeTransfer?.bytesTransferred = totalBatchBytes
            self.activeTransfer?.speedMBs = 0.0
            self.activeTransfer?.eta = "Selesai!"
            self.activeTransfer?.isCompleted = true
            self.activeTransfer?.isPaused = false
            self.activeTransfer?.canRetry = false
            self.activeTransfer?.completedFiles = files.count
            bgManager.endTransferBackgroundTask()
            bgManager.updateIdleTimer(isTransferring: false)

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

    private func uploadSingleFile(
        file: OutgoingFile,
        sessionId: String,
        token: String,
        target: DeviceInfo,
        targetIP: String
    ) async throws {
        let resumeOffset = self.fileResumeOffsets[file.id] ?? 0

        let uploadSourceURL: URL
        if resumeOffset > 0 {
            uploadSourceURL = try await Task.detached(priority: .userInitiated) {
                try TransferService.createUploadSliceSync(from: file.fileURL, startingAt: resumeOffset, fileName: file.fileName)
            }.value
        } else {
            uploadSourceURL = file.fileURL
        }

        let uploadURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/localsend/v2/upload?sessionId=\(sessionId)&fileId=\(file.id)&token=\(token)")!
        var uploadReq = URLRequest(url: uploadURL)
        uploadReq.httpMethod = "POST"
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadReq.setValue("\(resumeOffset)", forHTTPHeaderField: "X-KirimAja-Resume-Offset")
        uploadReq.setValue(file.fileName, forHTTPHeaderField: "X-File-Name")
        uploadReq.setValue(file.id, forHTTPHeaderField: "X-KirimAja-File-Id")

        let (uploadData, uploadResp) = try await self.urlSession.upload(for: uploadReq, fromFile: uploadSourceURL, delegate: self)

        if uploadSourceURL != file.fileURL {
            try? FileManager.default.removeItem(at: uploadSourceURL)
        }

        guard let upHttpResp = uploadResp as? HTTPURLResponse, (200...299).contains(upHttpResp.statusCode) else {
            let status = (uploadResp as? HTTPURLResponse)?.statusCode ?? 500
            if status == 409 {
                throw NSError(domain: "TransferError", code: 409, userInfo: [NSLocalizedDescriptionKey: "Transfer dibatalkan"])
            }
            let bodyStr = String(data: uploadData, encoding: .utf8) ?? ""
            throw NSError(domain: "TransferError", code: status, userInfo: [NSLocalizedDescriptionKey: "Gagal mengunggah \(file.fileName): \(bodyStr)"])
        }

        self.fileProgressMap[file.id] = file.fileSize
        self.completedFilesCount += 1
        self.activeTransfer?.completedFiles = self.completedFilesCount
        if (self.activeTransfer?.fileCount ?? 1) > 1 {
            self.activeTransfer?.fileName = "\(self.completedFilesCount)/\(self.activeFiles.count) berkas terkirim"
        }
    }

    public func startSendingBatch(
        files: [OutgoingFile],
        target: DeviceInfo
    ) {
        self.sendTask?.cancel()
        self.sendTask = Task {
            do {
                try await self.sendBatch(files: files, target: target)
            } catch {
                if !Task.isCancelled && (error as NSError).code != NSURLErrorCancelled {
                    print("[TransferService] Batch transfer failed: \(error)")
                }
            }
        }
    }

    public func startSending(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        fileType: String,
        target: DeviceInfo
    ) {
        let fileIdRaw = "\(fileName)_\(fileSize)".data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString
        let fileId = String(fileIdRaw.prefix(32))

        let outgoing = OutgoingFile(
            id: fileId,
            fileURL: fileURL,
            fileName: fileName,
            fileSize: fileSize,
            fileType: fileType
        )
        self.startSendingBatch(files: [outgoing], target: target)
    }

    public func sendFile(
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        fileType: String,
        target: DeviceInfo
    ) async throws {
        let fileIdRaw = "\(fileName)_\(fileSize)".data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "") ?? UUID().uuidString
        let fileId = String(fileIdRaw.prefix(32))

        let outgoing = OutgoingFile(
            id: fileId,
            fileURL: fileURL,
            fileName: fileName,
            fileSize: fileSize,
            fileType: fileType
        )
        try await self.sendBatch(files: [outgoing], target: target)
    }

    public func resumeActiveTransfer() {
        guard let active = self.activeTransfer,
              let target = active.target else { return }

        let files = active.batchFiles
        guard !files.isEmpty else { return }

        self.activeTransfer?.isPaused = false
        self.activeTransfer?.canRetry = false
        self.activeTransfer?.errorMessage = nil
        self.activeTransfer?.eta = "Menghubungkan kembali..."

        self.startSendingBatch(files: files, target: target)
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
        let files = self.activeFiles
        let target = self.currentTarget ?? self.activeTransfer?.target

        self.activeTransfer = nil

        if let target = target, let ip = target.ip {
            Task {
                var urlComponents = URLComponents(string: "\(target.effectiveProtocol)://\(ip):\(target.port)/api/localsend/v2/cancel")
                var queryItems: [URLQueryItem] = []
                if let sid = sid {
                    queryItems.append(URLQueryItem(name: "sessionId", value: sid))
                }
                for f in files {
                    queryItems.append(URLQueryItem(name: "fileId", value: f.id))
                }
                if !queryItems.isEmpty {
                    urlComponents?.queryItems = queryItems
                }
                if let cancelURL = urlComponents?.url {
                    var cancelReq = URLRequest(url: cancelURL)
                    cancelReq.httpMethod = "POST"
                    cancelReq.timeoutInterval = 3.0
                    _ = try? await URLSession.shared.data(for: cancelReq)
                    print("[TransferService] Sent cancel request to desktop: \(ip), sid: \(sid ?? "none")")
                }
            }
        }

        sendTask?.cancel()
        sendTask = nil

        urlSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }

        self.currentSessionId = nil
        self.activeFiles = []
        self.currentTarget = nil
        BackgroundManager.shared.endTransferBackgroundTask()
        BackgroundManager.shared.updateIdleTimer(isTransferring: false)
    }

    // MARK: - URLSessionTaskDelegate Aggregate Progress
    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let fileId = task.originalRequest?.value(forHTTPHeaderField: "X-KirimAja-File-Id") ?? ""
        Task { @MainActor in
            guard var state = self.activeTransfer, !state.isPaused else { return }

            let baseOffset = self.fileResumeOffsets[fileId] ?? 0
            self.fileProgressMap[fileId] = baseOffset + totalBytesSent

            let aggregate = self.fileProgressMap.values.reduce(0, +)
            let total = state.totalBytes

            let now = Date()
            let timeDelta = now.timeIntervalSince(self.lastUpdateTime)
            if timeDelta >= 0.35 {
                let bytesDelta = aggregate - self.lastBytesTransferred
                let speedMBs = max(0.0, (Double(bytesDelta) / (1024.0 * 1024.0)) / timeDelta)
                let remainingBytes = max(0, total - aggregate)
                let etaSecs = speedMBs > 0 ? Int(Double(remainingBytes) / (speedMBs * 1024 * 1024)) : 0
                let etaStr: String
                if etaSecs > 0 {
                    if etaSecs < 60 { etaStr = "\(etaSecs) dtk" }
                    else { etaStr = "\(etaSecs / 60)m \(etaSecs % 60)d" }
                } else {
                    etaStr = "Menghitung..."
                }

                self.activeTransfer?.bytesTransferred = aggregate
                self.activeTransfer?.speedMBs = speedMBs
                self.activeTransfer?.eta = etaStr

                self.lastUpdateTime = now
                self.lastBytesTransferred = aggregate
            }
        }
    }
}
