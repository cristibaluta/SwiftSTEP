import Foundation
import simd

extension STL {

    /// Optional post-processing of the triangle soup. The defaults keep Phase 1 behaviour
    /// (no edges, flat shading, unwelded vertices).
    public struct Options: Sendable {
        /// Non-nil turns on edge extraction: boundary edges, non-manifold edges, and interior edges
        /// whose face normals differ by more than this angle, chained into polylines.
        public var featureAngleDegrees: Double?
        /// Weld vertices and average normals across edges that are not features, splitting vertices
        /// at the features. Uses `featureAngleDegrees`, or 30 degrees when that is nil.
        public var smoothShading: Bool

        public init(featureAngleDegrees: Double? = nil, smoothShading: Bool = false) {
            self.featureAngleDegrees = featureAngleDegrees
            self.smoothShading = smoothShading
        }
    }
}

struct STLAnalysis {
    var polylines: [[SIMD3<Double>]] = []
    var nonManifoldEdgeCount = 0
    // Smooth mesh (only when requested): indexed, in the same coordinates as the input points.
    var positions: [SIMD3<Double>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
}

enum STLFeatureEdges {

    private struct EdgeRecord {
        var first: Int32 = -1
        var second: Int32 = -1
        var count: Int32 = 0
        mutating func add(_ triangle: Int32) {
            if count == 0 { first = triangle } else if count == 1 { second = triangle }
            count += 1
        }
    }

    private static let checkInterval = 16_384

    /// `points` holds three vertices per triangle (already scaled, zero-area triangles removed).
    /// Vertices are welded on a grid of about 1e-5 of the bounding-box diagonal, so a vertex that
    /// sits right on a grid boundary can occasionally fail to weld; that shows up as boundary edges.
    static func analyze(_ points: [SIMD3<Double>], angleDegrees: Double, diagonal: Double,
                        wantEdges: Bool, wantSmooth: Bool) throws -> STLAnalysis {
        var result = STLAnalysis()
        let triangleCount = points.count / 3
        let tolerance = diagonal > 0 ? 1e-5 * diagonal : 1

        // 1. Weld.
        var ids = [Int32](repeating: 0, count: points.count)
        var representatives: [SIMD3<Double>] = []
        var lookup: [SIMD3<Int64>: Int32] = [:]
        for (i, p) in points.enumerated() {
            if i % checkInterval == 0 { try Task.checkCancellation() }
            let key = SIMD3<Int64>(Int64((p.x / tolerance).rounded()), Int64((p.y / tolerance).rounded()),
                                   Int64((p.z / tolerance).rounded()))
            if let id = lookup[key] {
                ids[i] = id
            } else {
                let id = Int32(representatives.count)
                lookup[key] = id
                representatives.append(p)
                ids[i] = id
            }
        }

        // Unnormalised face normals (length = twice the area, so they weight averages by area).
        var crosses = [SIMD3<Double>](repeating: .zero, count: triangleCount)
        for t in 0..<triangleCount {
            crosses[t] = simd_cross(points[3 * t + 1] - points[3 * t], points[3 * t + 2] - points[3 * t])
        }

        // 2. Edge map: sorted welded pair -> adjacent triangles.
        func key(_ u: Int32, _ v: Int32) -> UInt64 {
            (UInt64(UInt32(min(u, v))) << 32) | UInt64(UInt32(max(u, v)))
        }
        var edgeMap: [UInt64: EdgeRecord] = [:]
        edgeMap.reserveCapacity(triangleCount * 3 / 2)
        for t in 0..<triangleCount {
            if t % checkInterval == 0 { try Task.checkCancellation() }
            for k in 0..<3 {
                let u = ids[3 * t + k], v = ids[3 * t + (k + 1) % 3]
                if u == v { continue }
                edgeMap[key(u, v), default: EdgeRecord()].add(Int32(t))
            }
        }

        // 3. Classify.
        let cosThreshold = cos(angleDegrees * .pi / 180)
        var features: [(Int32, Int32)] = []
        var smooth: [(u: Int32, v: Int32, a: Int32, b: Int32)] = []
        for (k, record) in edgeMap {
            let u = Int32(truncatingIfNeeded: k >> 32), v = Int32(truncatingIfNeeded: k & 0xFFFF_FFFF)
            switch record.count {
            case 1:
                features.append((u, v))
            case 2:
                let n1 = simd_normalize(crosses[Int(record.first)]), n2 = simd_normalize(crosses[Int(record.second)])
                if simd_dot(n1, n2) < cosThreshold { features.append((u, v)) }
                else { smooth.append((u, v, record.first, record.second)) }
            default:
                features.append((u, v))
                result.nonManifoldEdgeCount += 1
            }
        }
        features.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }   // deterministic output

