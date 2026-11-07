import Foundation

/// Task-confined mutable cache: never share this object between parsing tasks.
final class STEPFile {
    struct ComponentRange {
        let type: String
        let range: Range<Int>
    }
    let data: Data
    private(set) var index: [Int: [ComponentRange]] = [:]
    /// Parameter lists of the HEADER records, by keyword (the first of each), parsed on demand.
    private var headerRanges: [String: Range<Int>] = [:]
    private var cache: [Int: [STEPComponent]] = [:]

    init(data: Data, maximumEntityCount: Int = 2_000_000) throws {
        self.data = data
        // Some exporters write a UTF-8 byte order mark before ISO-10303-21; it is not part of the grammar.
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let start = data.starts(with: bom) ? data.startIndex + bom.count : data.startIndex
        var lexer = STEPTokenizer(data: data, range: start..<data.endIndex)
        do {
            try lexer.expect(.word("ISO-10303-21"))
        } catch let error as STEP.ParseError {
            throw STEP.ParseError("Not a STEP (ISO 10303-21) file: \(error.description)", kind: .notSTEP)
        }
        try lexer.expect(.symbol(59))
        try lexer.expect(.word("HEADER"))
        try lexer.expect(.symbol(59))
        while true {
            let token = try lexer.next()
            if token == .word("ENDSEC") { break }
            guard case .word(let name) = token else {
                throw STEP.ParseError("Invalid HEADER record", kind: token == .end ? .truncated : .malformed)
            }
            let range = try Self.componentRange(in: &lexer)
            if headerRanges[name] == nil { headerRanges[name] = range }
            try lexer.expect(.symbol(59))
        }
        try lexer.expect(.symbol(59))
        try lexer.expect(.word("DATA"))
        // Parameterized/multiple DATA sections are deliberately not supported yet.
        try lexer.expect(.symbol(59))
        while true {
            let token = try lexer.next()
            if token == .word("ENDSEC") { break }
            guard case .reference(let id) = token else {
                throw STEP.ParseError("Expected entity record", kind: token == .end ? .truncated : .malformed)
            }
            guard index[id] == nil else { throw STEP.ParseError("Duplicate entity #\(id)") }
            guard index.count < maximumEntityCount else {
                throw STEP.ParseError("Entity count limit exceeded", kind: .limitExceeded)
            }
            try lexer.expect(.symbol(61))
            let first = try lexer.next()
            var components: [ComponentRange] = []
            if case .word(let type) = first {
                components.append(ComponentRange(type: type, range: try Self.componentRange(in: &lexer)))
            } else if first == .symbol(40) {
                while true {
                    let part = try lexer.next()
                    if part == .symbol(41) { break }
                    guard case .word(let type) = part, !components.contains(where: { $0.type == type }) else {
                        throw STEP.ParseError("Invalid complex entity #\(id)")
                    }
                    components.append(ComponentRange(type: type, range: try Self.componentRange(in: &lexer)))
                    guard components.count <= 128 else {
                        throw STEP.ParseError("Too many complex components", kind: .limitExceeded)
                    }
                }
                guard !components.isEmpty else { throw STEP.ParseError("Empty complex entity #\(id)") }
            } else { throw STEP.ParseError("Missing type for #\(id)") }
            try lexer.expect(.symbol(59))
            index[id] = components
        }
        try lexer.expect(.symbol(59))
        try lexer.expect(.word("END-ISO-10303-21"))
        try lexer.expect(.symbol(59))
        try lexer.expect(.end)
    }

    /// Keep the parentheses in the range so the lazy parser can check list grammar.
    private static func componentRange(in lexer: inout STEPTokenizer) throws -> Range<Int> {
        let start = lexer.position
        try lexer.expect(.symbol(40))
        var depth = 1
        while depth > 0 {
            switch try lexer.next() {
                case .symbol(40): depth += 1
                case .symbol(41): depth -= 1
                case .end: throw STEP.ParseError("Unterminated entity parameters", kind: .truncated)
                case .symbol(59), .symbol(61): throw STEP.ParseError("Unterminated entity parameters")
                default: break
            }
            guard depth <= STEPTokenizer.maximumNesting else {
                throw STEP.ParseError("Parameter nesting limit exceeded", kind: .limitExceeded)
            }
        }
        return start..<lexer.position
    }

