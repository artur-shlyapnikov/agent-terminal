import AgentCore
import Foundation

// Visible/detection snapshots (architecture §3.7/§3.21):
//   - detection reads use the SCREEN-space read (live bottom screen, scroll-
//     independent — spike-verified) and are capped at 32 rows / 16 KiB;
//   - visible reads use the viewport (what the user sees);
//   - both are CRLF-normalized and trailing-space-stripped.
//
// Pure functions so normalization is unit-testable without any surface.

public enum TerminalSnapshotService {
    public static let detectionRowLimit = 32
    public static let detectionByteLimit = 16 * 1024

    /// Normalizes raw terminal text: CRLF/CR → LF, trailing whitespace per
    /// line stripped, trailing blank lines dropped, then `maxRows` (keeping
    /// the LAST rows) and `maxBytes` (keeping the LAST bytes, cut at a line
    /// boundary — or mid-line when no LF exists in the retained window)
    /// applied.
    public static func normalize(_ raw: String, maxRows: Int?, maxBytes: Int?) -> String {
        let withLF = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = withLF.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var trimmed = line
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed = trimmed.dropLast()
                }
                return trimmed
            }

        // Drop trailing blank lines (prompt cursor rows etc.).
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        if lines.isEmpty {
            return ""
        }

        // Row cap: keep the last N rows.
        if let maxRows, lines.count > maxRows {
            lines = lines.suffix(maxRows)
        }

        var text = lines.joined(separator: "\n")

        // Byte cap: keep the last maxBytes UTF-8 bytes, cut at a line start.
        if let maxBytes, text.utf8.count > maxBytes {
            let bytes = Array(text.utf8)
            var cut = bytes.count - maxBytes
            var sawLF = false
            // Advance to the first byte after the next LF so we start on a
            // whole line (and never split a UTF-8 sequence).
            while cut < bytes.count {
                if bytes[cut] == 0x0A {
                    sawLF = true
                    break
                }
                cut += 1
            }
            if sawLF {
                cut += 1 // skip the LF itself
            } else {
                // No LF within the retained window (a single long line longer
                // than maxBytes): keep the tail mid-line instead of dropping
                // the whole snapshot; String(decoding:) is lossy-tolerant of
                // a split UTF-8 sequence.
                cut = bytes.count - maxBytes
            }
            guard cut < bytes.count else { return "" }
            text = String(decoding: bytes[cut...], as: UTF8.self)
        }
        return text
    }

    /// Builds a snapshot from a read closure (real surfaces pass their native
    /// reader; fakes pass canned text).
    public static func snapshot(
        read: () -> String?,
        source: TerminalReadSource,
        generation: SurfaceGeneration,
        outputRevision: UInt64
    ) -> TerminalSnapshot? {
        // A nil read is a surface failure (missing/closing/read error), not an
        // empty screen: propagate nil so consumers treat it as no-evidence.
        guard let raw = read() else { return nil }
        switch source {
        case .visible:
            return TerminalSnapshot(
                text: normalize(raw, maxRows: nil, maxBytes: nil),
                outputRevision: outputRevision,
                generation: generation
            )
        case .detection:
            return TerminalSnapshot(
                text: normalize(raw, maxRows: detectionRowLimit, maxBytes: detectionByteLimit),
                outputRevision: outputRevision,
                generation: generation
            )
        }
    }
}
