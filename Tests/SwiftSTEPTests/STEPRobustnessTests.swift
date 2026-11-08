import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T64 (cancellation) and T66 (fuzzing). Neither checks what a model contains, only how the
// importer behaves when it is stopped, or fed damaged input.

// MARK: - Fixtures

private func boxFile() -> Data {
    let b = StepBuilder()
    return b.data(bodies: [boxBody(b)])
}

/// A valid file made big with unused records, so that parsing it takes a while.
private func paddedFile(extraEntities: Int) -> Data {
    let text = String(decoding: boxFile(), as: UTF8.self)
    var filler = ""
    filler.reserveCapacity(extraEntities * 40)
    for i in 0..<extraEntities {
        filler += "#\(100_000 + i)=CARTESIAN_POINT('',(1.E0,2.E0,3.E0));\n"
    }
    return Data(text.replacingOccurrences(of: "\nENDSEC;\nEND-ISO", with: "\n" + filler + "ENDSEC;\nEND-ISO").utf8)
}

private func temporaryFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftstep-\(UUID().uuidString).step")
    try data.write(to: url)
    return url
}

/// Runs `work` in a task that is already cancelled when `work` starts, so the outcome does not
/// depend on how fast the importer is.
private func runCancelled<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
    let task = Task<T, Error> {
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        return try await work()
    }
    task.cancel()
    return await task.result
}

private func expectCancelled<T>(_ result: Result<T, Error>, _ what: String = "",
                                sourceLocation: SourceLocation = #_sourceLocation) {
    switch result {
        case .success:
            Issue.record("\(what) finished although it was cancelled first", sourceLocation: sourceLocation)
        case .failure(let error):
            #expect(error is CancellationError, "\(what) threw \(error), not CancellationError", sourceLocation: sourceLocation)
    }
}

// MARK: - T64

@Suite("STEP cancellation")
struct STEPCancellationTests {

    @Test func aLoadThatIsCancelledBeforeItStartsThrowsCancellationError() async throws {
        let url = try temporaryFile(boxFile())
        defer { try? FileManager.default.removeItem(at: url) }

        expectCancelled(await runCancelled { try await STEP.load(contentsOf: url) }, "STEP.load")
        expectCancelled(await runCancelled { try await STEP.loadGeometry(contentsOf: url) }, "STEP.loadGeometry")
        expectCancelled(await runCancelled { try await STEP.loadTopology(contentsOf: url) }, "STEP.loadTopology")
    }

    @Test func theSynchronousEntryPointsStopInsideACancelledTask() async throws {
        let data = boxFile()
        expectCancelled(await runCancelled { try STEP.read(data: data) }, "STEP.read")
        expectCancelled(await runCancelled { try STEP.readGeometry(data: data) }, "STEP.readGeometry")
        expectCancelled(await runCancelled { try STEP.readTopology(data: data) }, "STEP.readTopology")
    }

    @Test func aBigFileIsCancelledAtOnce() async throws {
        let data = paddedFile(extraEntities: 50_000)
        expectCancelled(await runCancelled { try STEP.read(data: data) }, "a big STEP.read")
    }

    @Test func theSameFileLoadsNormallyWhenNobodyCancels() async throws {
        let url = try temporaryFile(boxFile())
        defer { try? FileManager.default.removeItem(at: url) }
        let model = try await STEP.load(contentsOf: url)
        #expect(model.edges.count == 12)
        let geometry = try await STEP.loadGeometry(contentsOf: url)
        #expect(geometry.surfaces.triangleCount == 12)
        let topology = try await STEP.loadTopology(contentsOf: url)
        #expect(topology.faces.count == 6)
    }

    @Test func aCancelledLoadLeavesNothingBehindThatSpoilsTheNextOne() async throws {
        let url = try temporaryFile(boxFile())
        defer { try? FileManager.default.removeItem(at: url) }
        expectCancelled(await runCancelled { try await STEP.load(contentsOf: url) })
        #expect(try await STEP.load(contentsOf: url).edges.count == 12)
    }

