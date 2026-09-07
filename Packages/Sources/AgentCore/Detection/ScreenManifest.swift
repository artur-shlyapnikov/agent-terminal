import Foundation

// Screen manifest schema and pure rule evaluation (architecture §3.7).

public struct ScreenMatcher: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case literal, regex }
    public enum Region: Equatable, Sendable {
        case wholeSnapshot
        case lastLine
        case lastNLines(Int)
    }

    public let kind: Kind
    public let pattern: String
    public let caseSensitive: Bool
    public let region: Region

    public init(kind: Kind, pattern: String, caseSensitive: Bool = false, region: Region = .wholeSnapshot) {
        self.kind = kind
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.region = region
    }
}

public enum StabilityRequirement: Equatable, Sendable {
    /// No stability declaration: the engine applies the legacy fallback
    /// windows (two-sighting confirmation at the phase's default interval).
    case unspecified
    /// Emit on the first matching snapshot.
    case none
    /// Emit only after the rule has matched for at least this long without a
    /// newer output revision (hysteresis against flicker).
    case stable(Duration)
}

public struct ScreenRule: Equatable, Sendable {
    public let id: String
    public let resultingLifecycle: LifecyclePhase
    /// Higher evaluates first. Equal-priority conflicts resolve to `unknown`.
    public let priority: Int
    /// Required when the rule produces `waitingForInput`.
    public let requestKind: InputRequestKind?
    public let stabilityRequirement: StabilityRequirement
    public let allMatchers: [ScreenMatcher]
    public let anyMatchers: [ScreenMatcher]
    /// Evaluated BEFORE the positive matchers (§3.7 step 7).
    public let noneMatchers: [ScreenMatcher]

    public init(
        id: String,
        resultingLifecycle: LifecyclePhase,
        priority: Int,
        requestKind: InputRequestKind? = nil,
        stabilityRequirement: StabilityRequirement = .unspecified,
        allMatchers: [ScreenMatcher] = [],
        anyMatchers: [ScreenMatcher] = [],
        noneMatchers: [ScreenMatcher] = []
    ) {
        self.id = id
        self.resultingLifecycle = resultingLifecycle
        self.priority = priority
        self.requestKind = requestKind
        self.stabilityRequirement = stabilityRequirement
        self.allMatchers = allMatchers
        self.anyMatchers = anyMatchers
        self.noneMatchers = noneMatchers
    }
}

/// What the manifest reports when no rule matched.
public enum FallbackBehavior: Equatable, Sendable {
    case unknown
}

public struct ScreenManifest: Equatable, Sendable {
    public static let supportedManifestVersion = 1

    public let manifestVersion: Int
    public let agentKind: AgentKind
    public let adapterVersionRange: String?
    public let foregroundExecutables: [String]
    public let snapshotRows: Int
    public let rules: [ScreenRule]
    public let fallback: FallbackBehavior

    public init(
        manifestVersion: Int,
        agentKind: AgentKind,
        adapterVersionRange: String? = nil,
        foregroundExecutables: [String],
        snapshotRows: Int = 32,
        rules: [ScreenRule],
        fallback: FallbackBehavior = .unknown
    ) {
        self.manifestVersion = manifestVersion
        self.agentKind = agentKind
        self.adapterVersionRange = adapterVersionRange
        self.foregroundExecutables = foregroundExecutables
        self.snapshotRows = snapshotRows
        self.rules = rules
        self.fallback = fallback
    }
}

