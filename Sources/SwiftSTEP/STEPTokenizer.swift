import Foundation

struct STEPTokenizer {
    enum Token: Equatable {
        case word(String), string(String), reference(Int), integer(Int), real(Double), enumeration(String)
        case symbol(UInt8), end
    }

    let data: Data
    private(set) var position: Int
    let end: Int
    static let maximumNesting = 128
    private static let maximumTokenBytes = 1_048_576

    init(data: Data, range: Range<Int>? = nil) {
        self.data = data
        position = range?.lowerBound ?? data.startIndex
        end = range?.upperBound ?? data.endIndex
    }

    private func digit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private func letter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
    }
    private func progress(from start: Int) throws {
        if (position - start) % 4096 == 0 { try Task.checkCancellation() }
        guard position - start <= Self.maximumTokenBytes else {
            throw STEP.ParseError("Token exceeds size limit at byte \(start)", kind: .limitExceeded)
        }
    }
    private func text(_ range: Range<Int>) -> String {
        String(decoding: data[range], as: UTF8.self)
    }

    mutating func next() throws -> Token {
        try Task.checkCancellation()
        // Whitespace and comments are recognized only outside strings.
        while position < end {
            let b = data[position]
            if b == 32 || b == 9 || b == 10 || b == 13 {
                position += 1
                if position % 4096 == 0 { try Task.checkCancellation() }
            } else if b == 47 && position + 1 < end && data[position + 1] == 42 {
                position += 2
                var closed = false
                while position + 1 < end {
                    if position % 4096 == 0 { try Task.checkCancellation() }
                    if data[position] == 42 && data[position + 1] == 47 {
                        position += 2
                        closed = true
                        break
                    }
                    position += 1
                }
                guard closed else { throw STEP.ParseError("Unterminated comment", kind: .truncated) }
            } else { break }
        }
        guard position < end else { return .end }
        let start = position
        let b = data[position]
        position += 1
        if b == 39 {
            var bytes: [UInt8] = []
            while position < end {
                try progress(from: start)
                let current = data[position]
                position += 1
                if current == 39 {
                    if position < end && data[position] == 39 {
                        bytes.append(39)
                        position += 1
                    } else { return .string(STEPStringEscapes.decode(String(decoding: bytes, as: UTF8.self))) }
                } else { bytes.append(current) }
            }
            throw STEP.ParseError("Unterminated string at byte \(start)", kind: .truncated)
        }
        if b == 35 {
            let digits = position
            while position < end && digit(data[position]) {
                position += 1
                try progress(from: start)
            }
            guard position > digits, let id = Int(text(digits..<position)), id > 0 else {
                throw STEP.ParseError("Invalid entity reference at byte \(start)")
            }
            return .reference(id)
        }
        // A user-defined keyword is `!NAME`; it lexes as a word like any other entity type.
        if letter(b) || (b == 33 && position < end && letter(data[position])) {
            while position < end && (letter(data[position]) || digit(data[position]) || data[position] == 45) {
                position += 1
                try progress(from: start)
            }
            return .word(text(start..<position).uppercased())
        }
        if b == 46 && position < end && letter(data[position]) {
            let nameStart = position
            while position < end && (letter(data[position]) || digit(data[position])) {
                position += 1
                try progress(from: start)
            }
            guard position < end && data[position] == 46 else {
                throw STEP.ParseError("Unterminated enumeration at byte \(start)")
            }
            let name = text(nameStart..<position).uppercased()
            position += 1
            return .enumeration(name)
        }
        if digit(b) || b == 43 || b == 45 || b == 46 {
            position = start
            if data[position] == 43 || data[position] == 45 { position += 1 }
            var digits = 0
            while position < end && digit(data[position]) {
                digits += 1; position += 1
                try progress(from: start)
            }
            var isReal = false
            if position < end && data[position] == 46 {
                isReal = true; position += 1
                while position < end && digit(data[position]) {
                    digits += 1; position += 1
                    try progress(from: start)
                }
            }
            guard digits > 0 else { throw STEP.ParseError("Invalid number at byte \(start)") }
            if position < end && (data[position] == 69 || data[position] == 101) {
                isReal = true; position += 1
                if position < end && (data[position] == 43 || data[position] == 45) { position += 1 }
                let exponentStart = position
                while position < end && digit(data[position]) {
                    position += 1
                    try progress(from: start)
                }
                guard position > exponentStart else { throw STEP.ParseError("Missing exponent digits") }
            }
            let spelling = text(start..<position)
            if !isReal, let value = Int(spelling) { return .integer(value) }
            guard isReal, let value = Double(spelling), value.isFinite else {
                throw STEP.ParseError("Invalid or overflowing number at byte \(start)")
            }
            return .real(value)
        }
        if [UInt8(40), 41, 44, 59, 61, 36, 42].contains(b) { return .symbol(b) }
        throw STEP.ParseError("Unexpected byte \(b) at \(start)")
    }

    mutating func expect(_ token: Token) throws {
        let found = try next()
        guard found == token else {
            // Running out of file where something was due means the file was cut short.
            throw STEP.ParseError("Expected \(token) near byte \(position)", kind: found == .end ? .truncated : .malformed)
        }
    }
}

