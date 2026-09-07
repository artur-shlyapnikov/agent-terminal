import Foundation

// Minimal self-contained TOML subset reader (architecture §3.7 manifest
// format). Foundation-only by law (§3.2): no external TOML dependency.
//
// Supported subset — exactly what our bundled detection manifests need:
// - top-level tables `[name]`, dotted headers `[a.b]`, arrays of tables `[[a.b]]`;
// - bare and quoted keys;
// - basic strings with escapes (\t \n \r \" \\ \/ \b \f \uXXXX \UXXXXXXXX),
//   literal single-quoted strings;
// - integers (decimal, underscores), floats, booleans;
// - arrays (possibly multi-line) and single-line inline tables;
// - `#` comments.
//
// Anything outside the subset (dates, multi-line strings, hex/octal/binary,
// newlines inside inline tables) is a strict error.

public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table(TOMLTable)
}

/// Ordered TOML table.
public struct TOMLTable: Equatable, Sendable {
    public private(set) var orderedKeys: [String] = []
    public private(set) var map: [String: TOMLValue] = [:]

    public init() {}

    public subscript(key: String) -> TOMLValue? {
        get { map[key] }
        set {
            if let newValue {
                if map[key] == nil {
                    orderedKeys.append(key)
                }
                map[key] = newValue
            } else {
                if map[key] != nil {
                    orderedKeys.removeAll { $0 == key }
                }
                map[key] = nil
            }
        }
    }

    public func value(_ key: String) -> TOMLValue? {
        map[key]
    }

    public func string(_ key: String) -> String? {
        if case let .string(string)? = map[key] {
            return string
        }
        return nil
    }

    public func integer(_ key: String) -> Int64? {
        if case let .integer(integer)? = map[key] {
            return integer
        }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        if case let .boolean(bool)? = map[key] {
            return bool
        }
        return nil
    }

    public func array(_ key: String) -> [TOMLValue]? {
        if case let .array(array)? = map[key] {
            return array
        }
        return nil
    }

    public func table(_ key: String) -> TOMLTable? {
        if case let .table(table)? = map[key] {
            return table
        }
        return nil
    }

    /// All elements of an array-of-tables key.
    public func arrayOfTables(_ key: String) -> [TOMLTable]? {
        guard let elements = array(key) else { return nil }
        var tables: [TOMLTable] = []
        for element in elements {
            guard case let .table(table) = element else { return nil }
            tables.append(table)
        }
        return tables
    }
}

public struct TOMLParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }

    public var description: String {
        "TOML parse error at line \(line): \(message)"
    }
}

public enum TOMLParser {
    public static func parse(_ source: String) throws -> TOMLTable {
        var scanner = Scanner(source: source)
        return try scanner.parseDocument()
    }

    private struct Scanner {
        let scalars: [Character]
        var index = 0
        var line = 1
        /// Full key paths of tables already defined by a non-array header;
        /// a second explicit definition is an error (TOML 1.0).
        var explicitlyDefinedTables: Set<[String]> = []

        init(source: String) {
            scalars = Array(source)
        }

        // MARK: Cursor

        var isAtEnd: Bool {
            index >= scalars.count
        }

        var current: Character? {
            index < scalars.count ? scalars[index] : nil
        }

        mutating func advance() -> Character? {
            guard index < scalars.count else { return nil }
            let character = scalars[index]
            index += 1
            if character == "\n" {
                line += 1
            }
            return character
        }

        func peek(offset: Int = 0) -> Character? {
            let position = index + offset
            return position < scalars.count ? scalars[position] : nil
        }

        mutating func skipInlineWhitespace() {
            while let character = current, character == " " || character == "\t" || character == "\r" {
                _ = advance()
            }
        }

        mutating func skipTrivia() {
            while let character = current {
                if character == " " || character == "\t" || character == "\n" || character == "\r" {
                    _ = advance()
                } else if character == "#" {
                    while let c = current, c != "\n" {
                        _ = advance()
                    }
                } else {
                    break
                }
            }
        }

        mutating func expectNewlineOrEnd() throws {
            skipInlineWhitespace()
            if current == "#" {
                while let c = current, c != "\n" {
                    _ = advance()
                }
            }
            if let character = current {
                if character == "\n" {
                    _ = advance()
                } else {
                    throw TOMLParseError(line: line, message: "expected end of line, found '\(character)'")
                }
            }
        }

