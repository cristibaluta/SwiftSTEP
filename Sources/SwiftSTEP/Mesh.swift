import Foundation
import simd

extension STEP {

    /// The triangles of one face inside its body's mesh.
    public struct FaceMesh: Sendable {
        /// ADVANCED_FACE / FACE_SURFACE entity ID.
        public let faceID: Int
        /// Exact surface data for picking and feature recognition.
        public let surface: Surface
        /// The face's own `same_sense` flag (not the shell orientation).
        public let sameSense: Bool
        /// Triangle numbers (index `3 * n ..< 3 * n + 3` in `indices`) that belong to this face.
        public let triangles: Range<Int>
    }

    /// One body's triangle mesh. Positions are Float, millimetres relative to
    /// `SurfaceModel.origin`, so they line up with wireframe points moved by the same origin.
    /// Normals follow the face (analytic, never averaged across a sharp edge) and point out of
    /// the material. The winding of every triangle agrees with its normal.
    public struct BodyMesh: Sendable {
        public let id: BodyID
        public internal(set) var positions: [SIMD3<Float>] = []
        public internal(set) var normals: [SIMD3<Float>] = []
        public internal(set) var indices: [UInt32] = []
        /// Sorted by triangle range, so a triangle number finds its face by binary search.
        public internal(set) var faces: [FaceMesh] = []

        public var triangleCount: Int { indices.count / 3 }

        /// The face a triangle belongs to.
        public func face(ofTriangle triangle: Int) -> FaceMesh? {
            var low = 0
            var high = faces.count
            while low < high {
                let middle = (low + high) / 2
                if faces[middle].triangles.upperBound <= triangle { low = middle + 1 } else { high = middle }
            }
            guard low < faces.count, faces[low].triangles.contains(triangle) else { return nil }
            return faces[low]
        }

        /// Three points per triangle moved by `offset`.
        public func occluderTriangles(offset: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
            var result: [SIMD3<Float>] = []
            result.reserveCapacity(indices.count)
            for index in indices { result.append(positions[Int(index)] + offset) }
            return result
        }
    }

    public struct SurfaceModel: Sendable {
        /// Origin the Float positions are relative to (`Bounds.workpieceOrigin`).
        public internal(set) var origin: SIMD3<Double>
        /// Bodies whose every face was tessellated. Only these may occlude edges.
        public internal(set) var bodies: [BodyMesh] = []
        /// Bodies that had at least one unsupported or failed face. A partial occluder would
        /// misclassify visible edges as hidden, so such a body gets no surface at all.
        public internal(set) var unsurfacedBodies: [BodyID] = []
        public internal(set) var diagnostics: [Diagnostic] = []
        /// Distinct faces reachable from the supported bodies.
        public internal(set) var reachableFaceCount = 0
        /// Faces that could not be tessellated (each has a diagnostic).
        public internal(set) var failedFaceCount = 0
        /// Faces inside `bodies`.
        public internal(set) var tessellatedFaceCount = 0
        public var triangleCount: Int { bodies.reduce(0) { $0 + $1.triangleCount } }

        public init(origin: SIMD3<Double> = .zero) { self.origin = origin }

        public func mesh(for id: BodyID) -> BodyMesh? { bodies.first { $0.id == id } }
    }
}
