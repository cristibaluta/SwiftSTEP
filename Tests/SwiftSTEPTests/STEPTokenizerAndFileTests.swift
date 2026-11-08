import Testing
import Foundation
@testable import SwiftSTEP

// T60 (tokenizer) and T61 (file-level structure). Both work on text, no geometry.

// MARK: - Helpers

private typealias Token = STEPTokenizer.Token

private func tokens(_ text: String) throws -> [Token] {
    var lexer = STEPTokenizer(data: Data(text.utf8))
    var result: [Token] = []
    while true {
        let token = try lexer.next()
        if token == .end { return result }
        result.append(token)
    }
}

private func tokenError(_ text: String) -> STEP.ParseError? {
    do {
        _ = try tokens(text)
        return nil
    } catch let error as STEP.ParseError {
        return error
    } catch {
        return nil
    }
}

private let standardHeader = "FILE_DESCRIPTION(('t'),'2;1');FILE_NAME('t.step','2026-01-01T00:00:00',(''),(''),'','','');"
    + "FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));"

/// A whole Part 21 file around the given DATA records.
private func part21(_ records: String, header: String = standardHeader) -> Data {
    Data("ISO-10303-21;\nHEADER;\n\(header)\nENDSEC;\nDATA;\n\(records)\nENDSEC;\nEND-ISO-10303-21;\n".utf8)
}

private func fileError(_ data: Data, maximumEntityCount: Int = 2_000_000) -> STEP.ParseError? {
    do {
        _ = try STEPFile(data: data, maximumEntityCount: maximumEntityCount)
        return nil
    } catch let error as STEP.ParseError {
        return error
    } catch {
        return nil
    }
}

private func fileError(_ text: String) -> STEP.ParseError? { fileError(Data(text.utf8)) }

// MARK: - T60

@Suite("STEP tokenizer")
struct STEPTokenizerTests {

    @Test func aDoubledQuoteInsideAStringIsOneQuote() throws {
        #expect(try tokens("'it''s'") == [.string("it's")])
        #expect(try tokens("''''") == [.string("'")])
        #expect(try tokens("''") == [.string("")])
        #expect(try tokens("'a' 'b'") == [.string("a"), .string("b")])
    }

    @Test func commentsAreSkippedButNotInsideStrings() throws {
        #expect(try tokens("/* one */ 5 /* two */") == [.integer(5)])
        #expect(try tokens("1/*x*/2") == [.integer(1), .integer(2)])
        #expect(try tokens("/**/ 7") == [.integer(7)])
        #expect(try tokens("'/* not a comment */'") == [.string("/* not a comment */")])
        #expect(try tokens("/* a\nmulti-line\ncomment */ #3") == [.reference(3)])
    }

    @Test func anUnterminatedCommentOrStringMeansTheFileWasCutShort() {
        #expect(tokenError("/* never closed")?.kind == .truncated)
        #expect(tokenError("/*/")?.kind == .truncated, "/*/ opens a comment, it does not close one")
        #expect(tokenError("'never closed")?.kind == .truncated)
        #expect(tokenError("'ends with a doubled quote''")?.kind == .truncated)
        // A lone slash is neither.
        #expect(tokenError("/ 5")?.kind == .malformed)
    }

    @Test func numbersInEveryPart21Spelling() throws {
        #expect(try tokens("1.") == [.real(1)])
        #expect(try tokens(".5E3") == [.real(500)])
        #expect(try tokens("1.0E+00") == [.real(1)])
        #expect(try tokens("-2.5") == [.real(-2.5)])
        #expect(try tokens("+7") == [.integer(7)])
        #expect(try tokens("-12") == [.integer(-12)])
        #expect(try tokens("007") == [.integer(7)])
        #expect(try tokens("1E5") == [.real(100_000)], "an exponent makes it a real")
        #expect(try tokens("1.5e-2") == [.real(0.015)])
        #expect(try tokens("1,2") == [.integer(1), .symbol(44), .integer(2)])
    }

