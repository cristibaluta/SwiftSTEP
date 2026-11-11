import Foundation
import simd

/// Reads `.stl` (binary or ASCII, optionally gzipped) into the same `STEP.Geometry` / `STEP.Assembly`
/// types the STEP reader produces, so a renderer needs no STL-specific code.
///
/// Caveats: STL has no edges (the edge model is empty), no units (millimetres unless
/// `Options.assumedUnitScaleToMM` says otherwise) and no topology. Shading is flat, from the
/// triangle winding; the normals stored in the file are ignored. Several `solid` blocks in one
/// ASCII file become one body.
public enum STL {

    public static func readGeometry(data: Data, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) throws -> STEP.Geometry {
        try Task.checkCancellation()
        let raw = try STEPGzip.inflateIfGzip(data)
        let decoded = try decode(raw, options: options)
        return try build(decoded, importID: importID, options: options)
    }

    public static func readGeometry(contentsOf url: URL, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) throws -> STEP.Geometry {
        try readGeometry(data: Data(contentsOf: url, options: .mappedIfSafe), importID: importID, options: options)
    }

    public static func loadGeometry(contentsOf url: URL, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) async throws -> STEP.Geometry {
        try await STEPEdgeImporter.detached { try readGeometry(contentsOf: url, importID: importID, options: options) }
    }

    /// The same mesh as a one-body `STEP.Assembly`, for consumers (like the demo) built on assemblies.
    public static func loadAssembly(contentsOf url: URL, importID: UUID = UUID(),
                                    options: STEP.Options = STEP.Options()) async throws -> STEP.Assembly {
        let geometry = try await loadGeometry(contentsOf: url, importID: importID, options: options)
        guard let info = geometry.edges.bodies.first, let mesh = geometry.surfaces.bodies.first else {
            throw STEP.ParseError("STL produced no body.", kind: .malformed)
        }
        var assembly = STEP.Assembly(importID: importID, prototype: nil)
        assembly.bodies = [STEP.Body(id: info.id, info: info, edges: [], mesh: mesh)]
        assembly.bounds = geometry.edges.bounds
        assembly.origin = geometry.surfaces.origin
        assembly.diagnostics = geometry.edges.diagnostics
        assembly.placementCount = 1
        return assembly
    }

    // MARK: - Decoding

    private struct Decoded {
        var vertices: [SIMD3<Double>]   // three per triangle, in file units
        var name: String?
    }

    private static let headerSize = 84
    private static let recordSize = 50
    private static let checkInterval = 16_384

    private static func malformed(_ message: String) -> STEP.ParseError {
        STEP.ParseError(message, kind: .malformed)
    }

