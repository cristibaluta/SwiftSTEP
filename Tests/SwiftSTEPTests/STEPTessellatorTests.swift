import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T63 (tessellator tests), T31b/T31c (planar faces) and T32 (poles and apexes).
// Fixtures are minimal generated Part 21 files built with `StepBuilder` (STEPCurveTests.swift).

// MARK: - Helpers

private func tessellate(_ data: Data, _ options: STEP.Options = STEP.Options()) throws -> STEP.Geometry {
    try STEP.readGeometry(data: data, options: options)
}

private func point(_ mesh: STEP.BodyMesh, _ index: UInt32) -> SIMD3<Double> {
    SIMD3<Double>(mesh.positions[Int(index)])
}

/// Volume the mesh encloses, by the divergence theorem. Positive when the triangles face outwards.
private func signedVolume(_ mesh: STEP.BodyMesh) -> Double {
    var volume = 0.0
    for t in 0..<mesh.triangleCount {
        let a = point(mesh, mesh.indices[3 * t])
        let b = point(mesh, mesh.indices[3 * t + 1])
        let c = point(mesh, mesh.indices[3 * t + 2])
        volume += simd_dot(a, simd_cross(b, c)) / 6
    }
    return volume
}

/// Triangles whose winding disagrees with the stored normal of their first corner.
private func backwardsTriangles(_ mesh: STEP.BodyMesh) -> Int {
    var count = 0
    for t in 0..<mesh.triangleCount {
        let first = mesh.indices[3 * t]
        let a = point(mesh, first)
        let b = point(mesh, mesh.indices[3 * t + 1])
        let c = point(mesh, mesh.indices[3 * t + 2])
        let normal = simd_cross(b - a, c - a)
        guard simd_length(normal) > 1e-9 else { continue }
        if simd_dot(normal, SIMD3<Double>(mesh.normals[Int(first)])) <= 0 { count += 1 }
    }
    return count
}

private func area(_ mesh: STEP.BodyMesh, face: STEP.FaceMesh) -> Double {
    var total = 0.0
    for t in face.triangles {
        let a = point(mesh, mesh.indices[3 * t])
        let b = point(mesh, mesh.indices[3 * t + 1])
        let c = point(mesh, mesh.indices[3 * t + 2])
        total += simd_length(simd_cross(b - a, c - a)) / 2
    }
    return total
}

private func skipped(_ geometry: STEP.Geometry) -> [STEP.Diagnostic] {
    geometry.surfaces.diagnostics.filter { $0.severity == .skipped }
}

private func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) <= tolerance
}

private func relativeError(_ value: Double, _ expected: Double) -> Double { abs(value - expected) / abs(expected) }

// MARK: - Fixtures

/// A closed cylinder of the given radius and height standing on the XY plane.
private func cylinderSolid(radius: Double = 5, height: Double = 10) -> Data {
    let b = StepBuilder()
    let bottomVertex = b.vertex(SIMD3(radius, 0, 0))
    let topVertex = b.vertex(SIMD3(radius, 0, height))
    let bottom = b.edge(start: bottomVertex, end: bottomVertex,
                        curve: b.circle(placement: b.placement(origin: .zero), radius: radius))
    let top = b.edge(start: topVertex, end: topVertex,
                     curve: b.circle(placement: b.placement(origin: SIMD3(0, 0, height)), radius: radius))
    let seam = b.edge(start: bottomVertex, end: topVertex,
                      curve: b.line(from: SIMD3(radius, 0, 0), direction: SIMD3(0, 0, 1)))
    let side = b.add("CYLINDRICAL_SURFACE('',#\(b.placement(origin: .zero)),\(StepBuilder.real(radius)))")
    let floor = b.add("PLANE('',#\(b.placement(origin: .zero, axis: SIMD3(0, 0, -1))))")
    let roof = b.add("PLANE('',#\(b.placement(origin: SIMD3(0, 0, height))))")
    return b.data(bodies: [StepBuilder.BodySpec(faces: [
        StepBuilder.FaceSpec(surface: floor, loops: [[StepBuilder.rev(bottom)]]),
        StepBuilder.FaceSpec(surface: roof, loops: [[StepBuilder.fwd(top)]]),
        StepBuilder.FaceSpec(surface: side, loops: [[StepBuilder.fwd(bottom), StepBuilder.fwd(seam),
                                                     StepBuilder.rev(top), StepBuilder.rev(seam)]])
    ])])
}