    @Test func malformedNumbersAreErrorsNotZeros() {
        for text in ["-", "+", "-.", ".", "1E", "1.5E+", "1.5E-x"] {
            #expect(tokenError(text) != nil, "\(text) is not a number")
        }
        // Too big for the type, rather than wrapped or clamped.
        #expect(tokenError("99999999999999999999") != nil)
        #expect(tokenError("1E999") != nil)
    }

    @Test func enumerationsAreUppercasedAndMustBeClosed() throws {
        #expect(try tokens(".T.") == [.enumeration("T")])
        #expect(try tokens(".f.") == [.enumeration("F")])
        #expect(try tokens(".CURVE_3D.") == [.enumeration("CURVE_3D")])
        #expect(try tokens(".F.,.T.") == [.enumeration("F"), .symbol(44), .enumeration("T")])
        #expect(tokenError(".ABC") != nil)
        #expect(tokenError(".ABC ") != nil)
    }

    @Test func entityReferences() throws {
        #expect(try tokens("#12") == [.reference(12)])
        #expect(try tokens("#00012") == [.reference(12)])
        for text in ["#", "#0", "#a", "#-1", "# 1", "#99999999999999999999"] {
            #expect(tokenError(text) != nil, "\(text) is not a reference")
        }
    }

    @Test func wordsAreUppercasedAndMayHaveHyphensAndDigits() throws {
        #expect(try tokens("cartesian_point") == [.word("CARTESIAN_POINT")])
        #expect(try tokens("END-ISO-10303-21") == [.word("END-ISO-10303-21")])
        #expect(try tokens("!my_entity") == [.word("!MY_ENTITY")])
        #expect(try tokens("LENGTH_MEASURE(25.4)") == [.word("LENGTH_MEASURE"), .symbol(40), .real(25.4), .symbol(41)])
        // A bang with no name after it is not a keyword.
        #expect(tokenError("! x") != nil)
    }

    @Test func everySymbolAndNoOtherByte() throws {
        #expect(try tokens("(),;=$*") == [40, 41, 44, 59, 61, 36, 42].map { Token.symbol(UInt8($0)) })
        #expect(try tokens(" \t\r\n( \n)") == [.symbol(40), .symbol(41)])
        for text in ["@", "%", "[", "{", "\u{0}", "é"] {
            #expect(tokenError(text) != nil, "unexpected byte in \(text.debugDescription)")
        }
    }

    @Test func aWholeRecordTokenizes() throws {
        #expect(try tokens("#12=CARTESIAN_POINT('',(1.,2.E0,-3.));") == [
            .reference(12), .symbol(61), .word("CARTESIAN_POINT"), .symbol(40), .string(""), .symbol(44),
            .symbol(40), .real(1), .symbol(44), .real(2), .symbol(44), .real(-3), .symbol(41), .symbol(41), .symbol(59)
        ])
    }

    @Test func theEndKeepsComingBackAndAnOverlongTokenIsRefused() throws {
        var lexer = STEPTokenizer(data: Data("5".utf8))
        #expect(try lexer.next() == .integer(5))
        #expect(try lexer.next() == .end)
        #expect(try lexer.next() == .end)

        let huge = "'" + String(repeating: "a", count: 1_100_000) + "'"
        #expect(tokenError(huge)?.kind == .limitExceeded)
    }

    @Test func aTokenizerOverARangeStopsAtItsEnd() throws {
        let data = Data("(1,2) 3".utf8)
        var lexer = STEPTokenizer(data: data, range: 0..<5)
        var seen: [Token] = []
        while true {
            let token = try lexer.next()
            if token == .end { break }
            seen.append(token)
        }
        #expect(seen == [.symbol(40), .integer(1), .symbol(44), .integer(2), .symbol(41)])
    }
}

// MARK: - T61

@Suite("STEP file structure")
struct STEPFileStructureTests {

    @Test func aMinimalFileIsIndexedByEntityNumber() throws {
        let file = try STEPFile(data: part21("#1=A(1);\n#7=B('x');"))
        #expect(file.index.count == 2)
        #expect(file.index[1]?.map(\.type) == ["A"])
        #expect(file.index[7]?.map(\.type) == ["B"])
        #expect(file.hasType(7, "B") && !file.hasType(7, "A") && !file.hasType(9, "A"))
        #expect(file.entities(ofTypes: ["A", "B"]) == [1, 7], "ascending by number")
    }