    /// Binary is recognised by size (`84 + 50 * N`), never by a leading `solid`: binary headers
    /// often start with it.
    private static func decode(_ data: Data, options: STEP.Options) throws -> Decoded {
        var declared: Int?
        if data.count >= headerSize {
            let count = data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            }
            declared = Int(count)
        }
        if let declared, data.count == headerSize + recordSize * declared {
            guard declared <= options.maximumTriangleCount else {
                throw STEP.ParseError("STL has \(declared) triangles; the limit is \(options.maximumTriangleCount).",
                                      kind: .limitExceeded)
            }
            return Decoded(vertices: try decodeBinary(data, count: declared), name: nil)
        }
        let ascii = try decodeASCII(data, limit: options.maximumTriangleCount)
        if ascii.vertices.isEmpty {
            if let declared, data.count < headerSize + recordSize * declared {
                throw STEP.ParseError("Binary STL header declares \(declared) triangles but the data is "
                                      + "\(data.count) bytes.", kind: .truncated)
            }
            throw malformed("Not an STL file: no binary size match and no `vertex` lines.")
        }
        return ascii
    }

    private static func decodeBinary(_ data: Data, count: Int) throws -> [SIMD3<Double>] {
        var vertices: [SIMD3<Double>] = []
        vertices.reserveCapacity(count * 3)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            func float(_ offset: Int) -> Double {
                Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))))
            }
            for triangle in 0..<count {
                if triangle % checkInterval == 0 { try Task.checkCancellation() }
                let base = headerSize + recordSize * triangle + 12   // skip the stored normal
                for vertex in 0..<3 {
                    let o = base + 12 * vertex
                    let point = SIMD3<Double>(float(o), float(o + 4), float(o + 8))
                    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                        throw malformed("Triangle \(triangle) has a non-finite coordinate.")
                    }
                    vertices.append(point)
                }
            }
        }
        return vertices
    }

    private static let vertexKeyword = Array("vertex".utf8)
    private static let solidKeyword = Array("solid".utf8)

    /// Line scanner over the raw bytes. Only `vertex x y z` lines matter; LF, CRLF and scientific
    /// notation are all fine.
    private static func decodeASCII(_ data: Data, limit: Int) throws -> Decoded {
        var vertices: [SIMD3<Double>] = []
        var name: String?
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var scratch = [CChar](repeating: 0, count: 64)
            var i = 0
            var lines = 0

            func isBlank(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }

            func hasKeyword(_ keyword: [UInt8], at start: Int, end: Int) -> Bool {
                guard end - start >= keyword.count else { return false }
                for k in 0..<keyword.count {
                    var b = bytes[start + k]
                    if b >= 65 && b <= 90 { b += 32 }
                    if b != keyword[k] { return false }
                }
                return end - start == keyword.count || isBlank(bytes[start + keyword.count])
            }

            func number(from position: inout Int, end: Int) throws -> Double {
                while position < end, isBlank(bytes[position]) { position += 1 }
                let start = position
                while position < end, !isBlank(bytes[position]) { position += 1 }
                let length = position - start
                guard length > 0, length < scratch.count else { throw malformed("Bad number in STL vertex line.") }
                for k in 0..<length { scratch[k] = CChar(bitPattern: bytes[start + k]) }
                scratch[length] = 0
                let value: Double? = scratch.withUnsafeBufferPointer { buffer in
                    var stop: UnsafeMutablePointer<CChar>? = nil
                    let result = strtod(buffer.baseAddress!, &stop)
                    guard let stop, stop - UnsafeMutablePointer(mutating: buffer.baseAddress!) == length else { return nil }
                    return result
                }
                guard let value, value.isFinite else { throw malformed("Bad or non-finite number in STL vertex line.") }
                return value
            }

            while i < n {
                lines += 1
                if lines % checkInterval == 0 { try Task.checkCancellation() }
                while i < n, isBlank(bytes[i]) { i += 1 }
                let start = i
                while i < n, bytes[i] != 10, bytes[i] != 13 { i += 1 }
                let end = i
                guard end > start else { continue }
                if hasKeyword(vertexKeyword, at: start, end: end) {
                    var position = start + vertexKeyword.count
                    let x = try number(from: &position, end: end)
                    let y = try number(from: &position, end: end)
                    let z = try number(from: &position, end: end)
                    vertices.append(SIMD3<Double>(x, y, z))
                    if vertices.count > limit * 3 {
                        throw STEP.ParseError("STL has more than \(limit) triangles.", kind: .limitExceeded)
                    }
                } else if name == nil, hasKeyword(solidKeyword, at: start, end: end) {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[(start + solidKeyword.count)..<end]),
                                      as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { name = text }
                }
            }
        }
        guard vertices.count % 3 == 0 else {
            throw malformed("STL has \(vertices.count) vertex lines, not a multiple of 3.")
        }
        return Decoded(vertices: vertices, name: name)
    }

    // MARK: - Building the result

    private static func build(_ decoded: Decoded, importID: UUID, options: STEP.Options) throws -> STEP.Geometry {
        let scale = options.assumedUnitScaleToMM ?? 1
        guard scale.isFinite, scale > 0 else {
            throw STEP.ParseError("assumedUnitScaleToMM must be a positive finite number.", kind: .invalidOptions)
        }
        let source = decoded.vertices
        let total = source.count / 3

        // Bounding box of everything, to scale the "zero area" threshold.
        var all = STEP.Bounds(min: source.first ?? .zero, max: source.first ?? .zero)
        for point in source { all.include(point * scale) }
        let diagonal = simd_length(all.size)
        let epsilon = 1e-12 * diagonal * diagonal

        var kept: [SIMD3<Double>] = []
        kept.reserveCapacity(source.count)
        var bounds: STEP.Bounds?
        var dropped = 0
        for t in 0..<total {
            if t % checkInterval == 0 { try Task.checkCancellation() }
            let a = source[3 * t] * scale, b = source[3 * t + 1] * scale, c = source[3 * t + 2] * scale
            if simd_length(simd_cross(b - a, c - a)) <= epsilon { dropped += 1; continue }
            kept.append(contentsOf: [a, b, c])
            for point in [a, b, c] {
                if bounds == nil { bounds = STEP.Bounds(min: point, max: point) } else { bounds!.include(point) }
            }
        }
        guard let bounds else { throw malformed("STL contains no usable triangles.") }

        let origin = bounds.workpieceOrigin
        let id = STEP.BodyID(representationID: 0, entityID: 0)
        var mesh = STEP.BodyMesh(id: id)
        mesh.positions.reserveCapacity(kept.count)
        mesh.normals.reserveCapacity(kept.count)
        mesh.indices.reserveCapacity(kept.count)
        for t in 0..<(kept.count / 3) {
            let a = kept[3 * t], b = kept[3 * t + 1], c = kept[3 * t + 2]
            let normal = SIMD3<Float>(simd_normalize(simd_cross(b - a, c - a)))
            for point in [a, b, c] {
                mesh.indices.append(UInt32(mesh.positions.count))
                mesh.positions.append(SIMD3<Float>(point - origin))
                mesh.normals.append(normal)
            }
        }

        var notes: [STEP.Diagnostic] = []
        if dropped > 0 {
            notes.append(STEP.Diagnostic(entityID: nil, message: "Dropped \(dropped) zero-area triangle(s).",
                                         severity: .info, code: "degenerate-triangles"))
        }
        notes.append(STEP.Diagnostic(entityID: nil, message: "STL has no edges; showing the shaded mesh only.",
                                     severity: .info, code: "stl-no-edges"))

        let info = STEP.BodyInfo(id: id, contextID: 0, unitScaleToMM: scale, unitsAssumed: true,
                                 bounds: bounds, name: decoded.name)
        let edges = STEP.EdgeModel(importID: importID, bodies: [info], bounds: bounds, diagnostics: notes)
        var surfaces = STEP.SurfaceModel(origin: origin)
        surfaces.bodies = [mesh]
        return STEP.Geometry(edges: edges, surfaces: surfaces)
    }
}
