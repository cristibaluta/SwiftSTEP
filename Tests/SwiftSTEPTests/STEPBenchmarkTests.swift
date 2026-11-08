import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T50: timings, not assertions. Off unless STEP_BENCHMARK is set, because they take a while and
// only mean something in an optimised build:
//
//   STEP_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --filter STEPBenchmark
//
// (`-enable-testing` lets the release build keep `@testable import` working.) Set
// STEP_BENCHMARK_MB to change the size of the synthetic file, 20 by default. Debug builds are
// often 10 to 50 times slower than release for this kind of code, so a slow draw in an app run
// from Xcode in Debug says little; run the sample files below in release first.

private let benchmarkEnabled = ProcessInfo.processInfo.environment["STEP_BENCHMARK"] != nil

private func seconds(_ block: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    try block()
    let elapsed = clock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

/// The fastest of `runs`, which is the least disturbed by whatever else the machine is doing.
private func best(of runs: Int, _ block: () throws -> Void) rethrows -> Double {
    var fastest = Double.infinity
    for _ in 0..<runs { fastest = min(fastest, try seconds(block)) }
    return fastest
}

/// Peak resident memory of this process so far, in MB.
private func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if os(macOS) || os(iOS)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes
    #else
    return Double(usage.ru_maxrss) / 1024 // kilobytes
    #endif
}

private func format(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }

/// Many boxes, so many planes, lines and vertices, sized to about `megabytes`.
private func syntheticFile(megabytes: Int) -> Data {
    func make(bodies: Int) -> Data {
        let b = StepBuilder()
        let specs = (0..<bodies).map { i in
            boxBody(b, origin: SIMD3(Double(i % 100) * 20, Double((i / 100) % 100) * 20, Double(i / 10_000) * 20),
                    size: SIMD3(10, 10, 10))
        }
        return b.data(bodies: specs)
    }
    let sample = make(bodies: 200)
    let perBody = max(1, sample.count / 200)
    return make(bodies: max(200, megabytes * 1_048_576 / perBody))
}

private var samplesFolder: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SwiftSTEPDemo/Samples")
}

@Suite("STEP benchmark", .enabled(if: benchmarkEnabled))
struct STEPBenchmarkTests {

    /// A big file of simple geometry: what indexing and reading cost per megabyte.
    @Test func aLargeSyntheticFile() throws {
        let megabytes = Int(ProcessInfo.processInfo.environment["STEP_BENCHMARK_MB"] ?? "") ?? 20
        let data = syntheticFile(megabytes: megabytes)
        let size = Double(data.count) / 1_048_576
        print("""

        == synthetic file ==
        size                 \(format(size)) MB
        memory before        \(format(peakMemoryMB(), 0)) MB peak
        """)

        var entities = 0
        let index = best(of: 3) { entities = (try? STEPFile(data: data))?.index.count ?? 0 }
        print("STEPFile.init        \(format(index, 3)) s   \(format(size / index)) MB/s   \(entities) entities")

        var edges = 0
        let read = best(of: 3) { edges = (try? STEP.read(data: data))?.edges.count ?? 0 }
        print("STEP.read            \(format(read, 3)) s   \(format(size / read)) MB/s   \(edges) edges")

        var triangles = 0
        let geometry = best(of: 1) { triangles = (try? STEP.readGeometry(data: data))?.surfaces.triangleCount ?? 0 }
        print("STEP.readGeometry    \(format(geometry, 3)) s   \(triangles) triangles")
        print("memory after         \(format(peakMemoryMB(), 0)) MB peak\n")
    }

    /// Every sample file, edges only and with surfaces, so the cost of the geometry shows.
    @Test func theSampleFiles() throws {
        let files = try FileManager.default.contentsOfDirectory(at: samplesFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "step" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty, "no sample files at \(samplesFolder.path)")

        print("\n== sample files (best of 3) ==")
        print("file".padding(toLength: 28, withPad: " ", startingAt: 0) + "KB      edges ms   with surfaces ms   triangles  failed faces")
        for url in files {
            let data = try Data(contentsOf: url)
            var edgeCount = 0
            let edgesOnly = best(of: 3) { edgeCount = (try? STEP.read(data: data))?.edges.count ?? 0 }
            var triangles = 0
            var failed = 0
            let everything = best(of: 3) {
                if let geometry = try? STEP.readGeometry(data: data) {
                    triangles = geometry.surfaces.triangleCount
                    failed = geometry.surfaces.failedFaceCount
                }
            }
            print(url.lastPathComponent.padding(toLength: 28, withPad: " ", startingAt: 0)
                  + String(format: "%-7.0f %-10.1f %-18.1f %-10ld %ld", Double(data.count) / 1024, edgesOnly * 1000,
                           everything * 1000, triangles, failed)
                  + "   (\(edgeCount) edges)")
        }
        print("")
    }