    @Test func aDataSectionMayBeEmpty() throws {
        let file = try STEPFile(data: part21(""))
        #expect(file.index.isEmpty)
    }

    @Test func aComplexEntityKeepsEveryComponent() throws {
        let file = try STEPFile(data: part21("#1=( FOO(1) BAR('x',(2,3)) );"))
        #expect(file.index[1]?.map(\.type) == ["FOO", "BAR"])
        #expect(file.hasType(1, "BAR"))
        let parts = try file.components(1)
        #expect(parts.map(\.type) == ["FOO", "BAR"])
        #expect(parts[1].parameters == [.string("x"), .list([.integer(2), .integer(3)])])
        #expect(try file.parameters(1, type: "FOO") == [.integer(1)])
    }

    @Test func badComplexEntitiesAreRefused() {
        #expect(fileError(part21("#1=( A() A() );")) != nil, "the same type twice")
        #expect(fileError(part21("#1=();")) != nil, "nothing in it")
        #expect(fileError(part21("#1=( 5 );")) != nil, "not a type")
        #expect(fileError(part21("#1=( A() ;"))  != nil, "never closed")
    }

    @Test func aComplexEntityHasAtMost128Components() {
        func complex(_ count: Int) -> Data {
            part21("#1=(" + (0..<count).map { "C\($0)()" }.joined(separator: " ") + ");")
        }
        #expect(fileError(complex(128)) == nil)
        #expect(fileError(complex(129))?.kind == .limitExceeded)
    }

    @Test func aDuplicateEntityNumberIsRefused() {
        let error = fileError(part21("#1=A();\n#2=B();\n#1=C();"))
        #expect(error?.description.contains("Duplicate entity #1") == true)
    }

    @Test func theEntityCapCountsEveryRecord() {
        let data = part21("#1=A();\n#2=A();\n#3=A();")
        #expect(fileError(data, maximumEntityCount: 3) == nil)
        #expect(fileError(data, maximumEntityCount: 2)?.kind == .limitExceeded)
    }

    @Test func parametersMayNestExactly128Deep() throws {
        func nested(_ depth: Int) -> Data {
            // The record's own parentheses are the first level.
            part21("#1=A(" + String(repeating: "(", count: depth - 1) + String(repeating: ")", count: depth - 1) + ");")
        }
        let file = try STEPFile(data: nested(128))
        _ = try file.components(1)
        #expect(fileError(nested(129))?.kind == .limitExceeded)
        #expect(fileError(nested(5000))?.kind == .limitExceeded)
    }

    @Test func anEmptyOrForeignFileIsNotSTEP() {
        #expect(fileError(Data())?.kind == .notSTEP)
        #expect(fileError("   \n\t ")?.kind == .notSTEP)
        #expect(fileError("hello")?.kind == .notSTEP)
        #expect(fileError("ISO-10303-22;")?.kind == .notSTEP)
        #expect(fileError("<?xml version=\"1.0\"?>")?.kind == .notSTEP)
        #expect(fileError(Data([0x00, 0xFF, 0xFE, 0x41]))?.kind == .notSTEP)
    }

    @Test func aFileThatStopsEarlyIsTruncated() {
        #expect(fileError("ISO-10303-21")?.kind == .truncated)
        #expect(fileError("ISO-10303-21;")?.kind == .truncated)
        #expect(fileError("ISO-10303-21;\nHEADER;\nFILE_NAME('a'")?.kind == .truncated)
        #expect(fileError("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n#1=A(1);\n#2=B(")?.kind == .truncated)
        #expect(fileError("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n#1=A(1);\n")?.kind == .truncated, "no ENDSEC")
    }

    @Test func theClosingLinesAreRequired() {
        let body = "ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n#1=A(1);\nENDSEC;\n"
        #expect(fileError(body + "END-ISO-10303-21;") == nil)
        #expect(fileError(body)?.kind == .truncated, "missing END-ISO-10303-21")
        #expect(fileError(body + "END-ISO-10303-21")?.kind == .truncated, "missing its semicolon")
        #expect(fileError(body + "END-ISO-10303-21; junk")?.kind == .malformed, "text after the end")
        #expect(fileError(body + "END-ISO-10303-22;")?.kind == .malformed)
    }

