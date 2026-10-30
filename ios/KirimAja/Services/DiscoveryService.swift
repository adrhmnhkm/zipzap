import Foundation
import Network
import UIKit

@MainActor
public class DiscoveryService: ObservableObject {
    public static let shared = DiscoveryService()

    @Published public var discoveredPeers: [DeviceInfo] = []
    @Published public var isScanning: Bool = false
    @Published public var myLocalIP: String = "Tidak diketahui"

    public let myDevice: DeviceInfo

    private var scanTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    private init() {
        let deviceName = UIDevice.current.name.isEmpty ? "Adi's iPhone" : UIDevice.current.name
        self.myDevice = DeviceInfo(
            alias: deviceName,
            version: "2.1",
            deviceModel: "iPhone",
            deviceType: "mobile",
            fingerprint: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            port: 53317,
            protocolStr: "http",
            download: false
        )
    }

    public func startDiscovery() {
        refreshLocalIP()
        broadcastPresence()
        scanNetwork()

        periodicTask?.cancel()
        periodicTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { break }
                self.broadcastPresence()
                await self.performSubnetScan()
            }
        }
    }

    public func stopDiscovery() {
        scanTask?.cancel()
        periodicTask?.cancel()
        isScanning = false
    }

    public func refreshLocalIP() {
        if let ip = getWiFiIPAddress() {
            self.myLocalIP = ip
        } else {
            self.myLocalIP = "Wi-Fi tidak terhubung"
        }
    }

    public func scanNetwork() {
        scanTask?.cancel()
        scanTask = Task {
            await performSubnetScan()
        }
    }

    public func connectManual(ip: String) async -> Bool {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIP.isEmpty else { return false }

        let targetURLStr = "http://\(cleanIP):53317/api/localsend/v2/info"
        guard let url = URL(string: targetURLStr) else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                var peer = try JSONDecoder().decode(DeviceInfo.self, from: data)
                peer.ip = cleanIP
                addOrUpdatePeer(peer)

                registerWith(peer: peer)
                return true
            }
        } catch {
            print("[Discovery] Manual connect failed to \(cleanIP): \(error)")
        }
        return false
    }

    private func performSubnetScan() async {
        guard let myIP = getWiFiIPAddress(), myIP.contains(".") else {
            self.isScanning = false
            return
        }

        self.myLocalIP = myIP
        self.isScanning = true

        let parts = myIP.split(separator: ".")
        guard parts.count == 4 else {
            self.isScanning = false
            return
        }

        let subnetPrefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let myLastOctet = Int(parts[3]) ?? -1

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.2
        config.timeoutIntervalForResource = 1.2
        let session = URLSession(configuration: config)

        await withTaskGroup(of: DeviceInfo?.self) { group in
            for i in 1...254 {
                if i == myLastOctet { continue }
                let hostIP = "\(subnetPrefix)\(i)"
                guard let url = URL(string: "http://\(hostIP):53317/api/localsend/v2/info") else { continue }

                group.addTask {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 1.2
                    do {
                        let (data, resp) = try await session.data(for: req)
                        if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 {
                            var dev = try JSONDecoder().decode(DeviceInfo.self, from: data)
                            dev.ip = hostIP
                            return dev
                        }
                    } catch {}
                    return nil
                }
            }

            for await peerOpt in group {
                if let peer = peerOpt {
                    self.addOrUpdatePeer(peer)
                    self.registerWith(peer: peer)
                }
            }
        }

        self.isScanning = false
    }

    private func addOrUpdatePeer(_ peer: DeviceInfo) {
        if let idx = discoveredPeers.firstIndex(where: { $0.fingerprint == peer.fingerprint || ($0.ip == peer.ip && $0.port == peer.port) }) {
            discoveredPeers[idx] = peer
        } else {
            discoveredPeers.append(peer)
        }
    }

    public func registerWith(peer: DeviceInfo) {
        guard let peerIP = peer.ip, let url = URL(string: "\(peer.effectiveProtocol)://\(peerIP):\(peer.port)/api/localsend/v2/register") else {
            return
        }

        var myInfo = self.myDevice
        myInfo.ip = getWiFiIPAddress()

        Task.detached(priority: .background) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 3.0

            do {
                req.httpBody = try JSONEncoder().encode(myInfo)
                let (_, response) = try await URLSession.shared.data(for: req)
                if let httpResp = response as? HTTPURLResponse {
                    print("[Discovery] Registered with \(peer.alias) -> HTTP \(httpResp.statusCode)")
                }
            } catch {
                print("[Discovery] Failed to register with \(peer.alias): \(error)")
            }
        }
    }

    public func broadcastPresence() {
        let alias = self.myDevice.alias
        let fingerprint = self.myDevice.fingerprint

        Task.detached(priority: .background) {
            let announcement = AnnouncementMessage(
                alias: alias,
                version: "2.1",
                deviceModel: "iPhone",
                deviceType: "mobile",
                fingerprint: fingerprint,
                port: 53317,
                protocolStr: "http",
                download: false,
                announce: true
            )

            guard let jsonData = try? JSONEncoder().encode(announcement) else { return }

            let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { return }
            defer { close(sock) }

            var broadcastEnable: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

            // 1. Subnet Broadcast to 255.255.255.255:53317
            var bcAddr = sockaddr_in()
            bcAddr.sin_family = sa_family_t(AF_INET)
            bcAddr.sin_port = UInt16(53317).bigEndian
            inet_pton(AF_INET, "255.255.255.255", &bcAddr.sin_addr)

            jsonData.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &bcAddr) { addrPtr in
                    _ = addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(sock, rawBuf.baseAddress, rawBuf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            // 2. Multicast to 224.0.0.167:53317
            var mcAddr = sockaddr_in()
            mcAddr.sin_family = sa_family_t(AF_INET)
            mcAddr.sin_port = UInt16(53317).bigEndian
            inet_pton(AF_INET, "224.0.0.167", &mcAddr.sin_addr)

            jsonData.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &mcAddr) { addrPtr in
                    _ = addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(sock, rawBuf.baseAddress, rawBuf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name.starts(with: "en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