        // 4. Chain feature edges into polylines, passing through vertices of degree 2.
        if wantEdges {
            var adjacency = [[Int]](repeating: [], count: representatives.count)
            for (index, edge) in features.enumerated() {
                adjacency[Int(edge.0)].append(index)
                adjacency[Int(edge.1)].append(index)
            }
            var used = [Bool](repeating: false, count: features.count)

            func walk(from start: Int32, along first: Int) {
                var line = [representatives[Int(start)]]
                var vertex = start
                var edge = first
                while true {
                    used[edge] = true
                    let (a, b) = features[edge]
                    vertex = a == vertex ? b : a
                    line.append(representatives[Int(vertex)])
                    let incident = adjacency[Int(vertex)]
                    guard incident.count == 2, let next = incident.first(where: { !used[$0] }) else { break }
                    edge = next
                }
                result.polylines.append(line)
            }

            // Open chains and junctions first, so a chain is never split in the middle...
            for vertex in 0..<representatives.count where adjacency[vertex].count != 2 {
                for edge in adjacency[vertex] where !used[edge] { walk(from: Int32(vertex), along: edge) }
            }
            // ...then whatever is left is a closed loop.
            for edge in 0..<features.count where !used[edge] { walk(from: features[edge].0, along: edge) }
        }

        // 5. Smooth shading: union the corners of triangles that meet across a non-feature edge.
        if wantSmooth {
            var parent = (0..<Int32(points.count)).map { $0 }
            func find(_ x: Int32) -> Int32 {
                var x = x
                while parent[Int(x)] != x { parent[Int(x)] = parent[Int(parent[Int(x)])]; x = parent[Int(x)] }
                return x
            }
            func corner(_ triangle: Int32, _ vertex: Int32) -> Int32 {
                let base = Int(triangle) * 3
                for k in 0..<3 where ids[base + k] == vertex { return Int32(base + k) }
                return Int32(base)
            }
            for edge in smooth {
                for vertex in [edge.u, edge.v] {
                    let a = find(corner(edge.a, vertex)), b = find(corner(edge.b, vertex))
                    if a != b { parent[Int(a)] = b }
                }
            }
            var indexOfRoot: [Int32: UInt32] = [:]
            var sums: [SIMD3<Double>] = []
            result.indices.reserveCapacity(points.count)
            for c in 0..<points.count {
                if c % checkInterval == 0 { try Task.checkCancellation() }
                let root = find(Int32(c))
                let index: UInt32
                if let existing = indexOfRoot[root] {
                    index = existing
                } else {
                    index = UInt32(result.positions.count)
                    indexOfRoot[root] = index
                    result.positions.append(points[c])
                    sums.append(.zero)
                }
                sums[Int(index)] += crosses[c / 3]
                result.indices.append(index)
            }
            result.normals = sums.map { sum in
                let length = simd_length(sum)
                return length > 0 ? SIMD3<Float>(sum / length) : SIMD3<Float>(0, 0, 1)
            }
        }
        return result
    }
}