        /// Parses a whole document into a root table.
        mutating func parseDocument() throws -> TOMLTable {
            var document = TOMLTable()
            // Where plain `key = value` pairs land. The last segment may point
            // into an array-of-tables element.
            var insertionPath: [Segment] = []

            while true {
                skipTrivia()
                if isAtEnd {
                    break
                }

                if current == "[" {
                    insertionPath = try parseTableHeader(into: &document)
                    continue
                }

                let key = try Segment.key(parseSimpleKey())
                skipInlineWhitespace()
                if current == "." {
                    throw TOMLParseError(
                        line: line,
                        message: "dotted keys are only supported inside table headers"
                    )
                }

                skipInlineWhitespace()
                guard current == "=" else {
                    throw TOMLParseError(line: line, message: "expected '=' after key")
                }
                _ = advance()
                let value = try parseValue()
                try insert(value, at: insertionPath + [key], into: &document)
                try expectNewlineOrEnd()
            }
            return document
        }

        /// Parses `[table]` / `[[array.of.tables]]`, materializes the target and
        /// returns the insertion path for subsequent key/value pairs.
        mutating func parseTableHeader(into document: inout TOMLTable) throws -> [Segment] {
            _ = advance() // '['
            var isArray = false
            if current == "[" {
                isArray = true
                _ = advance()
            }
            var keys: [String] = []
            try keys.append(parseSimpleKey())
            skipInlineWhitespace()
            while current == "." {
                _ = advance()
                try keys.append(parseSimpleKey())
                skipInlineWhitespace()
            }
            guard current == "]" else {
                throw TOMLParseError(line: line, message: "expected ']' in table header")
            }
            _ = advance()
            if isArray {
                guard current == "]" else {
                    throw TOMLParseError(line: line, message: "expected ']]' for array-of-tables header")
                }
                _ = advance()
            }
            try expectNewlineOrEnd()

            let keySegments = keys.map { Segment.key($0) }
            if isArray {
                // Append a fresh empty element; subsequent keys land inside it.
                try appendArrayElement(keys: keys, into: &document)
                return try keySegments + [.index(arrayCount(keys: keys, in: document) - 1)]
            } else {
                guard !explicitlyDefinedTables.contains(keys) else {
                    throw TOMLParseError(line: line, message: "duplicate table '\(keys.joined(separator: "."))'")
                }
                explicitlyDefinedTables.insert(keys)
                try ensureTable(at: keySegments, into: &document)
                return keySegments
            }
        }

        mutating func parseSimpleKey() throws -> String {
            skipInlineWhitespace()
            guard let character = current else {
                throw TOMLParseError(line: line, message: "unexpected end of input, expected key")
            }
            if character == "\"" {
                return try parseBasicString()
            }
            if character == "'" {
                return try parseLiteralString()
            }
            var key = ""
            while let c = current, isBareKeyCharacter(c) {
                key.append(c)
                _ = advance()
            }
            guard !key.isEmpty else {
                throw TOMLParseError(line: line, message: "invalid key at '\(character)'")
            }
            return key
        }

        func isBareKeyCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }

        // MARK: Values

        mutating func parseValue() throws -> TOMLValue {
            skipInlineWhitespace()
            guard let character = current else {
                throw TOMLParseError(line: line, message: "unexpected end of input, expected value")
            }
            switch character {
            case "\"": return try .string(parseBasicString())
            case "'": return try .string(parseLiteralString())
            case "[": return try parseArray()
            case "{": return try parseInlineTable()
            case "t", "f": return try parseBoolean()
            default: return try parseNumber()
            }
        }

        mutating func parseBasicString() throws -> String {
            _ = advance() // opening quote
            if current == "\"", peek() == "\"" {
                throw TOMLParseError(line: line, message: "multi-line strings are outside the supported TOML subset")
            }
            var result = ""
            var startLine = line
            while let character = advance() {
                if character == "\"" {
                    return result
                }
                if character == "\n" {
                    throw TOMLParseError(line: startLine, message: "unterminated string")
                }
                if character == "\\" {
                    startLine = line
                    guard let escaped = advance() else {
                        throw TOMLParseError(line: line, message: "unterminated escape sequence")
                    }
                    switch escaped {
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{08}")
                    case "f": result.append("\u{0C}")
                    case "u": try result.append(parseUnicodeEscape(digits: 4))
                    case "U": try result.append(parseUnicodeEscape(digits: 8))
                    default:
                        throw TOMLParseError(line: line, message: "unsupported escape '\\\(escaped)'")
                    }
                } else {
                    result.append(character)
                }
            }
            throw TOMLParseError(line: line, message: "unterminated string")
        }