    @Test func everyShorterPrefixOfAValidFileIsRefused() {
        let data = part21("#1=A(1);\n#2=B('x',(2,3));")
        #expect(fileError(data) == nil)
        let bytes = [UInt8](data)
        // The last byte is the newline after END-ISO-10303-21;, which is only whitespace.
        for length in 0..<(bytes.count - 1) {
            #expect(fileError(Data(bytes[0..<length])) != nil, "a \(length)-byte prefix cannot be a whole file")
        }
        #expect(fileError(Data(bytes[0..<(bytes.count - 1)])) == nil)
    }

    @Test func malformedRecordsAreRefusedWithoutBeingTakenForTruncation() {
        let wrapper = { (record: String) in "ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n\(record)\nENDSEC;\nEND-ISO-10303-21;\n" }
        #expect(fileError(wrapper("#1 A();"))?.kind == .malformed, "no equals sign")
        #expect(fileError(wrapper("#1=A()\n#2=B();"))?.kind == .malformed, "no semicolon")
        #expect(fileError(wrapper("#1=A((1,2);"))?.kind == .malformed, "an unclosed list")
        #expect(fileError(wrapper("#1=;"))?.kind == .malformed, "no type")
        #expect(fileError(wrapper("#0=A();"))?.kind == .malformed, "entity zero")
        #expect(fileError(wrapper("5;"))?.kind == .malformed, "not a record")
        #expect(fileError("ISO-10303-21;\nHEADER;\n5;\nENDSEC;\nDATA;\nENDSEC;\nEND-ISO-10303-21;")?.kind == .malformed)
    }

    @Test func parametersAreCheckedWhenTheyAreFirstRead() throws {
        // Indexing only matches the brackets; the grammar inside is read on demand.
        let file = try STEPFile(data: part21("#1=A(1 2);\n#2=A(,);\n#3=A(1,);\n#4=A();\n#5=A($,*,.T.,(),#9,LENGTH_MEASURE(25.4));"))
        #expect(throws: STEP.ParseError.self) { try file.components(1) }
        #expect(throws: STEP.ParseError.self) { try file.components(2) }
        #expect(throws: STEP.ParseError.self) { try file.components(3) }
        #expect(try file.parameters(4, type: "A") == [])
        #expect(try file.parameters(5, type: "A") == [
            .unset, .derived, .enumeration("T"), .list([]), .reference(9), .typed("LENGTH_MEASURE", [.real(25.4)])
        ])
    }

    @Test func lookingUpWhatIsNotThereIsAnErrorNotACrash() throws {
        let file = try STEPFile(data: part21("#1=A(1);"))
        #expect(throws: STEP.ParseError.self) { try file.components(99) }
        #expect(throws: STEP.ParseError.self) { try file.parameters(1, type: "B") }
        #expect(throws: STEP.ParseError.self) { try file.parameters(99, type: "A") }
        let parameters = try file.parameters(1, type: "A")
        #expect(throws: STEP.ParseError.self) { try parameters.argument(5) }
        #expect(throws: STEP.ParseError.self) { try parameters.reference(at: 0) }
        #expect(throws: STEP.ParseError.self) { try parameters.references(at: 0) }
    }

    @Test func aStringWithASemicolonAndABracketDoesNotConfuseTheIndexer() throws {
        let file = try STEPFile(data: part21("#1=A('a;b)(c','it''s');\n#2=B();"))
        #expect(file.index.count == 2)
        #expect(try file.parameters(1, type: "A") == [.string("a;b)(c"), .string("it's")])
    }

    @Test func aCommentBetweenRecordsIsIgnored() throws {
        let file = try STEPFile(data: part21("/* first */ #1=A(); /* between */ #2=B(); /* last */"))
        #expect(file.index.count == 2)
    }

    @Test func theHeaderIsReadEvenWhenTheDataIsEmpty() throws {
        let file = try STEPFile(data: part21(""))
        let header = file.header()
        #expect(header.name == "t.step")
        #expect(header.schemas == ["AUTOMOTIVE_DESIGN"])
    }
}