    /// The HEADER records. Missing or unreadable records leave their fields empty.
    func header() -> STEP.Header {
        func values(_ keyword: String) -> [STEPValue] {
            guard let range = headerRanges[keyword] else { return [] }
            var parser = STEPParameterParser(lexer: STEPTokenizer(data: data, range: range))
            guard (try? parser.lexer.expect(.symbol(40))) != nil, let list = try? parser.list(depth: 1) else { return [] }
            return list
        }
        func text(_ value: STEPValue?) -> String? {
            guard case .string(let string)? = value, !string.isEmpty else { return nil }
            return string
        }
        func texts(_ value: STEPValue?) -> [String] {
            (value?.list ?? []).compactMap { text($0) }
        }
        var header = STEP.Header()
        let description = values("FILE_DESCRIPTION")
        header.descriptions = texts(description.first)
        header.implementationLevel = text(description.count > 1 ? description[1] : nil)
        let name = values("FILE_NAME")
        func field(_ index: Int) -> STEPValue? { index < name.count ? name[index] : nil }
        header.name = text(field(0))
        header.timestamp = text(field(1))
        header.authors = texts(field(2))
        header.organizations = texts(field(3))
        header.preprocessorVersion = text(field(4))
        header.originatingSystem = text(field(5))
        header.authorization = text(field(6))
        header.schemas = texts(values("FILE_SCHEMA").first)
        return header
    }

    func hasType(_ id: Int, _ type: String) -> Bool {
        index[id]?.contains { $0.type == type } ?? false
    }

    func entities(ofTypes types: Set<String>) -> [Int] {
        index.keys.filter { id in index[id]!.contains { types.contains($0.type) } }.sorted()
    }

    func components(_ id: Int) throws -> [STEPComponent] {
        try Task.checkCancellation()
        if let cached = cache[id] { return cached }
        guard let ranges = index[id] else { throw STEP.ParseError("Missing entity #\(id)") }
        let parsed = try ranges.map { component in
            var parser = STEPParameterParser(lexer: STEPTokenizer(data: data, range: component.range))
            try parser.lexer.expect(.symbol(40))
            let values = try parser.list(depth: 1)
            try parser.lexer.expect(.end)
            return STEPComponent(type: component.type, parameters: values)
        }
        cache[id] = parsed
        return parsed
    }

    func parameters(_ id: Int, type: String) throws -> [STEPValue] {
        guard let component = try components(id).first(where: { $0.type == type }) else {
            throw STEP.ParseError("Expected \(type) at #\(id)")
        }
        return component.parameters
    }
}

private struct STEPParameterParser {
    var lexer: STEPTokenizer

    mutating func list(depth: Int) throws -> [STEPValue] {
        guard depth <= STEPTokenizer.maximumNesting else {
            throw STEP.ParseError("Parameter nesting limit exceeded", kind: .limitExceeded)
        }
        var values: [STEPValue] = []
        var token = try lexer.next()
        if token == .symbol(41) { return values }
        while true {
            values.append(try value(token, depth: depth))
            token = try lexer.next()
            if token == .symbol(41) { return values }
            guard token == .symbol(44) else { throw STEP.ParseError("Expected parameter comma") }
            token = try lexer.next()
        }
    }

    mutating func value(_ token: STEPTokenizer.Token, depth: Int) throws -> STEPValue {
        switch token {
            case .integer(let value): return .integer(value)
            case .real(let value): return .real(value)
            case .reference(let id): return .reference(id)
            case .string(let value): return .string(value)
            case .enumeration(let value): return .enumeration(value)
            case .symbol(36): return .unset
            case .symbol(42): return .derived
            case .symbol(40): return .list(try list(depth: depth + 1))
            case .word(let type):
                try lexer.expect(.symbol(40))
                return .typed(type, try list(depth: depth + 1))
            default: throw STEP.ParseError("Invalid parameter near byte \(lexer.position)")
        }
    }
}

extension Array where Element == STEPValue {
    func argument(_ index: Int) throws -> STEPValue {
        guard indices.contains(index) else { throw STEP.ParseError("Missing parameter \(index)") }
        return self[index]
    }
    func reference(at index: Int) throws -> Int {
        guard let id = try argument(index).reference else { throw STEP.ParseError("Expected reference at parameter \(index)") }
        return id
    }
    func references(at index: Int) throws -> [Int] {
        guard let values = try argument(index).list else { throw STEP.ParseError("Expected reference list at parameter \(index)") }
        return try values.map {
            guard let id = $0.reference else { throw STEP.ParseError("Expected reference in list") }
            return id
        }
    }
}