        mutating func parseUnicodeEscape(digits: Int) throws -> Character {
            var scalarText = ""
            for _ in 0 ..< digits {
                guard let character = advance(), character.isHexDigit else {
                    throw TOMLParseError(line: line, message: "invalid \\u escape")
                }
                scalarText.append(character)
            }
            guard let value = UInt32(scalarText, radix: 16),
                  let unicodeScalar = Unicode.Scalar(value)
            else {
                throw TOMLParseError(line: line, message: "invalid unicode escape value")
            }
            return Character(unicodeScalar)
        }

        mutating func parseLiteralString() throws -> String {
            _ = advance()
            var result = ""
            let startLine = line
            while let character = advance() {
                if character == "'" {
                    return result
                }
                if character == "\n" {
                    throw TOMLParseError(line: startLine, message: "unterminated literal string")
                }
                result.append(character)
            }
            throw TOMLParseError(line: line, message: "unterminated literal string")
        }

        mutating func parseBoolean() throws -> TOMLValue {
            if matchWord("true") {
                return .boolean(true)
            }
            if matchWord("false") {
                return .boolean(false)
            }
            throw TOMLParseError(line: line, message: "invalid boolean literal")
        }

        mutating func matchWord(_ word: String) -> Bool {
            let characters = Array(word)
            for (offset, expected) in characters.enumerated() {
                guard peek(offset: offset) == expected else { return false }
            }
            for _ in characters {
                _ = advance()
            }
            return true
        }

        mutating func parseArray() throws -> TOMLValue {
            _ = advance() // '['
            var elements: [TOMLValue] = []
            while true {
                skipTrivia()
                guard let character = current else {
                    throw TOMLParseError(line: line, message: "unterminated array")
                }
                if character == "]" {
                    _ = advance()
                    return .array(elements)
                }
                try elements.append(parseValue())
                skipTrivia()
                if current == "," {
                    _ = advance()
                } else if current == "]" {
                    _ = advance()
                    return .array(elements)
                } else {
                    throw TOMLParseError(line: line, message: "expected ',' or ']' in array")
                }
            }
        }

        mutating func parseInlineTable() throws -> TOMLValue {
            _ = advance() // '{'
            var table = TOMLTable()
            skipInlineWhitespace()
            if current == "}" {
                _ = advance()
                return .table(table)
            }
            while true {
                let key = try parseSimpleKey()
                skipInlineWhitespace()
                guard current == "=" else {
                    throw TOMLParseError(line: line, message: "expected '=' in inline table")
                }
                _ = advance()
                let value = try parseValue()
                guard table.map[key] == nil else {
                    throw TOMLParseError(line: line, message: "duplicate key '\(key)' in inline table")
                }
                table[key] = value
                skipInlineWhitespace()
                if current == "," {
                    _ = advance()
                    skipInlineWhitespace()
                    continue
                }
                if current == "}" {
                    _ = advance()
                    return .table(table)
                }
                throw TOMLParseError(line: line, message: "expected ',' or '}' in inline table")
            }
        }

        mutating func parseNumber() throws -> TOMLValue {
            var text = ""
            while let character = current,
                  character.isNumber || character == "-" || character == "+"
                  || character == "." || character == "e" || character == "E" || character == "_"
            {
                text.append(character)
                _ = advance()
            }
            guard !text.isEmpty else {
                throw TOMLParseError(line: line, message: "invalid value")
            }
            let cleaned = text.replacingOccurrences(of: "_", with: "")
            if cleaned.range(of: "^[+-]?\\d+$", options: .regularExpression) != nil {
                guard let integer = Int64(cleaned) else {
                    throw TOMLParseError(line: line, message: "integer literal out of range")
                }
                return .integer(integer)
            }
            if let double = Double(cleaned) {
                return .float(double)
            }
            throw TOMLParseError(line: line, message: "invalid number literal '\(text)'")
        }

        // MARK: Structural insertion

        enum Segment: Equatable {
            case key(String)
            case index(Int)
        }

        func arrayCount(keys: [String], in table: TOMLTable) throws -> Int {
            guard let count = try arrayElementCount(keys: keys, in: table) else {
                throw TOMLParseError(line: line, message: "internal: array missing after append")
            }
            return count
        }