    @Test func cancellingInTheMiddleOfAParseEndsInCancellationOrAFinishedModelNeverAParseError() async throws {
        // Timing decides which of the two happens, so both are accepted; what must not happen
        // is some other error, a hang, or a half-built model.
        let url = try temporaryFile(paddedFile(extraEntities: 300_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await STEP.loadGeometry(contentsOf: url) }
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        switch await task.result {
            case .success(let geometry):
                #expect(geometry.edges.edges.count == 12)
            case .failure(let error):
                #expect(error is CancellationError, "cancelled mid-parse, but \(error) came out")
        }
    }

    @Test func manyCancelledLoadsInARowAreAllCancelled() async throws {
        let data = boxFile()
        for _ in 0..<20 {
            expectCancelled(await runCancelled { try STEP.readGeometry(data: data) })
        }
    }
}

// MARK: - T66

/// SplitMix64: a small, seedable generator, so a failing run can be repeated exactly.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A file with every kind of geometry the importer reads: planes, a cylinder, a sphere cap,
/// and edges that are lines, circles, an ellipse, polynomial and rational splines and a polyline.
private func fuzzFixture() -> Data {
    let b = StepBuilder()
    let box = boxBody(b)

    // A closed cylinder.
    let bottomVertex = b.vertex(SIMD3(45, 0, 0))
    let topVertex = b.vertex(SIMD3(45, 0, 10))
    let bottom = b.edge(start: bottomVertex, end: bottomVertex,
                        curve: b.circle(placement: b.placement(origin: SIMD3(40, 0, 0)), radius: 5))
    let top = b.edge(start: topVertex, end: topVertex,
                     curve: b.circle(placement: b.placement(origin: SIMD3(40, 0, 10)), radius: 5))
    let seam = b.edge(start: bottomVertex, end: topVertex, curve: b.line(from: SIMD3(45, 0, 0), direction: SIMD3(0, 0, 1)))
    let side = b.add("CYLINDRICAL_SURFACE('',#\(b.placement(origin: SIMD3(40, 0, 0))),5.0E+00)")
    let floor = b.add("PLANE('',#\(b.placement(origin: SIMD3(40, 0, 0), axis: SIMD3(0, 0, -1))))")
    let cylinder = StepBuilder.BodySpec(faces: [
        StepBuilder.FaceSpec(surface: floor, loops: [[StepBuilder.rev(bottom)]]),
        StepBuilder.FaceSpec(surface: side, loops: [[StepBuilder.fwd(bottom), StepBuilder.fwd(seam),
                                                     StepBuilder.rev(top), StepBuilder.rev(seam)]])
    ])

    // A sphere cap written as one circle.
    let equatorVertex = b.vertex(SIMD3(80, 0, 0))
    let equator = b.edge(start: equatorVertex, end: equatorVertex,
                         curve: b.circle(placement: b.placement(origin: SIMD3(75, 0, 0)), radius: 5))
    let sphere = b.add("SPHERICAL_SURFACE('',#\(b.placement(origin: SIMD3(75, 0, 0))),5.0E+00)")
    let dome = StepBuilder.BodySpec(faces: [StepBuilder.FaceSpec(surface: sphere, loops: [[StepBuilder.fwd(equator)]])])

    // One face per remaining curve type.
    func single(_ curve: Int, from: SIMD3<Double>, to: SIMD3<Double>) -> StepBuilder.FaceSpec {
        let edge = b.edge(start: b.vertex(from), end: b.vertex(to), curve: curve)
        return StepBuilder.FaceSpec(loops: [[StepBuilder.fwd(edge)]])
    }
    let ellipse = b.ellipse(placement: b.placement(origin: SIMD3(0, 50, 0)), semiAxis1: 8, semiAxis2: 4)
    let spline = b.bspline(degree: 3, points: [SIMD3(0, 70, 0), SIMD3(3, 75, 0), SIMD3(6, 65, 0), SIMD3(9, 70, 0)],
                           multiplicities: [4, 4], knots: [0, 1])
    let rational = b.bspline(degree: 2, points: [SIMD3(20, 60, 0), SIMD3(25, 60, 0), SIMD3(25, 65, 0)],
                             weights: [1, 0.5.squareRoot(), 1], multiplicities: [3, 3], knots: [0, 1])
    let polyline = b.polyline([SIMD3(30, 60, 0), SIMD3(35, 60, 0), SIMD3(35, 65, 0)])
    let curves = StepBuilder.BodySpec(faces: [
        single(ellipse, from: SIMD3(8, 50, 0), to: SIMD3(0, 54, 0)),
        single(spline, from: SIMD3(0, 70, 0), to: SIMD3(9, 70, 0)),
        single(rational, from: SIMD3(20, 60, 0), to: SIMD3(25, 65, 0)),
        single(polyline, from: SIMD3(30, 60, 0), to: SIMD3(35, 65, 0))
    ])
    return b.data(bodies: [box, cylinder, dome, curves])
}

private let extremeNumbers = ["0", "1", "-1", "2", "255", "2147483647", "4294967296", "99999999999999999999",
                              "1.E308", "-1.E308", "1.E-308", "0.", "1.E10", "-0.", ".5"]
private let alphabet = Array("()',;=#$*.-+E/\\ \n0123456789ABCDEFXTSP_".utf8)

/// A few random edits: flip a bit, replace, delete, insert, cut short, repeat a chunk, or swap a
/// whole number for an extreme one (huge counts, zeros, negatives and overflow are where code
/// that trusts its input breaks).
private func mutate(_ original: Data, using rng: inout SplitMix64) -> Data {
    var bytes = [UInt8](original)
    for _ in 0..<Int.random(in: 1...6, using: &rng) {
        guard !bytes.isEmpty else { break }
        let at = Int.random(in: 0..<bytes.count, using: &rng)
        switch Int.random(in: 0..<8, using: &rng) {
            case 0:
                bytes[at] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &rng)
            case 1:
                bytes[at] = UInt8.random(in: 0...255, using: &rng)
            case 2:
                bytes[at] = alphabet.randomElement(using: &rng)!
            case 3:
                bytes.remove(at: at)
            case 4:
                let length = min(Int.random(in: 1...60, using: &rng), bytes.count - at)
                bytes.removeSubrange(at..<(at + length))
            case 5:
                bytes.insert(alphabet.randomElement(using: &rng)!, at: at)
            case 6:
                if Int.random(in: 0..<6, using: &rng) == 0 {
                    bytes.removeSubrange(at...)
                } else {
                    let length = min(Int.random(in: 1...200, using: &rng), bytes.count - at)
                    bytes.insert(contentsOf: Array(bytes[at..<(at + length)]), at: at)
                }
            default:
                // The nearest run of digits at or after `at`.
                guard var start = bytes[at...].firstIndex(where: { $0 >= 48 && $0 <= 57 }) else { break }
                var end = start
                while end < bytes.count, (bytes[end] >= 48 && bytes[end] <= 57) || bytes[end] == 46 { end += 1 }
                while start > 0, (bytes[start - 1] >= 48 && bytes[start - 1] <= 57) || bytes[start - 1] == 46 { start -= 1 }
                bytes.replaceSubrange(start..<end, with: Array(extremeNumbers.randomElement(using: &rng)!.utf8))
        }
    }
    return Data(bytes)
}