/// The upper half of a ball of radius 5 on the XY plane, closed by its flat base. With `seam` the
/// dome's loop runs out along a meridian to the pole and back, as many CAD systems write it;
/// without, it is the equator alone. `inward` makes the dome face the other way (a cavity).
private func halfBall(seam: Bool, inward: Bool = false) -> Data {
    let b = StepBuilder()
    let radius = 5.0
    let equatorVertex = b.vertex(SIMD3(radius, 0, 0))
    let equator = b.edge(start: equatorVertex, end: equatorVertex,
                         curve: b.circle(placement: b.placement(origin: .zero), radius: radius))
    let sphere = b.add("SPHERICAL_SURFACE('',#\(b.placement(origin: .zero)),\(StepBuilder.real(radius)))")
    var domeLoop: [StepBuilder.Use] = [StepBuilder.fwd(equator)]
    if seam {
        let poleVertex = b.vertex(SIMD3(0, 0, radius))
        // A quarter of the meridian circle in the XZ plane, from the equator up to the pole.
        let meridian = b.circle(placement: b.placement(origin: .zero, axis: SIMD3(0, -1, 0), ref: SIMD3(1, 0, 0)),
                                radius: radius)
        let seamEdge = b.edge(start: equatorVertex, end: poleVertex, curve: meridian)
        domeLoop += [StepBuilder.fwd(seamEdge), StepBuilder.rev(seamEdge)]
    }
    // A reversed dome (sense false) keeps its region but turns its loop round, and the base turns up.
    let dome: StepBuilder.FaceSpec
    let base: StepBuilder.FaceSpec
    if inward {
        var turned: [StepBuilder.Use] = []
        for use in domeLoop.reversed() { turned.append((edge: use.edge, forward: !use.forward)) }
        dome = StepBuilder.FaceSpec(surface: sphere, sameSense: false, loops: [turned])
        let up = b.add("PLANE('',#\(b.placement(origin: .zero, axis: SIMD3(0, 0, 1))))")
        base = StepBuilder.FaceSpec(surface: up, loops: [[StepBuilder.fwd(equator)]])
    } else {
        dome = StepBuilder.FaceSpec(surface: sphere, loops: [domeLoop])
        let down = b.add("PLANE('',#\(b.placement(origin: .zero, axis: SIMD3(0, 0, -1))))")
        base = StepBuilder.FaceSpec(surface: down, loops: [[StepBuilder.rev(equator)]])
    }
    return b.data(bodies: [StepBuilder.BodySpec(faces: [dome, base])])
}

/// A cone of base radius 5 and height 10 standing on the XY plane, apex up, with no seam and no
/// apex vertex: the lateral face is the base circle alone. The surface's axis points down, so
/// its parameter v grows towards the base and the apex is at v = -10.
private func cone() -> Data {
    let b = StepBuilder()
    let vertex = b.vertex(SIMD3(5, 0, 0))
    let rim = b.edge(start: vertex, end: vertex, curve: b.circle(placement: b.placement(origin: .zero), radius: 5))
    let lateral = b.add("CONICAL_SURFACE('',#\(b.placement(origin: .zero, axis: SIMD3(0, 0, -1))),"
                        + "\(StepBuilder.real(5)),\(StepBuilder.real(atan(0.5))))")
    let floor = b.add("PLANE('',#\(b.placement(origin: .zero, axis: SIMD3(0, 0, -1))))")
    return b.data(bodies: [StepBuilder.BodySpec(faces: [
        StepBuilder.FaceSpec(surface: lateral, loops: [[StepBuilder.fwd(rim)]]),
        StepBuilder.FaceSpec(surface: floor, loops: [[StepBuilder.rev(rim)]])
    ])])
}

