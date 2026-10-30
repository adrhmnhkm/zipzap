import Foundation

@MainActor
public class TransferService: NSObject, ObservableObject, URLSessionTaskDelegate {
    public static let shared = TransferService()

    @Published public var activeTransfer: ActiveTransferState?

    private var currentTask: URLSessionUploadTask?
    private var lastUpdateTime = Date()
    private var lastBytesTransferred: Int64 = 0
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

        self.activeTransfer = ActiveTransferState(
            fileName: fileName,
            bytesTransferred: 0,
            totalBytes: fileSize,
            speedMBs: 0.0,
            eta: "Menghubungkan...",
            isResume: false
        )

        do {
            // 1. Prepare Upload Request
            let fileId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
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

            let (prepareData, prepareResp) = try await URLSession.shared.data(for: req)
            guard let httpResp = prepareResp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw NSError(domain: "TransferError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Target menolak permintaan pengiriman"])
            }

            let prepResponse = try JSONDecoder().decode(PrepareUploadResponse.self, from: prepareData)
            guard let token = prepResponse.files[fileId] else {
                throw NSError(domain: "TransferError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Token file tidak ditemukan dari penerima"])
            }

            // 2. Upload file stream
            let uploadURL = URL(string: "\(target.effectiveProtocol)://\(targetIP):\(target.port)/api/localsend/v2/upload?sessionId=\(prepResponse.sessionId)&fileId=\(fileId)&token=\(token)")!
            var uploadReq = URLRequest(url: uploadURL)
            uploadReq.httpMethod = "POST"
            uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadReq.setValue("0", forHTTPHeaderField: "X-KirimAja-Resume-Offset")
            uploadReq.setValue(fileName, forHTTPHeaderField: "X-File-Name")

            self.lastUpdateTime = Date()
            self.lastBytesTransferred = 0

            let (uploadData, uploadResp) = try await self.urlSession.upload(for: uploadReq, fromFile: fileURL)
            guard let upHttpResp = uploadResp as? HTTPURLResponse, (200...299).contains(upHttpResp.statusCode) else {
                let bodyStr = String(data: uploadData, encoding: .utf8) ?? ""
                throw NSError(domain: "TransferError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Gagal mengunggah file ke desktop: \(bodyStr)"])
            }

            // Completed!
            self.activeTransfer?.bytesTransferred = fileSize
            self.activeTransfer?.isCompleted = true
            bgManager.endTransferBackgroundTask()
            bgManager.updateIdleTimer(isTransferring: false)

            // Auto-clear success after 3.5 seconds
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.activeTransfer?.isCompleted == true {
                self.activeTransfer = nil
            }

        } catch {
            self.activeTransfer?.errorMessage = error.localizedDescription
            bgManager.endTransferBackgroundTask()
            bgManager.updateIdleTimer(isTransferring: false)
            throw error
        }
    }

    public func cancelTransfer() {
        currentTask?.cancel()
        currentTask = nil
        activeTransfer = nil
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
            guard var state = self.activeTransfer else { return }

            let now = Date()
            let timeDiff = now.timeIntervalSince(self.lastUpdateTime)

            if timeDiff >= 0.3 || totalBytesSent >= state.totalBytes {
                let bytesDiff = totalBytesSent - self.lastBytesTransferred
                let speedBytesSec = timeDiff > 0 ? Double(bytesDiff) / timeDiff : 0.0
                let speedMBs = speedBytesSec / (1024.0 * 1024.0)

                let remainingBytes = max(0, state.totalBytes - totalBytesSent)
                let etaSecs = speedBytesSec > 1024 ? Int(Double(remainingBytes) / speedBytesSec) : 0

                let etaStr: String
                if etaSecs <= 0 {
                    etaStr = "--"
                } else if etaSecs < 60 {
                    etaStr = "\(etaSecs) dtk"
                } else {
                    etaStr = "\(etaSecs / 60)m \(etaSecs % 60)d"
                }

                state.bytesTransferred = totalBytesSent
                state.speedMBs = speedMBs
                state.eta = etaStr

                self.activeTransfer = state
                self.lastUpdateTime = now
                self.lastBytesTransferred = totalBytesSent
            }
        }
    }
}
