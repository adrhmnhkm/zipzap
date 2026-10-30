import Foundation

public struct DeviceInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String { fingerprint }
    public let alias: String
    public let version: String?
    public let deviceModel: String?
    public let deviceType: String?
    public let fingerprint: String
    public let port: UInt16
    public let protocolStr: String?
    public let download: Bool?
    public var ip: String?

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, ip
        case protocolStr = "protocol"
    }

    public init(
        alias: String,
        version: String = "2.1",
        deviceModel: String = "iPhone",
        deviceType: String = "mobile",
        fingerprint: String = UUID().uuidString,
        port: UInt16 = 53317,
        protocolStr: String = "http",
        download: Bool = false,
        ip: String? = nil
    ) {
        self.alias = alias
        self.version = version
        self.deviceModel = deviceModel
        self.deviceType = deviceType
        self.fingerprint = fingerprint
        self.port = port
        self.protocolStr = protocolStr
        self.download = download
        self.ip = ip
    }

    public var effectiveProtocol: String {
        protocolStr?.lowercased() == "https" ? "https" : "http"
    }
}

public struct AnnouncementMessage: Codable, Sendable {
    public let alias: String
    public let version: String
    public let deviceModel: String?
    public let deviceType: String?
    public let fingerprint: String
    public let port: UInt16
    public let protocolStr: String?
    public let download: Bool
    public let announce: Bool

    enum CodingKeys: String, CodingKey {
        case alias, version, deviceModel, deviceType, fingerprint, port, download, announce
        case protocolStr = "protocol"
    }
}

public struct PrepareUploadRequest: Codable, Sendable {
    public let info: DeviceInfo
    public let files: [String: FileMetadata]

    public init(info: DeviceInfo, files: [String: FileMetadata]) {
        self.info = info
        self.files = files
    }
}

public struct FileMetadata: Codable, Sendable {
    public let id: String
    public let fileName: String
    public let size: Int64
    public let fileType: String
    public let sha256: String?
    public let preview: String?

    public init(id: String, fileName: String, size: Int64, fileType: String, sha256: String? = nil, preview: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.size = size
        self.fileType = fileType
        self.sha256 = sha256
        self.preview = preview
    }
}

public struct PrepareUploadResponse: Codable, Sendable {
    public let sessionId: String
    public let files: [String: String] // fileId -> token
}

public struct ActiveTransferState: Identifiable, Sendable {
    public let id = UUID()
    public var fileName: String
    public var bytesTransferred: Int64
    public var totalBytes: Int64
    public var speedMBs: Double
    public var eta: String
    public var isResume: Bool
    public var isCompleted: Bool = false
    public var isPaused: Bool = false
    public var errorMessage: String? = nil
    public var canRetry: Bool = false
    public var fileCount: Int = 1
    public var completedFiles: Int = 0

    // Context for resuming
    public var fileURL: URL? = nil
    public var fileType: String? = nil
    public var target: DeviceInfo? = nil
    public var batchFiles: [OutgoingFile] = []

    public init(
        fileName: String,
        bytesTransferred: Int64,
        totalBytes: Int64,
        speedMBs: Double,
        eta: String,
        isResume: Bool,
        isCompleted: Bool = false,
        isPaused: Bool = false,
        errorMessage: String? = nil,
        canRetry: Bool = false,
        fileURL: URL? = nil,
        fileType: String? = nil,
        target: DeviceInfo? = nil,
        fileCount: Int = 1,
        completedFiles: Int = 0,
        batchFiles: [OutgoingFile] = []
    ) {
        self.fileName = fileName
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speedMBs = speedMBs
        self.eta = eta
        self.isResume = isResume
        self.isCompleted = isCompleted
        self.isPaused = isPaused
        self.errorMessage = errorMessage
        self.canRetry = canRetry
        self.fileURL = fileURL
        self.fileType = fileType
        self.target = target
        self.fileCount = fileCount
        self.completedFiles = completedFiles
        self.batchFiles = batchFiles
    }
}

public struct OutgoingFile: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let fileType: String

    public init(id: String, fileURL: URL, fileName: String, fileSize: Int64, fileType: String) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.fileType = fileType
    }
}
