import Foundation

/// A minimal in-process fake engine speaking the REAL wire protocol
/// (newline JSON, `unsupported_protocol` semantics) over a real Unix
/// domain socket. Test and smoke-only: it exists so the client, transport
/// and cache layers can be exercised without touching a live engine,
/// real projects or real agent sessions (CONTRIBUTING: 测试用合成来源).
///
/// Not compiled into any UI code path; used by XCTest and the
/// `--smoke-test` self-check.
public final class EngineSimulator {
    /// What the simulator should answer for a request line.
    public typealias Handler = (_ request: Data) -> Data

    public private(set) var socketPath: String = ""
    public private(set) var receivedRequests: [Data] = []

    private var handler: Handler
    private var serverFD: Int32 = -1
    private var running = false
    private let stateLock = NSLock()
    private let thread = Thread.self

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Bind and start serving on a fresh temp socket path.
    public func start() throws {
        // sockaddr_un.sun_path holds 104 bytes; a UUID-named path under
        // the long per-user temp dir overflows it, so keep it short.
        let short = "orxs-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: "/tmp/\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        socketPath = dir.appendingPathComponent("e.sock").path

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.io("simulator socket() failed")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard rc == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw TransportError.io("simulator bind/listen failed: \(String(cString: strerror(errno)))")
        }
        serverFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.serveLoop() }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let fd = serverFD
        serverFD = -1
        stateLock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        if !socketPath.isEmpty {
            // remove the whole short-lived dir (socket + parent)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
        }
    }

    deinit { stop() }

    private func serveLoop() {
        while true {
            stateLock.lock()
            let alive = running
            stateLock.unlock()
            guard alive else { return }

            // poll() so stop() is honored even while idle in accept().
            var pfd = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 150)
            if ready == 0 { continue }              // timeout: re-check `running`
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { continue }
            Thread.detachNewThread { [weak self] in self?.serveClient(clientFD) }
        }
    }

    private func serveClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        connectionLoop: while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                stateLock.lock()
                receivedRequests.append(line)
                let response = handler(line)
                stateLock.unlock()
                var out = response
                out.append(0x0A)
                if !_writeAll(fd, out) { break connectionLoop }
            }
        }
    }

    private func _writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent),
                              raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    // MARK: - Canned behaviors

    /// A valid v1 `overview` response with the given counts.
    public static func overviewResponse(activeRuns: Int, attention: Int,
                                        recentCompleted: Int = 0) -> [String: Any] {
        [
            "op": "overview",
            "ok": true,
            "protocol_version": 1,
            "generated_at": "2026-10-16T00:00:00+00:00",
            "summary": [
                "active_runs": activeRuns,
                "attention": attention,
                "recent_completed": recentCompleted,
                "projects": ["considered": 1, "queried": 1, "excluded": []],
            ],
            "active": (0..<activeRuns).map { i in
                [
                    "project": "/tmp/proj\(i)",
                    "run_id": "R00\(i + 1)",
                    "goal": ["id": "G001", "objective": "目标 \(i)",
                             "status": ["raw": "in_progress", "known": true,
                                        "display": "进行中"]] as [String: Any],
                    "status": ["raw": "running", "known": true,
                               "display": "执行中"],
                    "started_at": "2026-10-16T00:00:00+00:00",
                    "progress": ["completed": 1, "total": 3,
                                 "revision_id": "RV001", "revision": 1],
                    "consumption": [
                        "caliber": "orx_recorded",
                        "tokens": ["input_tokens": 1000 + i,
                                   "output_tokens": 200] as [String: Any],
                        "observed_total": 1200 + i,
                        "missing_fields": 0,
                        "accuracy": ["exact": 2, "estimated": 0,
                                     "unknown": 0],
                    ],
                    "data_as_of": "2026-10-16T00:00:00+00:00",
                ] as [String: Any]
            },
            "attention": (0..<attention).map { i in
                [
                    "kind": "failed_task",
                    "project": "/tmp/proj\(i)",
                    "run_id": "R001",
                    "task_id": "T00\(i + 1)",
                    "revision_id": "RV001",
                    "detail": "task failed",
                ] as [String: Any]
            },
            "recent_completed": [],
            "project_health": [],
            "snapshots": [:],
            "coverage": [:],
            "warnings": [],
        ]
    }

    /// A valid v1 `health` response.
    public static func healthResponse(version: Int = 1) -> [String: Any] {
        [
            "op": "health",
            "ok": true,
            "protocol_version": version,
            "generated_at": "2026-10-16T00:00:00+00:00",
            "engine": ["implemented": true, "protocol_version": version],
        ]
    }

    /// The engine's version-mismatch refusal (engine.py `unsupported_protocol`).
    public static func unsupportedProtocolResponse(requested: Int,
                                                   supported: Int,
                                                   op: String? = nil) -> [String: Any] {
        [
            "op": op ?? "health",
            "ok": false,
            "protocol_version": supported,
            "error": [
                "code": "unsupported_protocol",
                "message": "protocol version \(requested) is not supported by "
                    + "this engine (supported: \(supported)); the request is "
                    + "refused, not taken over",
                "requested": requested,
                "supported": supported,
            ] as [String: Any],
        ]
    }

    public static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}