/// Pure rule evaluation over a normalized snapshot (§3.7 steps 6–8).
/// Regexes are compiled once at manifest load; evaluation is allocation-light.
public enum ScreenManifestEvaluator {
    public static func evaluate(manifest: ScreenManifest, snapshotText: String) -> ScreenEvidencePayload {
        let lines = snapshotText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lastLine = lines.last ?? ""

        // Group rules by priority, descending.
        let priorities = Array(Set(manifest.rules.map(\.priority))).sorted(by: >)

        for priority in priorities {
            let group = manifest.rules.filter { $0.priority == priority }
            var matched: [ScreenRule] = []

            for rule in group {
                // noneMatchers apply BEFORE positive matchers.
                if rule.noneMatchers
                    .contains(where: { matches($0, text: snapshotText, lines: lines, lastLine: lastLine) })
                {
                    continue
                }
                let allOK = rule.allMatchers.allSatisfy { matches(
                    $0,
                    text: snapshotText,
                    lines: lines,
                    lastLine: lastLine
                ) }
                let anyOK = rule.anyMatchers.isEmpty
                    || rule.anyMatchers.contains { matches($0, text: snapshotText, lines: lines, lastLine: lastLine) }
                if allOK, anyOK {
                    matched.append(rule)
                }
            }

            guard !matched.isEmpty else { continue }

            // Distinct lifecycle results at equal priority → unknown, never a
            // random pick (§3.5 flicker rules).
            var distinctResults: [LifecyclePhase] = []
            for rule in matched where !distinctResults.contains(rule.resultingLifecycle) {
                distinctResults.append(rule.resultingLifecycle)
            }
            if distinctResults.count > 1 {
                return .unknown(reason: matched.map(\.id))
            }
            let winner = matched[0]
            return ScreenEvidencePayload(
                matchedRuleID: winner.id,
                resultingLifecycle: winner.resultingLifecycle,
                supportingRules: matched.map(\.id),
                conflictingRules: []
            )
        }

        // Nothing matched anywhere.
        return .unknown(reason: [])
    }

    static func matches(
        _ matcher: ScreenMatcher,
        text: String,
        lines: [String],
        lastLine: String
    ) -> Bool {
        let regionText: String
        switch matcher.region {
        case .wholeSnapshot:
            regionText = text
        case .lastLine:
            regionText = lastLine
        case let .lastNLines(n):
            let slice = lines.suffix(max(1, n))
            regionText = slice.joined(separator: "\n")
        }

        switch matcher.kind {
        case .literal:
            if matcher.caseSensitive {
                return regionText.contains(matcher.pattern)
            }
            return regionText.range(of: matcher.pattern, options: [.caseInsensitive]) != nil
        case .regex:
            guard let regex = CompiledPatternCache.shared.compiled(
                pattern: matcher.pattern,
                caseSensitive: matcher.caseSensitive
            ) else {
                // Invalid patterns can only come from hand-built manifests;
                // the loader rejects them earlier. Treat as non-match.
                return false
            }
            let range = NSRange(regionText.startIndex ..< regionText.endIndex, in: regionText)
            return regex.firstMatch(in: regionText, range: range) != nil
        }
    }
}

/// Compiled-once regex holder (§3.7: "Regex компилируются один раз").
/// NSRegularExpression is immutable and thread-safe for matching.
final class CompiledPattern: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ regex: NSRegularExpression) {
        self.regex = regex
    }
}

final class CompiledPatternCache: @unchecked Sendable {
    static let shared = CompiledPatternCache()
    private let lock = NSLock()
    private var cache: [String: CompiledPattern] = [:]

    func compiled(pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = (caseSensitive ? "s:" : "i:") + pattern
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached.regex
        }
        lock.unlock()

        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        lock.lock()
        cache[key] = CompiledPattern(regex)
        lock.unlock()
        return regex
    }

    /// Loader entry point: validates a pattern eagerly so manifests with bad
    /// regexes fail at load, not at evaluation time.
    static func validate(pattern: String) throws {
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            throw ManifestError.invalidRegex(pattern: pattern, underlying: error.localizedDescription)
        }
    }
}

public enum ManifestError: Error, Equatable, Sendable {
    case parseError(line: Int, message: String)
    case missingField(String)
    case wrongType(String)
    case unsupportedManifestVersion(Int)
    case agentKindMismatch(expected: AgentKind, found: String)
    case unknownLifecycle(String)
    case unknownRequestKind(String)
    case unknownRegion(String)
    case unknownMatcherKind(String)
    case invalidRegex(pattern: String, underlying: String)
    case waitingRuleWithoutRequestKind(String)
    case invalidSnapshotRows(Int)
    case invalidLastLinesCount(Int)
}
