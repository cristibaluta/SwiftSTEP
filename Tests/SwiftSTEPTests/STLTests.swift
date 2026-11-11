import Testing
import Foundation
import simd
@testable import SwiftSTEP

// Files are built in memory; no fixtures. The cube is [0,1]^3 with outward counter-clockwise winding.

private typealias Triangle = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

private func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) -> [Triangle] {
    [(a, b, c), (a, c, d)]
}

private let cubeTriangles: [Triangle] = {
    func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }
    return quad(p(0, 0, 0), p(0, 1, 0), p(1, 1, 0), p(1, 0, 0))      // -Z
        + quad(p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1))       // +Z
        + quad(p(0, 0, 0), p(1, 0, 0), p(1, 0, 1), p(0, 0, 1))       // -Y
        + quad(p(0, 1, 0), p(0, 1, 1), p(1, 1, 1), p(1, 1, 0))       // +Y
        + quad(p(0, 0, 0), p(0, 0, 1), p(0, 1, 1), p(0, 1, 0))       // -X
        + quad(p(1, 0, 0), p(1, 1, 0), p(1, 1, 1), p(1, 0, 1))       // +X
}()

private func binarySTL(_ triangles: [Triangle], header: String = "", declaredCount: Int? = nil) -> Data {
    var data = Data(header.utf8)
    data.append(Data(count: 80 - data.count))
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    append((UInt32(declaredCount ?? triangles.count)).littleEndian)
    for (a, b, c) in triangles {
        data.append(Data(count: 12))                                  // stored normal, ignored
        for point in [a, b, c] {
            for value in [point.x, point.y, point.z] { append(value.bitPattern.littleEndian) }
        }
        append(UInt16(0).littleEndian)
    }
    return data
}

private func asciiSTL(_ triangles: [Triangle], name: String = "cube", lineEnding: String = "\n") -> Data {
    var lines = ["solid \(name)"]
    for (a, b, c) in triangles {
        lines.append("facet normal 0 0 0")
        lines.append("outer loop")
        for point in [a, b, c] {
            lines.append("vertex " + String(format: "%.6e %.6e %.6e", point.x, point.y, point.z))
        }
        lines.append("endloop")
        lines.append("endfacet")
    }
    lines.append("endsolid \(name)")
    return Data((lines.joined(separator: lineEnding) + lineEnding).utf8)
}

private func parseError(_ work: () throws -> Void) -> STEP.ParseError? {
    do { try work() } catch let error as STEP.ParseError { return error } catch {}
    return nil
}

@Suite struct STLTests {

    @Test func binaryCube() throws {
        let geometry = try STL.readGeometry(data: binarySTL(cubeTriangles))
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(mesh.triangleCount == 12)
        #expect(mesh.faces.isEmpty)
        #expect(geometry.edges.edges.isEmpty)
        let bounds = try #require(geometry.edges.bounds)
        #expect(bounds.min == SIMD3<Double>(0, 0, 0))
        #expect(bounds.max == SIMD3<Double>(1, 1, 1))
        #expect(geometry.edges.bodies.first?.unitsAssumed == true)
        #expect(geometry.edges.diagnostics.contains { $0.code == "stl-no-edges" })

        // Normals point away from the cube centre.
        let origin = SIMD3<Float>(geometry.surfaces.origin)
        let centre = SIMD3<Float>(repeating: 0.5)
        for t in 0..<mesh.triangleCount {
            let i = Int(mesh.indices[3 * t])
            let corner = mesh.positions[i] + origin
            #expect(simd_dot(mesh.normals[i], corner - centre) > 0)
        }
    }