    /// The cost of one operation on a freeform surface, which is what a face of a loft is made of.
    @Test func freeformSurfacePrimitives() throws {
        let url = samplesFolder.appendingPathComponent("loft_transition.step")
        let geometry = try STEP.readGeometry(data: try Data(contentsOf: url))
        var spline: STEP.BSplineSurface?
        for body in geometry.surfaces.bodies {
            for face in body.faces {
                if case .bspline(let surface) = face.surface, spline == nil { spline = surface }
            }
        }
        let surface = try #require(spline, "loft_transition.step has no B-spline face that tessellated")
        let uLow = surface.uDomain.lowerBound, uHigh = surface.uDomain.upperBound
        let vLow = surface.vDomain.lowerBound, vHigh = surface.vDomain.upperBound
        let parameters = (0..<1_000).map { i -> (Double, Double) in
            let a = Double((i * 7919) % 1_000) / 1_000
            let b = Double((i * 104_729) % 1_000) / 1_000
            return (uLow + (uHigh - uLow) * a, vLow + (vHigh - vLow) * b)
        }
        var sink = 0.0

        print("\n== one freeform surface of loft_transition.step: degree \(surface.uDegree) x \(surface.vDegree) ==")
        let points = best(of: 3) {
            for _ in 0..<100 { for (u, v) in parameters { sink += surface.point(u: u, v: v).x } }
        }
        print("point                \(format(points / 100_000 * 1e6, 3)) us each")

        let normals = best(of: 3) {
            for _ in 0..<50 { for (u, v) in parameters { sink += surface.normal(u: u, v: v).x } }
        }
        print("normal               \(format(normals / 50_000 * 1e6, 3)) us each")

        let targets = parameters.prefix(300).map { surface.point(u: $0.0, v: $0.1) }
        let projections = best(of: 3) {
            for target in targets { sink += surface.parameters(of: target).u }
        }
        print("projection (cold)    \(format(projections / Double(targets.count) * 1e6, 1)) us each")

        let chained = best(of: 3) {
            var hint: (u: Double, v: Double)?
            for target in targets {
                let found = surface.parameters(of: target, near: hint)
                hint = (found.u, found.v)
                sink += found.u
            }
        }
        print("projection (hinted)  \(format(chained / Double(targets.count) * 1e6, 1)) us each")

        var divisions = (u: 0, v: 0)
        let counted = best(of: 3) { divisions = surface.divisions(tolerance: 0.01) }
        print("divisions            \(format(counted * 1000, 2)) ms   (\(divisions.u) x \(divisions.v))")
        print("(checksum \(sink))\n")
    }

    /// A dense spline curve: what sampling an edge costs.
    @Test func splineCurveSampling() throws {
        let degree = 9
        let knots = (0..<4).map(Double.init)
        let count = degree + 1 + 3
        let controls = (0..<count).map { i in SIMD3(Double(i) * 3, 5 * sin(Double(i)), Double(i % 3)) }
        let curve = try STEPBSpline(degree: degree, controlPoints: controls, weights: nil,
                                    multiplicities: [degree + 1, 1, 1, degree + 1], knotValues: knots)
        var sink = 0.0
        let evaluation = best(of: 3) {
            for i in 0..<200_000 { sink += curve.point(at: 3 * Double(i) / 200_000).x }
        }
        print("\n== degree 9 spline curve ==")
        print("point                \(format(evaluation / 200_000 * 1e6, 3)) us each")
        let sampling = best(of: 3) { sink += Double(curve.sample(from: 0, to: 3, tolerance: 0.001, pointBudget: 100_000).points.count) }
        print("sample (tol 0.001)   \(format(sampling * 1000, 2)) ms   (checksum \(sink))\n")
    }
}
