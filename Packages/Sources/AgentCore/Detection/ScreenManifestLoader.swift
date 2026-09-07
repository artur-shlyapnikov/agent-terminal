import Foundation

// Loads and validates screen manifests from TOML (architecture §3.7).

public enum ScreenManifestLoader {
    /// Parses a manifest from TOML text. Strict: anything outside the schema
    /// or the supported TOML subset is an error, never a silent default.
    public static func parse(_ source: String) throws -> ScreenManifest {
        do {
            let document = try TOMLParser.parse(source)
            return try decode(document)
        } catch let error as TOMLParseError {
            throw ManifestError.parseError(line: error.line, message: error.message)
        }
    }

    public static func parse(data: Data) throws -> ScreenManifest {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ManifestError.wrongType("manifest must be UTF-8")
        }
        return try parse(source)
    }

    /// Loads one of the bundled manifests from the AgentCore resources.
    public static func loadBundled(named name: String, bundle: Bundle? = nil) throws -> ScreenManifest {
        let bundle = bundle ?? Bundle.module
        // SwiftPM drops the target-relative top-level "Resources" component
        // when copying into the bundle ("Resources/Detection" → "Detection"),
        // while Xcode-generated bundles keep the full path — accept both.
        guard let url = bundle.url(
            forResource: name,
            withExtension: "toml",
            subdirectory: "Detection"
        ) ?? bundle.url(
            forResource: name,
            withExtension: "toml",
            subdirectory: "Resources/Detection"
        ) else {
            throw ManifestError.missingField("bundled manifest \(name).toml")
        }
        return try parse(data: Data(contentsOf: url))
    }

    // MARK: Decoding

    private static func decode(_ document: TOMLTable) throws -> ScreenManifest {
        let version = try Int(requireInt(document, "manifestVersion"))
        guard version == Int64(ScreenManifest.supportedManifestVersion) else {
            throw ManifestError.unsupportedManifestVersion(version)
        }

        let kindString = try requireString(document, "agentKind")
        guard let agentKind = AgentKind(rawValue: kindString) else {
            throw ManifestError.agentKindMismatch(expected: .claudeCode, found: kindString)
        }

        let foregroundExecutables = try requireArray(document, "foregroundExecutables").map { value -> String in
            guard case let .string(executable) = value
            else { throw ManifestError.wrongType("foregroundExecutables entries must be strings") }
            return executable
        }
        guard !foregroundExecutables.isEmpty else {
            throw ManifestError.missingField("foregroundExecutables")
        }

        let snapshotRows = document.integer("snapshotRows").map(Int.init) ?? 32
        guard snapshotRows >= 1, snapshotRows <= 64 else {
            throw ManifestError.invalidSnapshotRows(snapshotRows)
        }

        let ruleTables = try requireArrayOfTables(document, "rules")

        var rules: [ScreenRule] = []
        rules.reserveCapacity(ruleTables.count)
        for table in ruleTables {
            try rules.append(decodeRule(table))
        }

        var fallback = FallbackBehavior.unknown
        if let fallbackText = document.string("fallback") {
            switch fallbackText {
            case "unknown": fallback = .unknown
            default: throw ManifestError.unknownLifecycle(fallbackText)
            }
        }

        let manifest = ScreenManifest(
            manifestVersion: version,
            agentKind: agentKind,
            adapterVersionRange: document.string("adapterVersionRange"),
            foregroundExecutables: foregroundExecutables,
            snapshotRows: snapshotRows,
            rules: rules,
            fallback: fallback
        )

        // Compile every regex once at load (§3.7).
        for rule in manifest.rules {
            for matcher in rule.allMatchers + rule.anyMatchers + rule.noneMatchers {
                if matcher.kind == .regex {
                    try CompiledPatternCache.validate(pattern: matcher.pattern)
                }
            }
        }

        return manifest
    }

    private static func decodeRule(_ table: TOMLTable) throws -> ScreenRule {
        let id = try requireString(table, "id")
        let lifecycleText = try requireString(table, "resultingLifecycle")

        var requestKind: InputRequestKind?
        if let requestText = table.string("requestKind") {
            requestKind = try decodeRequestKind(requestText)
        }

        let lifecycle = try decodeLifecycle(lifecycleText, requestKind: requestKind, ruleID: id)

        let priority = try Int(requireInt(table, "priority"))

        var stability: StabilityRequirement =
            .unspecified // §3.5: legacy two-sighting confirmation when the manifest omits the field
        if let milliseconds = table.integer("stabilityMilliseconds") {
            stability = .stable(.milliseconds(milliseconds))
        }

        func matchers(_ key: String) throws -> [ScreenMatcher] {
            guard let values = table.array(key) else { return [] }
            return try values.map { value in
                guard case let .table(matcherTable) = value else {
                    throw ManifestError.wrongType("\(key) entries must be inline tables")
                }
                return try decodeMatcher(matcherTable)
            }
        }

        return try ScreenRule(
            id: id,
            resultingLifecycle: lifecycle,
            priority: priority,
            requestKind: requestKind,
            stabilityRequirement: stability,
            allMatchers: matchers("allMatchers"),
            anyMatchers: matchers("anyMatchers"),
            noneMatchers: matchers("noneMatchers")
        )
    }

    private static func decodeMatcher(_ table: TOMLTable) throws -> ScreenMatcher {
        let pattern = try requireString(table, "pattern")

        let kind: ScreenMatcher.Kind
        switch table.string("kind") ?? "literal" {
        case "literal": kind = .literal
        case "regex": kind = .regex
        case let other: throw ManifestError.unknownMatcherKind(other)
        }

        let caseSensitive = table.bool("caseSensitive") ?? false

        let region: ScreenMatcher.Region
        switch table.string("region") ?? "wholeSnapshot" {
        case "wholeSnapshot":
            region = .wholeSnapshot
        case "lastLine":
            region = .lastLine
        case "lastLines":
            let lines = try Int(requireInt(table, "lines"))
            // 0/negative silently degrading to "last 1 line" would hide
            // manifest authoring mistakes — reject them at load instead.
            guard lines >= 1 else { throw ManifestError.invalidLastLinesCount(lines) }
            region = .lastNLines(lines)
        case let other:
            throw ManifestError.unknownRegion(other)
        }

        return ScreenMatcher(kind: kind, pattern: pattern, caseSensitive: caseSensitive, region: region)
    }

    static func decodeLifecycle(_ text: String, requestKind: InputRequestKind?,
                                ruleID: String) throws -> LifecyclePhase
    {
        switch text {
        case "unknown": return .unknown
        case "starting": return .starting
        case "idle": return .idle
        case "working": return .working
        case "waitingForInput":
            // Every waitingForInput screen rule must classify the request;
            // descriptors stay terminalOnly by default (§3.4 safety).
            guard let kind = requestKind else {
                throw ManifestError.waitingRuleWithoutRequestKind(ruleID)
            }
            return .waitingForInput(InputRequestDescriptor.screenSourced(kind: kind, summary: nil))
        case "stopping": return .stopping
        case "stopped": return .stopped(.userRequested)
        case "failed": return .failed(FailureDescriptor(reason: "screen rule"))
        case let other: throw ManifestError.unknownLifecycle(other)
        }
    }

    static func decodeRequestKind(_ text: String) throws -> InputRequestKind {
        switch text {
        case "freeText": return .freeText
        case "approval": return .approval
        case "selection": return .selection
        case "unknown": return .unknown
        case let other: throw ManifestError.unknownRequestKind(other)
        }
    }

    private static func requireString(_ table: TOMLTable, _ key: String) throws -> String {
        guard let value = table.value(key) else { throw ManifestError.missingField(key) }
        guard case let .string(string) = value else { throw ManifestError.wrongType(key) }
        return string
    }

    private static func requireInt(_ table: TOMLTable, _ key: String) throws -> Int64 {
        guard let value = table.value(key) else { throw ManifestError.missingField(key) }
        guard case let .integer(integer) = value else { throw ManifestError.wrongType(key) }
        return integer
    }

    private static func requireArray(_ table: TOMLTable, _ key: String) throws -> [TOMLValue] {
        guard let value = table.value(key) else { throw ManifestError.missingField(key) }
        guard case let .array(array) = value else { throw ManifestError.wrongType(key) }
        return array
    }

    private static func requireArrayOfTables(_ table: TOMLTable, _ key: String) throws -> [TOMLTable] {
        guard let tables = table.arrayOfTables(key), !tables.isEmpty else {
            throw ManifestError.missingField(key)
        }
        return tables
    }
}
