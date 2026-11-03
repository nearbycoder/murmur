import Foundation

/// Opens the listening port on the router with NAT-PMP, or UPnP IGD when that isn't available,
/// so peers outside the network can connect in.
final class PortMapper {
    private let port: UInt16
    private let queue: DispatchQueue
    private var natpmpSocket: UDPSocket?
    private var ssdpSocket: UDPSocket?
    private var gateway: UInt32?
    private var refreshWork: DispatchWorkItem?
    private var upnpControl: (url: URL, service: String, localIP: String)?
    private var stopped = false
    private var natpmpPending: Set<UInt8> = []
    var onChange: ((String?) -> Void)?

    init(port: UInt16, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    func start() {
        gateway = PortMapper.defaultGateway()
        if gateway != nil { tryNATPMP(attempt: 0) } else { discoverUPnP() }
    }

    func stop() {
        stopped = true
        refreshWork?.cancel()
        if let natpmpSocket, let gateway {
            for op: UInt8 in [1, 2] { natpmpSocket.send(natpmpRequest(op: op, lifetime: 0), to: NodeEndpoint(ip: gateway, port: 5351)) }
        }
        if let upnpControl {
            for proto in ["TCP", "UDP"] {
                soap(upnpControl, action: "DeletePortMapping", body: "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>\(proto)</NewProtocol>") { _ in }
            }
        }
        let socket = natpmpSocket
        queue.asyncAfter(deadline: .now() + 0.5) { socket?.close() }
        ssdpSocket?.close()
    }

    // MARK: NAT-PMP (RFC 6886)

    private func natpmpRequest(op: UInt8, lifetime: UInt32) -> Data {
        var packet = Data([0, op, 0, 0])
        packet.appendUInt16(port)
        packet.appendUInt16(port)
        packet.appendUInt32(lifetime)
        return packet
    }

    private func tryNATPMP(attempt: Int) {
        guard !stopped, let gateway else { return }
        if natpmpSocket == nil {
            natpmpSocket = try? UDPSocket(port: 0, queue: queue)
            natpmpSocket?.onPacket = { [weak self] data, from in
                guard let self, from.ip == gateway, from.port == 5351, data.count >= 16, data[0] == 0 else { return }
                let op = data[1] & 0x7F
                guard data[1] & 0x80 != 0, data.uint16(at: 2) == 0 else { return }
                natpmpPending.remove(op)
                if natpmpPending.isEmpty {
                    let lifetime = TimeInterval(data.uint32(at: 12))
                    onChange?("NAT-PMP")
                    scheduleRefresh(after: max(lifetime / 2, 60)) { [weak self] in self?.tryNATPMP(attempt: 0) }
                }
            }
        }
        guard let natpmpSocket else { discoverUPnP(); return }
        if attempt >= 3 {
            natpmpPending = []
            discoverUPnP()
            return
        }
        natpmpPending = [1, 2]
        for op: UInt8 in [1, 2] { natpmpSocket.send(natpmpRequest(op: op, lifetime: 7200), to: NodeEndpoint(ip: gateway, port: 5351)) }
        queue.asyncAfter(deadline: .now() + 0.5 * pow(2, Double(attempt))) { [weak self] in
            guard let self, !natpmpPending.isEmpty else { return }
            tryNATPMP(attempt: attempt + 1)
        }
    }

    private func scheduleRefresh(after delay: TimeInterval, _ block: @escaping () -> Void) {
        refreshWork?.cancel()
        let work = DispatchWorkItem(block: block)
        refreshWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: UPnP IGD

    private func discoverUPnP() {
        guard !stopped, ssdpSocket == nil else { return }
        guard let socket = try? UDPSocket(port: 0, queue: queue) else { onChange?(nil); return }
        ssdpSocket = socket
        var found = false
        socket.onPacket = { [weak self] data, _ in
            guard let self, !found, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst(9).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value) {
                    found = true
                    fetchDescription(url)
                }
            }
        }
        let targets = ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANPPPConnection:1"]
        for target in targets {
            let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
            socket.send(Data(search.utf8), to: NodeEndpoint(ip: 0xEFFF_FFFA, port: 1900))
        }
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !found else { return }
            ssdpSocket?.close()
            ssdpSocket = nil
            onChange?(nil)
        }
    }

    private func fetchDescription(_ url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let xml = String(data: data, encoding: .utf8) else { return }
            queue.async { self.parseDescription(xml, base: url) }
        }.resume()
    }

    private func parseDescription(_ xml: String, base: URL) {
        let services = xml.components(separatedBy: "<service>").dropFirst()
        for block in services {
            guard let type = PortMapper.tag("serviceType", in: block), type.contains("WANIPConnection") || type.contains("WANPPPConnection"),
                  let control = PortMapper.tag("controlURL", in: block) else { continue }
            let baseURL = PortMapper.tag("URLBase", in: xml).flatMap(URL.init(string:)) ?? base
            guard let controlURL = URL(string: control, relativeTo: baseURL)?.absoluteURL, let host = base.host,
                  let localIP = PortMapper.localAddress(toward: host) else { continue }
            let target = (controlURL, type, localIP)
            addUPnPMapping(target)
            return
        }
        onChange?(nil)
    }

    private func addUPnPMapping(_ target: (url: URL, service: String, localIP: String)) {
        var remaining = 2
        var succeeded = true
        for proto in ["TCP", "UDP"] {
            let body = "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>\(proto)</NewProtocol><NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(target.localIP)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>Murmur</NewPortMappingDescription><NewLeaseDuration>0</NewLeaseDuration>"
            soap(target, action: "AddPortMapping", body: body) { [weak self] ok in
                guard let self else { return }
                remaining -= 1
                succeeded = succeeded && ok
                if remaining == 0 {
                    if succeeded {
                        upnpControl = target
                        onChange?("UPnP")
                        // Some routers drop mappings after a while; renew them.
                        scheduleRefresh(after: 1800) { [weak self] in self?.addUPnPMapping(target) }
                    } else {
                        onChange?(nil)
                    }
                }
            }
        }
    }

    private func soap(_ target: (url: URL, service: String, localIP: String), action: String, body: String, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: target.url, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(target.service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let envelope = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(target.service)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        request.httpBody = Data(envelope.utf8)
        let queue = self.queue
        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            queue.async { completion(ok) }
        }.resume()
    }

    static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Our LAN address on the route to `host`: connect a UDP socket and read its local end.
    static func localAddress(toward host: String) -> String? {
        guard let ip = IPv4Literal(host) ?? DHT.resolve(host, port: 80).first?.ip else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = NodeEndpoint(ip: ip, port: 80).sockaddr
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard ok == 0 else { return nil }
        return NodeEndpoint(local).peerAddress.host
    }

    /// The IPv4 default gateway, read from the routing table.
    static func defaultGateway() -> UInt32? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        let headerSize = MemoryLayout<rt_msghdr>.size
        var offset = 0
        return buffer.withUnsafeBytes { raw -> UInt32? in
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                defer { offset += Int(header.rtm_msglen) }
                guard header.rtm_msglen > 0 else { return nil }
                guard header.rtm_addrs & RTA_DST != 0, header.rtm_addrs & RTA_GATEWAY != 0 else { continue }
                let dstOffset = offset + headerSize
                let dst = raw.loadUnaligned(fromByteOffset: dstOffset, as: sockaddr_in.self)
                guard dst.sin_family == sa_family_t(AF_INET), dst.sin_addr.s_addr == 0 else { continue }
                let dstLength = max(Int(dst.sin_len), 4)
                let rounded = (dstLength + 3) & ~3
                let gw = raw.loadUnaligned(fromByteOffset: dstOffset + rounded, as: sockaddr_in.self)
                guard gw.sin_family == sa_family_t(AF_INET) else { continue }
                return UInt32(bigEndian: gw.sin_addr.s_addr)
            }
            return nil
        }
    }
}
