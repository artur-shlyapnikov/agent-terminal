import Foundation

// Client used by `agentctl` and helper scripts (architecture §4.5).
//
// Deliberately synchronous and reconnect-free: a control invocation is one
// short-lived connection — connect, handshake, request(s), close. There is no
// retry/reconnect logic by design (idempotency retries are the caller's job,
// keyed by commandID).

public enum ControlReadTimeout: Error {
    /// A receive deadline elapsed with no bytes; not a connection failure.
    case timedOut
    /// The peer performed a clean close (`recv` returned 0); not a failure.
    case closed
}

public final class ControlClient: @unchecked Sendable {
    public let socketPath: String
    private var fd: Int32 = -1
    private var buffer: [UInt8] = []
    /// Bytes `buffer[0 ..< scannedPrefix]` are already known to contain no
    /// newline, so each `readLine` rescans only freshly received bytes.
    private var scannedPrefix = 0
    /// Hoisted recv chunk (mirrors UnixSocketServer.serve): one reusable
    /// buffer per connection instead of a fresh 64 KiB zeroing per line.
    private var chunk = [UInt8](repeating: 0, count: 65536)

    public init(socketPath: String) throws {
        let expanded = NSString(string: socketPath).expandingTildeInPath
        self.socketPath = expanded

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.posix("socket", errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(expanded.utf8)
        guard bytes.count < 104 else {
            Darwin.close(fd)
            fd = -1
            throw ControlFailure(code: .internalError, message: "socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let failure = errno
            Darwin.close(fd)
            fd = -1
            throw SocketError.posix("connect", failure)
        }
    }

    deinit {
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    public func close() {
        if fd >= 0 {
            shutdown(fd, Int32(SHUT_RDWR))
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Bounds each blocking recv so deadline checks can run even when no
    /// event frames arrive (used by the event-driven `agentctl agent wait`).
    public func setReceiveTimeout(milliseconds: Int) {
        var tv = timeval(
            tv_sec: time_t(milliseconds / 1000),
            tv_usec: suseconds_t((milliseconds % 1000) * 1000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Request/response

    public func send(_ request: ControlRequest) throws {
        let data = ControlWire.encode(request)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if written < 0 {
                    guard errno == EINTR else {
                        throw SocketError.posix("send", errno)
                    }
                    continue
                }
                if written == 0 {
                    throw SocketError.posix("send", errno)
                }
                offset += written
            }
        }
    }

    /// Sends a request and awaits its response envelope.
    public func roundtrip(
        method: String,
        params: [String: JSONValue] = [:],
        commandID: String? = nil
    ) throws -> ControlResponse {
        let request = ControlRequest(
            requestID: UUID().uuidString,
            commandID: commandID,
            method: method,
            params: params
        )
        try send(request)
        return try readResponse()
    }

    public func readResponse() throws -> ControlResponse {
        let line = try readLine()
        let text = String(decoding: line, as: UTF8.self)
        switch try ControlWire.parse(line: Substring(text)) {
        case let .response(response):
            return response
        case let .request(request):
            throw ControlFailure.badRequest("unexpected request frame on client connection: \(request.method)")
        }
    }

    /// First index of `\n` in `buffer[from...]` via libc `memchr`, mirroring
    /// UnixSocketServer's fresh-range-only scan: a pointer-based scan that
    /// stays fast even where generic `firstIndex(of:)` is not specialized.
    private static func firstNewline(in buffer: [UInt8], from start: Int) -> Int? {
        guard start < buffer.count else { return nil }
        return buffer.withUnsafeBufferPointer { raw -> Int? in
            guard let base = raw.baseAddress else { return nil }
            let begin = base + start
            guard let hit = memchr(begin, 0x0A, raw.count - start) else { return nil }
            return UnsafeRawPointer(begin).distance(to: UnsafeRawPointer(hit)) + start
        }
    }

    /// Reads one NDJSON line. Throws `ControlReadTimeout.timedOut` when a
    /// receive timeout (see `setReceiveTimeout`) elapses without data, and
    /// `ControlReadTimeout.closed` when the server closes the connection.
    public func readLine() throws -> [UInt8] {
        while true {
            // Scan only bytes not yet known to be newline-free.
            if let newlineIndex = Self.firstNewline(in: buffer, from: scannedPrefix) {
                var line = Array(buffer[0 ..< newlineIndex])
                buffer.removeSubrange(0 ... newlineIndex)
                // Only [0, oldScannedPrefix) was proven newline-free; the
                // hit and everything before it just left the buffer, so the
                // survivors carry over exactly that proven length.
                scannedPrefix = max(0, scannedPrefix - (newlineIndex + 1))
                if line.last == 0x0D {
                    line.removeLast()
                }
                return line
            }
            // Everything buffered so far failed the scan: future scans of it
            // are wasted work. Resume from here once fresh bytes arrive.
            scannedPrefix = buffer.count
            // Read only the bound pointer inside this closure: touching
            // `chunk.count` here would overlap the closure's exclusive
            // mutable access to the same property (runtime exclusivity
            // violation). raw.count IS chunk.count under the binding.
            let received = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(fd, base, raw.count, 0)
            }
            if received <= 0 {
                if received == 0 {
                    // Clean EOF: the server closed its side of the connection.
                    throw ControlReadTimeout.closed
                }
                let err = errno
                if err == EINTR {
                    continue // interrupted syscall; retry the recv
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw ControlReadTimeout.timedOut
                }
                throw SocketError.posix("recv", err)
            }
            buffer.append(contentsOf: chunk[0 ..< received])
        }
    }

    /// Version handshake: verifies the server speaks our protocol generation
    /// before any state-changing call. Mismatch is fatal (no fallback).
    public func handshake() throws {
        let response = try roundtrip(method: ControlMethod.systemPing.rawValue)
        guard response.ok else {
            throw ControlFailure(
                code: response.error?.code ?? .internalError,
                message: response.error?.message ?? "handshake rejected"
            )
        }
        let serverVersion = response.result["protocolVersion"]?.intValue
        guard serverVersion == Int64(ProtocolVersion.current) else {
            throw ControlFailure(
                code: .unsupportedProtocolVersion,
                message: "server protocol v\(serverVersion.map(String.init) ?? "?"), client v\(ProtocolVersion.current)"
            )
        }
    }

    /// Opens an event subscription; returns after consuming the ok-header.
    /// Subsequent lines are event frames until disconnect/Ctrl-C.
    public func openSubscription(agentID: String?) throws -> String {
        var params: [String: JSONValue] = [:]
        if let agentID {
            params["agentID"] = .string(agentID)
        }
        let request = ControlRequest(
            requestID: UUID().uuidString,
            method: ControlMethod.eventsSubscribe.rawValue,
            params: params
        )
        try send(request)
        let header = try readResponse()
        guard header.ok else {
            throw ControlFailure(
                code: header.error?.code ?? .internalError,
                message: header.error?.message ?? "subscription rejected"
            )
        }
        return header.result["subscriptionID"]?.stringValue ?? ""
    }

    /// Next subscription event frame; nil on clean end-of-stream.
    public func nextEventFrame() throws -> [String: JSONValue]? {
        let line: [UInt8]
        do {
            line = try readLine()
        } catch ControlReadTimeout.closed {
            return nil
        }
        let text = String(decoding: line, as: UTF8.self)

        guard let value = try? ControlWire.jsonDecoder.decode(JSONValue.self, from: Data(text.utf8)),
              case let .object(object) = value
        else {
            throw ControlFailure.badRequest("malformed event frame")
        }
        // Server error frame mid-subscription: surface it instead of treating
        // it as clean end-of-stream.
        if let error = object["error"], case let .object(errorBody) = error {
            let message = errorBody["message"]?.stringValue ?? "server reported an error mid-stream"
            throw ControlFailure(
                code: errorBody["code"]?.stringValue.flatMap(ControlErrorCode.init(rawValue:)) ?? .internalError,
                message: message
            )
        }

        // Plain event frame: a bare JSON object carrying an "event" key.
        guard object["event"] != nil else {
            throw ControlFailure.badRequest("unexpected non-event frame")
        }
        return object
    }
}