private var iterationScale: Int {
    Int(ProcessInfo.processInfo.environment["STEP_FUZZ_ITERATIONS"] ?? "") ?? 1
}

/// The last input handed to the importer. A trap cannot be caught, so when a run dies this file
/// is the input that killed it.
private let lastInput = FileManager.default.temporaryDirectory.appendingPathComponent("swiftstep-fuzz-last-input.step")

/// Every mutation of the fixture must end in a model or a `STEP.ParseError`, in a sensible time.
private func fuzz(_ fixture: Data, seed: UInt64, iterations: Int, options: STEP.Options,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    var rng = SplitMix64(seed: seed)
    for i in 0..<iterations {
        let mutated = mutate(fixture, using: &rng)
        try? mutated.write(to: lastInput)
        do {
            switch i % 3 {
                case 0: _ = try STEP.readGeometry(data: mutated, options: options)
                case 1: _ = try STEP.readTopology(data: mutated, options: options)
                default: _ = try STEP.read(data: mutated, options: options)
            }
        } catch is STEP.ParseError {
            // The expected way to refuse a damaged file.
        } catch {
            Issue.record("seed \(seed), iteration \(i): \(error) is not a STEP.ParseError (input saved at \(lastInput.path))",
                         sourceLocation: sourceLocation)
            try? mutated.write(to: lastInput.deletingLastPathComponent()
                .appendingPathComponent("swiftstep-fuzz-failure-\(seed)-\(i).step"))
        }
    }
}

