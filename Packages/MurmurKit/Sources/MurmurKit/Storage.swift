import Foundation

enum StorageError: LocalizedError {
    case missingData
    case io(String, Int32)

    var errorDescription: String? {
        switch self {
        case .missingData: "Some downloaded data is missing from disk."
        case .io(let path, let code): "Couldn't access “\((path as NSString).lastPathComponent)”: \(String(cString: strerror(code)))"
        }
    }
}

/// Maps pieces onto the torrent's files and reads and writes them. Used only on the disk queue.
final class Storage {
    let info: TorrentInfo
    let root: URL
    private var handles: [Int: Int32] = [:]
    private var recent: [Int] = []
    private let maxHandles = 32

    init(info: TorrentInfo, root: URL) {
        self.info = info
        self.root = root
    }

    deinit { closeAll() }

    /// The torrent's top-level item on disk: its folder, or its only file.
    var contentURL: URL { root.appendingPathComponent(info.name) }

    func url(forFile index: Int) -> URL {
        if !info.isMultiFile { return root.appendingPathComponent(info.name) }
        return info.files[index].path.reduce(root.appendingPathComponent(info.name)) { $0.appendingPathComponent($1) }
    }

    struct Segment {
        let file: Int
        let offset: Int64
        let length: Int
        /// Where this segment starts within the requested range.
        let position: Int
    }

    func segments(offset: Int64, length: Int) -> [Segment] {
        let files = info.files
        // Binary search for the first file that ends after `offset`.
        var lo = 0, hi = files.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if files[mid].offset + files[mid].length <= offset { lo = mid + 1 } else { hi = mid }
        }
        var out: [Segment] = []
        var remaining = length
        var position = 0
        var cursor = offset
        var i = lo
        while remaining > 0 && i < files.count {
            let file = files[i]
            let end = file.offset + file.length
            if file.length > 0 && cursor < end {
                let take = Int(min(Int64(remaining), end - cursor))
                out.append(Segment(file: i, offset: cursor - file.offset, length: take, position: position))
                remaining -= take
                position += take
                cursor += Int64(take)
            }
            i += 1
        }
        return out
    }

    func pieceSegments(_ piece: Int) -> [Segment] {
        segments(offset: Int64(piece) * Int64(info.pieceLength), length: info.pieceSize(piece))
    }

    func write(piece: Int, data: Data) throws {
        for segment in pieceSegments(piece) where !info.files[segment.file].isPadding {
            let fd = try handle(for: segment.file, create: true)
            try data.withUnsafeBytes { raw in
                var written = 0
                while written < segment.length {
                    let n = pwrite(fd, raw.baseAddress! + segment.position + written, segment.length - written, off_t(segment.offset) + off_t(written))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw StorageError.io(url(forFile: segment.file).path, errno)
                    }
                    written += n
                }
            }
        }
    }

    func read(piece: Int, begin: Int, length: Int) throws -> Data {
        let start = Int64(piece) * Int64(info.pieceLength) + Int64(begin)
        var out = Data(count: length)
        for segment in segments(offset: start, length: length) {
            if info.files[segment.file].isPadding { continue } // already zeros
            let fd = try handle(for: segment.file, create: false)
            try out.withUnsafeMutableBytes { raw in
                var done = 0
                while done < segment.length {
                    let n = pread(fd, raw.baseAddress! + segment.position + done, segment.length - done, off_t(segment.offset) + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw StorageError.io(url(forFile: segment.file).path, errno)
                    }
                    if n == 0 { throw StorageError.missingData }
                    done += n
                }
            }
        }
        return out
    }

    /// True when every file the piece touches exists and is long enough to hold it.
    func mightHave(piece: Int, sizes: [Int64?]) -> Bool {
        for segment in pieceSegments(piece) where !info.files[segment.file].isPadding {
            guard let size = sizes[segment.file], size >= segment.offset + Int64(segment.length) else { return false }
        }
        return true
    }

    func fileSizes() -> [Int64?] {
        (0..<info.files.count).map { i in
            if info.files[i].isPadding { return nil }
            var st = stat()
            guard stat(url(forFile: i).path, &st) == 0 else { return nil }
            return Int64(st.st_size)
        }
    }

    func fileModificationDates() -> [Double] {
        (0..<info.files.count).map { i in
            var st = stat()
            guard !info.files[i].isPadding, stat(url(forFile: i).path, &st) == 0 else { return 0 }
            return Double(st.st_mtimespec.tv_sec)
        }
    }

    private func handle(for file: Int, create: Bool) throws -> Int32 {
        if let fd = handles[file] {
            if let i = recent.firstIndex(of: file) { recent.remove(at: i); recent.append(file) }
            return fd
        }
        let url = url(forFile: file)
        if create {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var fd = open(url.path, O_RDWR | (create ? O_CREAT : 0), 0o644)
        if fd < 0 && !create && errno == EACCES { fd = open(url.path, O_RDONLY) }
        guard fd >= 0 else {
            if errno == ENOENT { throw StorageError.missingData }
            throw StorageError.io(url.path, errno)
        }
        handles[file] = fd
        recent.append(file)
        if recent.count > maxHandles {
            let evict = recent.removeFirst()
            if let old = handles.removeValue(forKey: evict) { Darwin.close(old) }
        }
        return fd
    }

    func closeAll() {
        for fd in handles.values { Darwin.close(fd) }
        handles.removeAll()
        recent.removeAll()
    }

    /// Flushes written data to disk, for when a torrent finishes or stops.
    func sync() {
        for fd in handles.values { fsync(fd) }
    }
}