        /// Appends an empty table element to the array-of-tables at `keys`,
        /// creating the array and any intermediate tables as needed.
        func appendArrayElement(keys: [String], into table: inout TOMLTable) throws {
            precondition(!keys.isEmpty)
            let key = keys[0]
            if keys.count == 1 {
                var elements: [TOMLTable]
                switch table[key] {
                case let .array(values):
                    elements = try values.map { value in
                        guard case let .table(element) = value else {
                            throw TOMLParseError(line: line, message: "'\(key)' mixes tables and other values")
                        }
                        return element
                    }
                case nil:
                    elements = []
                default:
                    throw TOMLParseError(line: line, message: "cannot redefine '\(key)' as array-of-tables")
                }
                elements.append(TOMLTable())
                table[key] = .array(elements.map { .table($0) })
                return
            }
            var subtable: TOMLTable
            switch table[key] {
            case let .table(existing): subtable = existing
            case nil: subtable = TOMLTable()
            default: throw TOMLParseError(line: line, message: "key '\(key)' is not a table")
            }
            try appendArrayElement(keys: Array(keys.dropFirst()), into: &subtable)
            table[key] = .table(subtable)
        }

        func arrayElementCount(keys: [String], in table: TOMLTable) throws -> Int? {
            guard let first = keys.first else { return nil }
            if keys.count == 1 {
                switch table[first] {
                case let .array(values): return values.count
                default: return nil
                }
            }
            guard case let .table(subtable)? = table[first] else { return nil }
            return try arrayElementCount(keys: Array(keys.dropFirst()), in: subtable)
        }

        /// Ensures a plain table exists at the given key path.
        func ensureTable(at segments: [Segment], into table: inout TOMLTable) throws {
            guard case let .key(key)? = segments.first else { return }
            if segments.count == 1 {
                switch table[key] {
                case .table: break
                case nil: table[key] = .table(TOMLTable())
                default: throw TOMLParseError(line: line, message: "cannot redefine '\(key)' as table")
                }
                return
            }
            var subtable: TOMLTable
            switch table[key] {
            case let .table(existing): subtable = existing
            case nil: subtable = TOMLTable()
            default: throw TOMLParseError(line: line, message: "key '\(key)' is not a table")
            }
            try ensureTable(at: Array(segments.dropFirst()), into: &subtable)
            table[key] = .table(subtable)
        }

        /// Inserts `value` at the given path. `.key` steps descend through
        /// tables; a `.key` immediately followed by `.index` descends into the
        /// matching array-of-tables element.
        func insert(_ value: TOMLValue, at segments: [Segment], into table: inout TOMLTable) throws {
            guard let first = segments.first else {
                throw TOMLParseError(line: line, message: "empty key path")
            }
            guard case let .key(key) = first else {
                throw TOMLParseError(line: line, message: "invalid key path")
            }

            // key[i].rest… → descend into array element i.
            if segments.count >= 2, case let .index(index) = segments[1] {
                try insertIntoArrayElement(
                    value,
                    key: key,
                    index: index,
                    rest: Array(segments.dropFirst(2)),
                    into: &table
                )
                return
            }

            if segments.count == 1 {
                guard table[key] == nil else {
                    throw TOMLParseError(line: line, message: "duplicate key '\(key)'")
                }
                table[key] = value
                return
            }

            var subtable: TOMLTable
            switch table[key] {
            case let .table(existing): subtable = existing
            case nil: subtable = TOMLTable()
            default: throw TOMLParseError(line: line, message: "key '\(key)' is not a table")
            }
            try insert(value, at: Array(segments.dropFirst()), into: &subtable)
            table[key] = .table(subtable)
        }

        func insertIntoArrayElement(
            _ value: TOMLValue,
            key: String,
            index: Int,
            rest: [Segment],
            into table: inout TOMLTable
        ) throws {
            var elements: [TOMLTable]
            switch table[key] {
            case let .array(values):
                elements = try values.map { element in
                    guard case let .table(elementTable) = element else {
                        throw TOMLParseError(line: line, message: "'\(key)' mixes tables and other values")
                    }
                    return elementTable
                }
            default:
                throw TOMLParseError(line: line, message: "no array-of-tables '\(key)' is open")
            }
            guard index >= 0, index < elements.count else {
                throw TOMLParseError(line: line, message: "array-of-tables index out of range")
            }
            if rest.isEmpty {
                // A bare value assignment directly on an element is not valid usage.
                throw TOMLParseError(line: line, message: "cannot assign a value to a table element")
            }
            try insert(value, at: rest, into: &elements[index])
            table[key] = .array(elements.map { .table($0) })
        }
    }
}
