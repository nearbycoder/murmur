import Foundation

/// An IPv4 address and port in compact form, as DHT nodes are identified.
struct NodeEndpoint: Hashable {
    let ip: UInt32 // host byte order
    let port: UInt16

    init(ip: UInt32, port: UInt16) {
        self.ip = ip
        self.port = port
    }

    init?(compact data: Data) {
        guard data.count == 6 else { return nil }
        ip = data.uint32(at: 0)
        port = data.uint16(at: 4)
    }

    init(_ address: sockaddr_in) {
        ip = UInt32(bigEndian: address.sin_addr.s_addr)
        port = UInt16(bigEndian: address.sin_port)
    }

    var compact: Data {
        var out = Data()
        out.appendUInt32(ip)
        out.appendUInt16(port)
        return out
    }

    var ipBytes: Data {
        var out = Data()
        out.appendUInt32(ip)
        return out
    }

    var peerAddress: PeerAddress {
        PeerAddress(host: "\(ip >> 24).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)", port: port)
    }

    var isValid: Bool {
        let first = ip >> 24
        return port != 0 && first != 0 && first != 127 && first < 224
    }

    var sockaddr: sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = ip.bigEndian
        return a
    }
}

/// A non-blocking IPv4 UDP socket read with a dispatch source on the engine queue.
final class UDPSocket {
    private let fd: Int32
    private let source: DispatchSourceRead
    var onPacket: ((Data, NodeEndpoint) -> Void)?

    init(port: UInt16, queue: DispatchQueue, interfaceIndex: UInt32? = nil) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if var index = interfaceIndex {
            setsockopt(sock, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var address = NodeEndpoint(ip: 0, port: port).sockaddr
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(sock)
            throw POSIXError(.init(rawValue: code) ?? .EADDRINUSE)
        }
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
        fd = sock
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = self.fd
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 2048)
            while true {
                var from = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
                }
                if n <= 0 { break }
                self?.onPacket?(Data(buffer[0..<n]), NodeEndpoint(from))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
    }

    func send(_ data: Data, to endpoint: NodeEndpoint) {
        var address = endpoint.sockaddr
        data.withUnsafeBytes { raw in
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        source.cancel()
    }
}
