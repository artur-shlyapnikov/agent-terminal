import AgentCore
import Foundation

// Pure gate math shared by production diagnostics and the acceptance
// harness (§3.7/§6.16). Lives in the PRODUCTION target because the unit
// suite covers it directly; the scenario merely reuses it.

enum DetectionGateMath {
    /// Least-squares slope (bytes per second) over (t, footprint) samples —
    /// soak-gate leak estimator.
    static func leakSlopeBytesPerSecond(_ samples: [(t: Double, bytes: UInt64)]) -> Double {
        guard samples.count > 2 else { return 0 }
        let n = Double(samples.count)
        let meanT = samples.map(\.t).reduce(0, +) / n
        let meanB = samples.map { Double($0.bytes) }.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for s in samples {
            num += (s.t - meanT) * (Double(s.bytes) - meanB)
            den += (s.t - meanT) * (s.t - meanT)
        }
        guard den > 0 else { return 0 }
        return num / den
    }

    /// Projection of the §3.7 version-range demotion (pure; unit-covered in
    /// AdapterVersionRangeTests, wired in DetectionPipeline).
    static func fallbackReason(manifestVersionRange: String?, detectedVersion: String?) -> String? {
        let version = detectedVersion.flatMap(AdapterVersionRange.extractVersion(from:))
        guard AdapterVersionRange.violates(range: manifestVersionRange, version: version) else {
            return nil
        }
        return "adapter version \(version ?? "?") outside manifest range \(manifestVersionRange ?? "?")"
    }
}
