import Foundation

// Manifest adapterVersionRange enforcement (§3.7, stage-16 adverse gate 6c).
//
// A CLI upgrade may ship an adapter whose on-disk output no longer matches the
// bundled screen manifest's expectations (`adapterVersionRange = ">=1.0 <3.0"`).
// Per §3.10/§3.17 the launch is NEVER blocked — the agent keeps working — but
// screen detection is demoted to FALLBACK with a visible operator warning
// until the bundled manifests catch up.
//
// Pure function so every edge is directly unit-testable.

public enum AdapterVersionRange {
    /// One parsed comparator inside a space-separated range expression.
    struct Constraint: Equatable {
        enum Op: String {
            case gte = ">="
            case lte = "<="
            case gt = ">"
            case lt = "<"
            case eq = "="
        }

        let op: Op
        let components: [Int]

        func satisfied(by other: [Int]) -> Bool {
            switch op {
            case .gte: Self.compare(other, components) >= 0
            case .lte: Self.compare(other, components) <= 0
            case .gt: Self.compare(other, components) > 0
            case .lt: Self.compare(other, components) < 0
            case .eq: Self.compare(other, components) == 0
            }
        }

        /// Component-wise numeric comparison; missing components count as 0.
        static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
            let width = max(lhs.count, rhs.count)
            let pad = { (v: [Int]) in v + Array(repeating: 0, count: width - v.count) }
            let l = pad(lhs), r = pad(rhs)
            for i in 0 ..< width where l[i] != r[i] {
                return l[i] < r[i] ? -1 : 1
            }
            return 0
        }
    }

    /// Parses `"​>=1.0 <3.0"` style expressions. Unparsable constraints are
    /// dropped individually; an unparsable WHOLE expression yields nil.
    static func parse(_ expression: String) -> [Constraint] {
        var constraints: [Constraint] = []
        for token in expression.split(separator: " ") {
            guard !token.isEmpty else { continue }
            let ops: [(prefix: String, op: Constraint.Op)] = [
                (">=", .gte), ("<=", .lte), (">", .gt), ("<", .lt), ("=", .eq),
            ]
            if let match = ops.first(where: { token.hasPrefix($0.prefix) }) {
                let digits = token.dropFirst(match.prefix.count)
                if let components = parseComponents(digits) {
                    constraints.append(Constraint(op: match.op, components: components))
                }
            }
        }
        return constraints
    }

    private static func parseComponents(_ text: some StringProtocol) -> [Int]? {
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// True when `detectedVersion` (e.g. "1.2.9") violates any constraint of
    /// `range`. A missing range or a missing/unparsable version NEVER counts
    /// as a violation — absence of evidence must not demote detection.
    public static func violates(range: String?, version: String?) -> Bool {
        guard let range, !range.isEmpty,
              let version, !version.isEmpty else { return false }
        let constraints = parse(range)
        guard !constraints.isEmpty,
              let components = parseComponents(version) else { return false }
        // Violation semantics: ANY unsatisfied constraint demotes the source.
        return !constraints.allSatisfy { $0.satisfied(by: components) }
    }

    /// Extracts a numeric dotted version ("999.0.0") from a probe output
    /// line like `"opencode 999.0.0"`; nil when no numeric component exists.
    public static func extractVersion(from line: String) -> String? {
        for rawToken in line.split(separator: " ") {
            let trimmed = Substring(rawToken).trimmingCharacters(in: CharacterSet(charactersIn: "v,;"))
            let token = trimmed.drop(while: { $0 == "v" })
            let parts = token.split(separator: ".")
            if !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
               parts.contains(where: { Int($0) != nil })
            {
                return String(token)
            }
        }
        return nil
    }
}