    @Test func asciiMatchesBinary() throws {
        let binary = try STL.readGeometry(data: binarySTL(cubeTriangles))
        let ascii = try STL.readGeometry(data: asciiSTL(cubeTriangles, lineEnding: "\r\n"))
        #expect(ascii.surfaces.bodies.first?.triangleCount == 12)
        #expect(ascii.edges.bounds?.min == binary.edges.bounds?.min)
        #expect(ascii.edges.bounds?.max == binary.edges.bounds?.max)
        #expect(ascii.edges.bodies.first?.name == "cube")
        #expect(ascii.surfaces.bodies.first?.normals == binary.surfaces.bodies.first?.normals)
    }

    @Test func binaryStartingWithSolidIsStillBinary() throws {
        let geometry = try STL.readGeometry(data: binarySTL(cubeTriangles, header: "solid exported by something"))
        #expect(geometry.surfaces.bodies.first?.triangleCount == 12)
    }

    @Test func truncatedBinaryThrows() {
        let data = binarySTL(cubeTriangles, declaredCount: 20)
        let error = parseError { _ = try STL.readGeometry(data: data) }
        #expect(error?.kind == .truncated)
    }

    @Test func nonSTLThrowsMalformed() {
        let error = parseError { _ = try STL.readGeometry(data: Data("ISO-10303-21; HEADER; ENDSEC;".utf8)) }
        #expect(error?.kind == .malformed)
    }

    @Test func vertexCountNotMultipleOfThree() {
        let text = "solid x\nvertex 0 0 0\nvertex 1 0 0\nendsolid x\n"
        let error = parseError { _ = try STL.readGeometry(data: Data(text.utf8)) }
        #expect(error?.kind == .malformed)
    }

    @Test func zeroAreaTriangleIsDropped() throws {
        let flat: Triangle = (SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(2, 2, 2))
        let geometry = try STL.readGeometry(data: binarySTL(cubeTriangles + [flat]))
        #expect(geometry.surfaces.bodies.first?.triangleCount == 12)
        #expect(geometry.edges.diagnostics.contains { $0.code == "degenerate-triangles" })
    }

    @Test func nanCoordinateThrows() {
        let bad: Triangle = (SIMD3(0, 0, 0), SIMD3(.nan, 0, 0), SIMD3(0, 1, 0))
        #expect(throws: STEP.ParseError.self) { _ = try STL.readGeometry(data: binarySTL([bad])) }
        let text = "solid x\nvertex 0 0 0\nvertex nan 0 0\nvertex 0 1 0\nendsolid x\n"
        #expect(throws: STEP.ParseError.self) { _ = try STL.readGeometry(data: Data(text.utf8)) }
    }

    @Test func triangleLimit() {
        var options = STEP.Options()
        options.maximumTriangleCount = 5
        let error = parseError { _ = try STL.readGeometry(data: binarySTL(cubeTriangles), options: options) }
        #expect(error?.kind == .limitExceeded)
        let ascii = parseError { _ = try STL.readGeometry(data: asciiSTL(cubeTriangles), options: options) }
        #expect(ascii?.kind == .limitExceeded)
    }

    @Test func unitScale() throws {
        var options = STEP.Options()
        options.assumedUnitScaleToMM = 25.4
        let geometry = try STL.readGeometry(data: binarySTL(cubeTriangles), options: options)
        let size = try #require(geometry.edges.bounds).size
        #expect(abs(size.x - 25.4) < 1e-9 && abs(size.y - 25.4) < 1e-9 && abs(size.z - 25.4) < 1e-9)
        #expect(geometry.edges.bodies.first?.unitScaleToMM == 25.4)
    }

    @Test func cancelledTaskThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cube-\(UUID().uuidString).stl")
        try binarySTL(cubeTriangles).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await STL.loadGeometry(contentsOf: url)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func loadAssemblyWrapsOneBody() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cube-\(UUID().uuidString).stl")
        try binarySTL(cubeTriangles).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let assembly = try await STL.loadAssembly(contentsOf: url)
        #expect(assembly.bodies.count == 1)
        #expect(assembly.triangleCount == 12)
        #expect(assembly.edgeCount == 0)
    }
}