/// The control directives of ISO 10303-21 strings (clause 6.4.3), which carry characters outside
/// basic ASCII: `\\` (a backslash), `\X\hh` (ISO 8859-1), `\S\c` (ISO 8859-1 character, high half),
/// `\X2\hhhh...\X0\` (UTF-16) and `\X4\hhhhhhhh...\X0\` (UTF-32). `\Pn\` code page selectors are
/// dropped. Malformed sequences are kept as written rather than failing the import.
enum STEPStringEscapes {
    static func decode(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let input = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        func hex(_ range: Range<Int>) -> UInt32? {
            guard range.upperBound <= input.count else { return nil }
            var value: UInt32 = 0
            for i in range {
                guard let digit = Self.hexValue(input[i]) else { return nil }
                value = value << 4 | digit
            }
            return value
        }
        func startsWith(_ marker: String, at position: Int) -> Bool {
            let scalars = Array(marker.unicodeScalars)
            guard position + scalars.count <= input.count else { return false }
            return Array(input[position..<(position + scalars.count)]) == scalars
        }

        while index < input.count {
            let scalar = input[index]
            guard scalar == "\\" else {
                output.append(scalar)
                index += 1
                continue
            }
            // \\ is one backslash.
            if startsWith("\\\\", at: index) {
                output.append("\\")
                index += 2
            // \X2\ ... \X0\ : UTF-16 code units, four hex digits each.
            } else if startsWith("\\X2\\", at: index), let close = find("\\X0\\", in: input, from: index + 4),
                      (close - (index + 4)) % 4 == 0 {
                var units: [UInt16] = []
                var position = index + 4
                var valid = true
                while position < close {
                    guard let value = hex(position..<(position + 4)) else { valid = false; break }
                    units.append(UInt16(truncatingIfNeeded: value))
                    position += 4
                }
                if valid {
                    output.append(contentsOf: String(decoding: units, as: UTF16.self).unicodeScalars)
                    index = close + 4
                } else {
                    output.append(scalar)
                    index += 1
                }
            // \X4\ ... \X0\ : UTF-32, eight hex digits each.
            } else if startsWith("\\X4\\", at: index), let close = find("\\X0\\", in: input, from: index + 4),
                      (close - (index + 4)) % 8 == 0 {
                var scalars: [Unicode.Scalar] = []
                var position = index + 4
                var valid = true
                while position < close {
                    guard let value = hex(position..<(position + 8)), let character = Unicode.Scalar(value) else {
                        valid = false
                        break
                    }
                    scalars.append(character)
                    position += 8
                }
                if valid {
                    output.append(contentsOf: scalars)
                    index = close + 4
                } else {
                    output.append(scalar)
                    index += 1
                }
            // \X\hh : ISO 8859-1.
            } else if startsWith("\\X\\", at: index), let value = hex((index + 3)..<(index + 5)),
                      let character = Unicode.Scalar(value) {
                output.append(character)
                index += 5
            // \S\c : the next character with its high bit set.
            } else if startsWith("\\S\\", at: index), index + 3 < input.count,
                      let character = Unicode.Scalar(input[index + 3].value + 128) {
                output.append(character)
                index += 4
            // \Pn\ : code page selector, nothing to output.
            } else if index + 3 < input.count, input[index + 1] == "P", input[index + 3] == "\\" {
                index += 4
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
            case 48...57: return scalar.value - 48
            case 65...70: return scalar.value - 55
            case 97...102: return scalar.value - 87
            default: return nil
        }
    }

    private static func find(_ marker: String, in input: [Unicode.Scalar], from start: Int) -> Int? {
        let scalars = Array(marker.unicodeScalars)
        guard input.count >= scalars.count, start <= input.count - scalars.count else { return nil }
        for position in start...(input.count - scalars.count) where Array(input[position..<(position + scalars.count)]) == scalars {
            return position
        }
        return nil
    }
}
