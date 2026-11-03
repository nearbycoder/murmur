import Foundation

/// An HTTP server that has the torrent's files (BEP 19, "GetRight style"). Pieces are fetched with
/// range requests and verified like any other piece.
final class WebSeed {
    let url: String
    var inFlight = Set<Int>()
    var failures = 0
    var nextAttempt = Date.distantPast
    var download = RateMeter()
    var lastError: String?
    var disabled = false

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Murmur/\(PeerIdentity.clientVersion)"]
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(url: String) {
        self.url = url
    }

    static func isSupported(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// The URL of one file: a folder URL gets the torrent's name (and path) appended.
    func fileURL(info: TorrentInfo, file: Int) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        if !info.isMultiFile {
            return URL(string: url.hasSuffix("/") ? url + encode(info.name) : url)
        }
        let base = url.hasSuffix("/") ? url : url + "/"
        return URL(string: base + ([info.name] + info.files[file].path).map(encode).joined(separator: "/"))
    }

    var status: String {
        if disabled { return "Not working" }
        if !inFlight.isEmpty { return "Downloading" }
        if lastError != nil { return "Retrying" }
        return "Ready"
    }

    /// Fetches the byte ranges that make up a piece, calling back with the assembled data.
    func fetch(piece: Int, info: TorrentInfo, segments: [Storage.Segment], size: Int, queue: DispatchQueue, completion: @escaping (Result<Data, Error>) -> Void) {
        var data = Data(count: size)
        var remaining = segments.filter { !info.files[$0.file].isPadding }
        func next() {
            guard let segment = remaining.first else {
                queue.async { completion(.success(data)) }
                return
            }
            remaining.removeFirst()
            guard let url = fileURL(info: info, file: segment.file) else {
                queue.async { completion(.failure(URLError(.badURL))) }
                return
            }
            var request = URLRequest(url: url)
            request.setValue("bytes=\(segment.offset)-\(segment.offset + Int64(segment.length) - 1)", forHTTPHeaderField: "Range")
            WebSeed.session.dataTask(with: request) { body, response, error in
                if let error { queue.async { completion(.failure(error)) }; return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let body else { queue.async { completion(.failure(URLError(.badServerResponse))) }; return }
                var chunk = body
                if status == 200 && body.count >= Int(segment.offset) + segment.length {
                    // A server that ignored the range sent the whole file.
                    chunk = body.subdata(in: Int(segment.offset) ..< Int(segment.offset) + segment.length)
                } else if status != 206 || body.count != segment.length {
                    queue.async { completion(.failure(TrackerError.failure("HTTP \(status)"))) }
                    return
                }
                data.replaceSubrange(segment.position ..< segment.position + segment.length, with: chunk)
                next()
            }.resume()
        }
        next()
    }
}
