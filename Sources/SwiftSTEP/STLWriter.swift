import Foundation
import simd

extension STL {

    /// Binary STL of every body's triangles, in millimetres and in model coordinates (the mesh
    /// origin is added back). Normals are recomputed from the winding. STL carries no edges, faces,
    /// names or units, so those are lost.
    public static func binaryData(for assembly: STEP.Assembly) -> Data {
        binaryData(meshes: assembly.bodies.compactMap { $0.mesh }, origin: assembly.origin)
    }

    public static func binaryData(for geometry: STEP.Geometry) -> Data {
        binaryData(meshes: geometry.surfaces.bodies, origin: geometry.surfaces.origin)
    }

    private static func binaryData(meshes: [STEP.BodyMesh], origin: SIMD3<Double>) -> Data {
        let count = meshes.reduce(0) { $0 + $1.triangleCount }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(84 + 50 * count)

        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func put(_ value: Float) { put(value.bitPattern) }
        func put(_ vector: SIMD3<Float>) { put(vector.x); put(vector.y); put(vector.z) }

        var header = Array("SwiftSTEP binary STL".utf8)
        header += [UInt8](repeating: 0, count: 80 - header.count)   // must not start with "solid"
        bytes.append(contentsOf: header)
        put(UInt32(count))

        for mesh in meshes {
            for t in 0..<mesh.triangleCount {
                let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t])]) + origin
                let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 1])]) + origin
                let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + 2])]) + origin
                let cross = simd_cross(b - a, c - a)
                let length = simd_length(cross)
                put(length > 0 ? SIMD3<Float>(cross / length) : SIMD3<Float>(0, 0, 0))
                put(SIMD3<Float>(a)); put(SIMD3<Float>(b)); put(SIMD3<Float>(c))
                bytes.append(0); bytes.append(0)                      // attribute byte count
            }
        }
        return Data(bytes)
    }
}
