import Foundation

enum Status: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

struct CheckResult {
    let number: Int
    let name: String
    var status: Status
    var measured: [String]
    var notes: String

    var row: String {
        var m = measured.joined(separator: "; ")
        if m.isEmpty { m = "—" }
        return "| \(number) | \(name) | **\(status.rawValue)** | \(m) | \(notes.replacingOccurrences(of: "\n", with: " ")) |"
    }
}

/// Accumulates check outcomes, streams them to stdout, and renders
/// Spike/RESULTS.md at the end (also flushed incrementally).
final class ResultsLog {
    private(set) var records: [CheckResult] = []
    let outputPath: String
    private var extraSections: [(String, String)] = []

    init(outputPath: String) {
        self.outputPath = outputPath
    }

    func record(_ r: CheckResult) {
        records.append(r)
        let line = "[CHECK \(r.number)] \(r.status.rawValue): \(r.name)" +
            (r.measured.isEmpty ? "" : " | \(r.measured.joined(separator: "; "))")
        print(line)
        flush()
    }

    func addSection(_ title: String, _ body: String) {
        extraSections.append((title, body))
    }

    func flush() {
        var md = """
        # Stage-0 Architecture Validation Spike — Results

        Generated: \(Date()) by spike-harness (\(ProcessInfo.processInfo.processName))

        | # | Check | Result | Measured | Notes |
        |---|-------|--------|----------|-------|
        \(records.map(\.row).joined(separator: "\n"))

        """
        for (title, body) in extraSections {
            md += "\n## \(title)\n\n\(body)\n"
        }
        try? md.write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    var exitCode: Int32 {
        let blocking = records.filter { $0.status == .fail }
        return blocking.isEmpty ? 0 : 1
    }
}