/// One planar face: a square of the given side with a grid of round holes of radius 2, ten apart.
private func plate(side: Double, holesAlong: Int) -> Data {
    let b = StepBuilder()
    let corners: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(side, 0, 0), SIMD3(side, side, 0), SIMD3(0, side, 0)]
    let vertices = corners.map { b.vertex($0) }
    var outer: [StepBuilder.Use] = []
    for i in 0..<4 {
        let from = corners[i]
        let to = corners[(i + 1) % 4]
        let edge = b.edge(start: vertices[i], end: vertices[(i + 1) % 4],
                          curve: b.line(from: from, direction: simd_normalize(to - from)))
        outer.append(StepBuilder.fwd(edge))
    }
    var loops = [outer]
    for i in 0..<holesAlong {
        for j in 0..<holesAlong {
            let centre = SIMD3<Double>(5 + 10 * Double(i), 5 + 10 * Double(j), 0)
            let start = b.vertex(centre + SIMD3(2, 0, 0))
            let hole = b.edge(start: start, end: start, curve: b.circle(placement: b.placement(origin: centre), radius: 2))
            loops.append([StepBuilder.rev(hole)])
        }
    }
    return b.data(bodies: [StepBuilder.BodySpec(faces: [StepBuilder.FaceSpec(loops: loops)])])
}

/// Area of a closed polyline in the XY plane (last point equal to the first).
private func polygonArea(_ points: [SIMD3<Double>]) -> Double {
    var sum = 0.0
    for (a, b) in zip(points, points.dropFirst()) { sum += a.x * b.y - b.x * a.y }
    return abs(sum) / 2
}

// MARK: - Tests

@Suite("STEP tessellator")
struct STEPTessellatorTests {

    // MARK: Box