@Suite("STEP fuzzing")
struct STEPFuzzTests {
    /// Small caps keep a mutated file that asks for the moon from taking the test machine with it.
    private let options = STEP.Options(maximumEntityCount: 50_000, maximumTriangleCount: 100_000)

    @Test func theFixtureItselfImportsCleanly() throws {
        let geometry = try STEP.readGeometry(data: fuzzFixture(), options: options)
        #expect(geometry.edges.bodies.count == 4)
        #expect(geometry.edges.edges.count >= 16, "box 12, cylinder 3, dome 1, and the four curves")
        #expect(geometry.surfaces.triangleCount > 12)
        #expect(geometry.edges.edges.map(\.kind).contains(.bspline))
        #expect(geometry.edges.edges.map(\.kind).contains(.polyline))
        #expect(geometry.edges.edges.map(\.kind).contains(.ellipticalArc))
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func mutatedFilesAreRefusedOrImportedNeverTrapped(seed: UInt64) {
        fuzz(fuzzFixture(), seed: seed, iterations: 300 * iterationScale, options: options)
    }

    @Test func aBoxWithDamagedBytesIsRefusedOrImported() {
        fuzz(boxFile(), seed: 99, iterations: 500 * iterationScale, options: options)
    }

    @Test func everyShorterPrefixOfTheFixtureIsHandled() {
        let data = fuzzFixture()
        // About 150 cut points, spread over the whole file.
        let step = max(1, data.count / 150)
        for length in stride(from: 0, to: data.count, by: step) {
            let prefix = data.prefix(length)
            try? prefix.write(to: lastInput)
            do {
                _ = try STEP.readGeometry(data: prefix, options: options)
            } catch is STEP.ParseError {
            } catch {
                Issue.record("a \(length)-byte prefix threw \(error), not a STEP.ParseError")
            }
        }
    }

    @Test func randomBytesNeverHangOrTrapTheIndexerAndTokenizer() {
        var rng = SplitMix64(seed: 2026)
        for i in 0..<(5_000 * iterationScale) {
            let length = Int.random(in: 0...300, using: &rng)
            var bytes: [UInt8] = []
            for _ in 0..<length {
                // Mostly the characters Part 21 uses, sometimes anything.
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    bytes.append(UInt8.random(in: 0...255, using: &rng))
                } else {
                    bytes.append(alphabet.randomElement(using: &rng)!)
                }
            }
            // As a whole file, and as a file that starts correctly and then goes wrong.
            let junk = Data(bytes)
            let framed = Data("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n".utf8) + junk
            for data in [junk, framed] {
                do {
                    _ = try STEPFile(data: data, maximumEntityCount: 1_000)
                } catch is STEP.ParseError {
                } catch {
                    Issue.record("iteration \(i): \(error) is not a STEP.ParseError")
                }
                var lexer = STEPTokenizer(data: data)
                var tokens = 0
                while tokens <= data.count + 1 {
                    guard let token = try? lexer.next(), token != .end else { break }
                    tokens += 1
                }
                #expect(tokens <= data.count, "the tokenizer must consume input as it goes (iteration \(i))")
            }
        }
    }

    @Test func theMutatorIsDeterministicAndActuallyChangesTheFile() {
        let fixture = boxFile()
        var first = SplitMix64(seed: 7)
        var second = SplitMix64(seed: 7)
        let a = mutate(fixture, using: &first)
        let b = mutate(fixture, using: &second)
        #expect(a == b, "the same seed must give the same damage, or a failure cannot be repeated")
        var changed = 0
        var rng = SplitMix64(seed: 8)
        for _ in 0..<50 {
            if mutate(fixture, using: &rng) != fixture { changed += 1 }
        }
        #expect(changed >= 45)
    }
}
