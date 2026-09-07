import Foundation

/// Best-effort single-line NDJSON reports to the control-plane unix socket
/// (architecture §3.9 step 4/7, §3.16).
///
/// Every report is a COMPLIANT control-v1 request envelope — the same wire
/// shape any client sends (docs/Protocols/control-v1.md):
///
///     {"protocolVersion":1,"requestID":"<uuid>",
///      "method":"launcher.started","params":{…}}
///
/// The server (AgentControl) validates the ticket-generation `token` carried
/// in params; a v1 server silently drops anything that fails validation, so
/// the envelope MUST be exact. Every operation here is fire-and-forget:
///
/// * total connect budget ≤ 250 ms (non-blocking connect + `poll`),
/// * ANY failure — missing socket, refused connection, timeout, short write,
///   auth rejection — is swallowed silently so the exec path is never
///   blocked or aborted,
/// * nothing sensitive beyond the scoped hook token is included (no argv,
///   no environment, no ticket contents; `reason` strings are fixed
///   diagnostics authored by the caller).
enum ControlReporter {
    /// Reported AFTER `setpgid(0,0)` so the consumer sees the final PGID.
    static func started(
        agentID: UUID,
        terminalID: UUID,
        surfaceGeneration: UInt64,
        token: String,
        socketPath: String
    ) {
        let params =
            "{\"agentID\":\"\(agentID.uuidString)\"," +
            "\"terminalID\":\"\(terminalID.uuidString)\"," +
            "\"surfaceGeneration\":\(surfaceGeneration)," +
            "\"pid\":\(getpid()),\"processGroupID\":\(getpgrp())," +
            "\"token\":\"\(escape(token))\"}"
        send(envelope(method: "launcher.started", params: params) + "\n", to: socketPath)
    }

    static func failed(
        reason: String,
        agentID: UUID,
        surfaceGeneration: UInt64,
        token: String,
        socketPath: String
    ) {
        let params =
            "{\"agentID\":\"\(agentID.uuidString)\"," +
            "\"surfaceGeneration\":\(surfaceGeneration)," +
            "\"reason\":\"\(escape(reason))\"," +
            "\"token\":\"\(escape(token))\"}"
        send(envelope(method: "launcher.failed", params: params) + "\n", to: socketPath)
    }

    // MARK: - Envelope

    /// control-v1 request envelope; `requestID` is a fresh UUID per frame.
    private static func envelope(method: String, params: String) -> String {
        "{\"protocolVersion\":1,\"requestID\":\"\(UUID().uuidString)\"," +
            "\"method\":\"\(method)\",\"params\":\(params)}"
    }

    // MARK: - Plumbing

    /// Reasons are authored by this file only (ASCII constants plus errno
    /// names); escape defensively anyway.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .filter { !$0.isNewline }
    }

    private static func send(_ message: String, to socketPath: String) {
        guard !socketPath.isEmpty,
              socketPath.hasPrefix("/")
        else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard !pathBytes.isEmpty, pathBytes.count < pathCapacity else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            _ = memcpy(dest.baseAddress, pathBytes, pathBytes.count)
        }

        // Non-blocking connect so a dead/stale socket costs at most 250 ms.
        let previousFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, previousFlags | O_NONBLOCK)

        var connected = false
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult == 0 {
            connected = true
        } else if errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 250) > 0 {
                var err: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 {
                    connected = true
                }
            }
        }
        guard connected else { return }

        // Back to blocking for one small write (< socket buffer) so the whole
        // line lands; a peer that vanished yields EPIPE/SIGPIPE-free failure
        // (SIGPIPE ignored below) which we discard.
        _ = fcntl(fd, F_SETFL, previousFlags)
        _ = signal(SIGPIPE, SIG_IGN)
        // SIG_IGN is inherited across execve: without this restore every
        // launched agent would run with SIGPIPE ignored and pipelines would
        // report EPIPE instead of dying (§3.9 step 6 contract).
        defer { _ = signal(SIGPIPE, SIG_DFL) }

        message.utf8.withContiguousStorageIfAvailable { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 {
                    break
                }
                offset += n
            }
        }
    }
}
