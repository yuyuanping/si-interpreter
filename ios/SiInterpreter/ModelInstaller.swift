import Foundation

struct DownloadState {
    var active = false
    var label = ""
    var fileIndex = 0
    var fileCount = 0
    var fileName = ""
    var done: Int64 = 0
    var total: Int64 = 0
    var bytesPerSec: Double = 0
    var message = ""
}

/// Model installer. Network use is confined to exactly this file — the interpretation
/// path never touches a socket.
///
/// Resume matters because these are 200 MB-3 GB files on flaky mobile connections: we
/// write to <name>.part, ask the server for Range, and only rename into place when the
/// byte count matches. A partial .part is never mistaken for an installed model.
final class ModelInstaller: ObservableObject {
    private let store = ModelStore()
    private let lock = NSLock()
    private var cancelled = false

    @Published var state = DownloadState()

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// Downloads every missing file of the bundle, trying both mirrors in order.
    /// Returns true when the bundle passes its size checks afterwards.
    func install(_ bundle: Bundle) async -> Bool {
        lock.lock(); cancelled = false; lock.unlock()
        let dir = store.installDir(bundle.id)
        var lastError: String?

        for base in Bundles.bases {
            var ok = true
            for (i, fs) in bundle.files.enumerated() {
                if isCancelled { return false }
                await MainActor.run {
                    state = DownloadState(active: true, label: bundle.label,
                                          fileIndex: i + 1, fileCount: bundle.files.count,
                                          fileName: fs.local)
                }
                let final = dir.appendingPathComponent(fs.local)
                if let attr = try? FileManager.default.attributesOfItem(atPath: final.path),
                   (attr[.size] as? Int64 ?? 0) >= fs.minBytes { continue }

                if let err = await fetch(bundle.fileUrl(base, fs), fs, final, dir) {
                    ok = false
                    lastError = err
                    break
                }
            }
            if ok {
                await MainActor.run { state = DownloadState(message: "\(bundle.label) 已就绪") }
                return true
            }
            let err = lastError ?? ""
            await MainActor.run { state.message = "\(err)，换镜像重试" }
        }

        let err = lastError ?? "全部镜像均失败"
        await MainActor.run { state = DownloadState(message: err) }
        return false
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// nil on success, otherwise the error message to surface in the UI
    private func fetch(_ urlStr: String, _ fs: FileSpec, _ final: URL, _ dir: URL) async -> String? {
        let part = dir.appendingPathComponent(fs.local + ".part")
        var start: Int64 = 0
        if let attr = try? FileManager.default.attributesOfItem(atPath: part.path) {
            start = attr[.size] as? Int64 ?? 0
        }
        // if the server (or a captive network) returned something tiny, do not trust resume
        if start >= fs.minBytes { try? FileManager.default.removeItem(at: part); start = 0 }

        guard let url = URL(string: urlStr) else { return "URL 无效: \(urlStr)" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            guard let code = http?.statusCode, (200...299).contains(code) else {
                return "HTTP \((http?.statusCode ?? -1)): \(fs.local)"
            }
            // 200 means the server ignored Range: restart from zero rather than append
            // onto an existing partial file, which would silently corrupt the model
            let append = (code == 206 && start > 0)
            if !append { start = 0 }
            let contentLen = Int64(http?.expectedContentLength ?? -1)
            let total = contentLen >= 0 ? (append ? start + contentLen : contentLen) : -1

            // only create a fresh .part when NOT resuming — createFile truncates the
            // existing partial, which would turn every resume into a corrupt file
            if !append {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: part)
            defer { try? fh.close() }
            if append { try fh.seek(toOffset: UInt64(start)) } else { try? fh.truncate(atOffset: 0) }

            var written = start
            var lastTick = Date()
            var lastBytes = start
            // AsyncBytes iterates one byte at a time; flushing per byte would pin the
            // disk, so batch into ~256 KB writes
            var buf = [UInt8]()
            buf.reserveCapacity(262_144)

            func flushBuf() throws {
                if buf.isEmpty { return }
                try fh.write(contentsOf: buf)
                written += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
            }

            for try await b in bytes {
                if isCancelled { return "已取消" }
                buf.append(b)
                if buf.count >= 262_144 {
                    try flushBuf()
                    let now = Date()
                    if now.timeIntervalSince(lastTick) > 0.25 {
                        let dt = now.timeIntervalSince(lastTick)
                        let done = written
                        let bps = Double(written - lastBytes) / max(dt, 0.001)
                        lastTick = now; lastBytes = written
                        let t = total
                        await MainActor.run {
                            state.done = done; state.total = t; state.bytesPerSec = bps
                        }
                    }
                }
            }
            try flushBuf()
            try fh.close()

            // only rename into place when the byte count passed the minimum-size check
            if let attr = try? FileManager.default.attributesOfItem(atPath: part.path),
               (attr[.size] as? Int64 ?? 0) >= fs.minBytes {
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: part, to: final)
                return nil
            }
            return "文件不完整: \(fs.local)"
        } catch {
            if isCancelled { return "已取消" }
            // the localizedDescription is the useful one on iPhone (e.g. the China-region
            // "无线局域网与蜂窝网络" permission rejection reads as a plain offline error)
            return "\(fs.local): \(error.localizedDescription)"
        }
    }

    /// only the app-written copy; Finder-dropped bundles belong to the user's computer
    func delete(_ bundle: Bundle) {
        try? FileManager.default.removeItem(at: store.installDir(bundle.id))
    }
}