    @Test func aBoxIsTwelveTrianglesAndEnclosesItsVolume() throws {
        let b = StepBuilder()
        let geometry = try tessellate(b.data(bodies: [boxBody(b)]))
        let mesh = try #require(geometry.surfaces.bodies.first)

        #expect(geometry.surfaces.bodies.count == 1)
        #expect(geometry.surfaces.failedFaceCount == 0 && geometry.surfaces.tessellatedFaceCount == 6)
        #expect(geometry.surfaces.unsurfacedBodies.isEmpty && !mesh.isPartial)
        #expect(skipped(geometry).isEmpty)
        #expect(mesh.triangleCount == 12)
        #expect(mesh.faces.count == 6 && mesh.faces.allSatisfy { $0.triangles.count == 2 })
        #expect(mesh.faces.allSatisfy { if case .plane = $0.surface { true } else { false } })
        #expect(abs(signedVolume(mesh) - 6000) < 0.1)
        #expect(backwardsTriangles(mesh) == 0)

        // Every triangle maps back to its face, and the ranges tile the mesh.
        #expect(mesh.faces.reduce(0) { $0 + $1.triangles.count } == mesh.triangleCount)
        for t in 0..<mesh.triangleCount { #expect(mesh.face(ofTriangle: t) != nil) }
        #expect(mesh.face(ofTriangle: mesh.triangleCount) == nil)
        // A box face adds no point beyond its corners: 6 faces x 4 corners.
        #expect(mesh.positions.count == 24)
    }

    @Test func aBoxFaceKeepsItsSurfaceNormalAndAReversedSenseTurnsItAround() throws {
        let b = StepBuilder()
        var body = boxBody(b)
        body.faces[1].sameSense = false // the top face, now facing into the material
        let mesh = try #require(try tessellate(b.data(bodies: [body])).surfaces.bodies.first)
        let top = try #require(mesh.faces.first { !$0.sameSense })
        for t in top.triangles {
            #expect(isClose(mesh.normals[Int(mesh.indices[3 * t])], SIMD3<Float>(0, 0, -1)))
        }
        #expect(top.sameSense == false)
        #expect(backwardsTriangles(mesh) == 0, "winding follows the flipped normal")
    }

    // MARK: Cylinder

    @Test func aCylinderIsFilledWithinTheChordTolerance() throws {
        let geometry = try tessellate(cylinderSolid())
        let mesh = try #require(geometry.surfaces.bodies.first)

        #expect(geometry.surfaces.failedFaceCount == 0 && geometry.surfaces.tessellatedFaceCount == 3)
        #expect(skipped(geometry).isEmpty)
        #expect(mesh.faces.contains { if case .cylinder = $0.surface { true } else { false } })
        #expect(mesh.triangleCount > 12)
        // The mesh is inscribed, so it is a little smaller than the true cylinder, never larger.
        let exact = Double.pi * 25 * 10
        let volume = signedVolume(mesh)
        #expect(volume < exact + 1e-6)
        #expect(relativeError(volume, exact) < 0.01)
        #expect(backwardsTriangles(mesh) == 0)

        // Every vertex of the wall is on the cylinder; its normal is radial.
        let origin = geometry.surfaces.origin
        let wall = try #require(mesh.faces.first { if case .cylinder = $0.surface { true } else { false } })
        for t in wall.triangles {
            for k in 0..<3 {
                let index = Int(mesh.indices[3 * t + k])
                let p = SIMD3<Double>(mesh.positions[index]) + origin
                #expect(abs(simd_length(SIMD2(p.x, p.y)) - 5) < 0.011, "on the cylinder, or on a boundary chord")
                let n = mesh.normals[index]
                #expect(abs(n.z) < 1e-6)
            }
        }
    }

    @Test func aFinerToleranceGivesMoreTriangles() throws {
        let coarse = try tessellate(cylinderSolid(), STEP.Options(chordToleranceMM: 0.1))
        let fine = try tessellate(cylinderSolid(), STEP.Options(chordToleranceMM: 0.001))
        let coarseMesh = try #require(coarse.surfaces.bodies.first)
        let fineMesh = try #require(fine.surfaces.bodies.first)
        #expect(fineMesh.triangleCount > coarseMesh.triangleCount)
    }

    // MARK: Holes

    @Test func aFaceWithACircularHoleLeavesTheHoleOpen() throws {
        let geometry = try tessellate(plate(side: 20, holesAlong: 1))
        let mesh = try #require(geometry.surfaces.bodies.first)
        let face = try #require(mesh.faces.first)
        let circle = try #require(geometry.edges.edges.first { $0.kind == .circle })
        let n = geometry.edges.edges.reduce(0) { $0 + $1.points.count - 1 }

        #expect(geometry.surfaces.failedFaceCount == 0 && mesh.faces.count == 1)
        // Square (400) minus the sampled hole, which is what the wireframe draws.
        let expected = 400 - polygonArea(circle.points)
        #expect(abs(area(mesh, face: face) - expected) < 0.01)
        #expect(backwardsTriangles(mesh) == 0)
        for t in face.triangles {
            let corners = (0..<3).map { SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + $0])]) + geometry.surfaces.origin }
            let centre = (corners[0] + corners[1] + corners[2]) / 3
            #expect(simd_length(SIMD2(centre.x - 5, centre.y - 5)) > 1.98, "no triangle in the hole")
        }
        // T31b: a plane adds no point of its own, so the mesh has no more vertices than the outline.
        #expect(mesh.positions.count <= n)
        #expect(mesh.triangleCount <= n) // n + 2h - 2 with one hole
        #expect(mesh.triangleCount >= n - 4)
        #expect(mesh.normals.allSatisfy { isClose($0, SIMD3<Float>(0, 0, 1)) })
    }

    // MARK: Plate with 100 holes (T31c)

    @Test func aPlateWithAHundredHolesStaysNearLinear() throws {
        let geometry = try tessellate(plate(side: 100, holesAlong: 10))
        let mesh = try #require(geometry.surfaces.bodies.first)
        let n = geometry.edges.edges.reduce(0) { $0 + $1.points.count - 1 }
        let ceiling = n + 2 * 100 - 2

        #expect(geometry.edges.edges.filter { $0.kind == .circle }.count == 100)
        #expect(geometry.surfaces.failedFaceCount == 0 && geometry.surfaces.bodies.count == 1)
        // No triangulation of n boundary points and h holes has more than n + 2h - 2 triangles;
        // a point on a straight run may go unused, hence the small allowance.
        #expect(mesh.triangleCount <= ceiling)
        #expect(mesh.triangleCount >= ceiling - 20)
        #expect(mesh.triangleCount < STEPTessellator.maximumTriangles / 10)
        #expect(mesh.positions.count <= n)
        #expect(backwardsTriangles(mesh) == 0)
        let holes = geometry.edges.edges.filter { $0.kind == .circle }.reduce(0) { $0 + polygonArea($1.points) }
        let face = try #require(mesh.faces.first)
        #expect(abs(area(mesh, face: face) - (10_000 - holes)) < 0.5)
    }

    // MARK: Void shell

    @Test func aVoidShellFacesIntoTheCavity() throws {
        let b = StepBuilder()
        let outer = boxBody(b)
        let cavity = boxBody(b, origin: SIMD3(2, 2, 2), size: SIMD3(4, 4, 4))
        let body = StepBuilder.BodySpec(faces: outer.faces, voidFaces: cavity.faces)
        let geometry = try tessellate(b.data(bodies: [body]))
        let mesh = try #require(geometry.surfaces.bodies.first)

        #expect(geometry.surfaces.failedFaceCount == 0 && mesh.faces.count == 12)
        #expect(backwardsTriangles(mesh) == 0)
        // The cavity's faces point out of the material, into the void: 6000 - 64.
        #expect(abs(signedVolume(mesh) - 5936) < 0.1)
    }

    // MARK: Failures and limits

    private func boxWithAnUnsupportedFace(_ b: StepBuilder) -> StepBuilder.BodySpec {
        var body = boxBody(b)
        let plane = body.faces[1].surface!
        body.faces[0].surface = b.add("OFFSET_SURFACE('',#\(plane),1.0E+00,.F.,.F.)")
        return body
    }

    @Test func oneUnsupportedFaceLeavesTheOtherFive() throws {
        let b = StepBuilder()
        let geometry = try tessellate(b.data(bodies: [boxWithAnUnsupportedFace(b)]))
        let mesh = try #require(geometry.surfaces.bodies.first)

        #expect(mesh.isPartial && mesh.failedFaceIDs.count == 1)
        #expect(geometry.surfaces.partialBodies == [mesh.id])
        #expect(mesh.triangleCount == 10 && mesh.faces.count == 5)
        #expect(geometry.surfaces.failedFaceCount == 1 && geometry.surfaces.tessellatedFaceCount == 5)
        let failure = try #require(geometry.surfaces.faceFailures.first)
        #expect(failure.surfaceType == "OFFSET_SURFACE")
        #expect(failure.faceID == mesh.failedFaceIDs[0])
        let codes = Set(geometry.surfaces.diagnostics.map(\.code))
        #expect(codes.contains("face-failed") && codes.contains("body-partial"))
    }

    @Test func theStrictOptionDropsTheWholeBody() throws {
        let b = StepBuilder()
        let geometry = try tessellate(b.data(bodies: [boxWithAnUnsupportedFace(b)]),
                                      STEP.Options(keepPartialSurfaces: false))
        #expect(geometry.surfaces.bodies.isEmpty && geometry.surfaces.unsurfacedBodies.count == 1)
        #expect(geometry.surfaces.triangleCount == 0)
        #expect(geometry.surfaces.diagnostics.contains { $0.code == "body-unfilled" })
        // The wireframe is unaffected.
        #expect(geometry.edges.edges.count == 12)
    }

    @Test func theTriangleCapIsAnOptionAndFailsTheFacesThatDoNotFit() throws {
        let b = StepBuilder()
        let data = b.data(bodies: [boxBody(b)])
        // Two triangles per face: two faces fit into five, the other four do not.
        let geometry = try tessellate(data, STEP.Options(maximumTriangleCount: 5))
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(mesh.triangleCount == 4 && mesh.faces.count == 2)
        #expect(mesh.failedFaceIDs.count == 4)
        #expect(geometry.surfaces.faceFailures.allSatisfy { $0.reason.contains("Triangle limit") })

        let none = try tessellate(data, STEP.Options(maximumTriangleCount: 0))
        #expect(none.surfaces.bodies.isEmpty && none.surfaces.unsurfacedBodies.count == 1)

        // The default is unchanged.
        let normal = try tessellate(data)
        #expect(normal.surfaces.triangleCount == 12)
    }

    // MARK: Poles and apexes (T32)

    @Test func aHemisphereWithASeamToThePoleIsFilled() throws {
        let geometry = try tessellate(halfBall(seam: true))
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(geometry.surfaces.failedFaceCount == 0 && !mesh.isPartial)
        #expect(skipped(geometry).isEmpty)
        let exact = 2.0 / 3.0 * Double.pi * 125
        let volume = signedVolume(mesh)
        #expect(volume < exact + 1e-6 && relativeError(volume, exact) < 0.02)
        #expect(backwardsTriangles(mesh) == 0)
        #expect(mesh.faces.contains { if case .sphere = $0.surface { true } else { false } })
    }

    @Test func aDomeWrittenAsOneCircleContainsThePoleItsDirectionPointsTo() throws {
        let geometry = try tessellate(halfBall(seam: false))
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(geometry.surfaces.failedFaceCount == 0 && !mesh.isPartial)
        #expect(skipped(geometry).isEmpty)
        let exact = 2.0 / 3.0 * Double.pi * 125
        let volume = signedVolume(mesh)
        #expect(volume < exact + 1e-6 && relativeError(volume, exact) < 0.02, "the upper half, not the lower")
        #expect(backwardsTriangles(mesh) == 0)
        // Every dome vertex is on or above the equator and on the sphere.
        let origin = geometry.surfaces.origin
        let dome = try #require(mesh.faces.first { if case .sphere = $0.surface { true } else { false } })
        for t in dome.triangles {
            for k in 0..<3 {
                let p = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t + k])]) + origin
                #expect(p.z > -1e-4 && abs(simd_length(p) - 5) < 0.02, "on the sphere, or on a boundary chord")
            }
        }
    }

    @Test func theSameDomeTurnedInsideOutIsTheSameRegionWithTheOppositeVolume() throws {
        let geometry = try tessellate(halfBall(seam: false, inward: true))
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(geometry.surfaces.failedFaceCount == 0)
        let exact = 2.0 / 3.0 * Double.pi * 125
        let volume = signedVolume(mesh)
        #expect(volume > -exact - 1e-6 && relativeError(-volume, exact) < 0.02, "a half-ball cavity")
        #expect(backwardsTriangles(mesh) == 0)
        let origin = geometry.surfaces.origin
        let dome = try #require(mesh.faces.first { if case .sphere = $0.surface { true } else { false } })
        #expect(dome.sameSense == false)
        for t in dome.triangles {
            let p = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * t])]) + origin
            #expect(p.z > -1e-4, "still the upper half")
        }
    }

    @Test func aConeTipWithNoSeamAndNoApexVertexIsFilled() throws {
        let geometry = try tessellate(cone())
        let mesh = try #require(geometry.surfaces.bodies.first)
        #expect(geometry.surfaces.failedFaceCount == 0 && !mesh.isPartial)
        #expect(skipped(geometry).isEmpty)
        let exact = Double.pi * 25 * 10 / 3
        let volume = signedVolume(mesh)
        #expect(volume < exact + 1e-6 && relativeError(volume, exact) < 0.01)
        #expect(backwardsTriangles(mesh) == 0)
        // The apex is reached: the highest point of the mesh is 10 above the base.
        let origin = geometry.surfaces.origin
        let top = mesh.positions.map { Double($0.z) + origin.z }.max() ?? 0
        #expect(abs(top - 10) < 1e-4)
    }

    @Test func aSingleCircleOnACylinderStillHasNoPoleToFill() throws {
        // A cylinder has no pole, so one circle is not a face: it is reported, not guessed.
        let b = StepBuilder()
        let vertex = b.vertex(SIMD3(5, 0, 0))
        let rim = b.edge(start: vertex, end: vertex, curve: b.circle(placement: b.placement(origin: .zero), radius: 5))
        let side = b.add("CYLINDRICAL_SURFACE('',#\(b.placement(origin: .zero)),\(StepBuilder.real(5)))")
        let geometry = try tessellate(b.data(bodies: [StepBuilder.BodySpec(faces: [
            StepBuilder.FaceSpec(surface: side, loops: [[StepBuilder.fwd(rim)]])
        ])]))
        #expect(geometry.surfaces.bodies.isEmpty)
        #expect(geometry.surfaces.faceFailures.count == 1)
        #expect(geometry.surfaces.faceFailures[0].reason.contains("not supported"))
    }
}
