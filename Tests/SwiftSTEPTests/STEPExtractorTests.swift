import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T62: what the edge extractor reports about a model, apart from the curves themselves.

private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-9) -> Bool {
    simd_distance(a, b) <= tolerance
}

/// Everything about an edge that must not change between two runs on the same file.
private struct EdgeSignature: Equatable {
    let id: STEP.EdgeID
    let kind: STEP.Edge.CurveKind
    let curve: STEP.Edge.Curve
    let points: [SIMD3<Double>]
    let startVertexID: Int?
    let endVertexID: Int?
    let adjacentFaceIDs: [Int]
    let isSeam: Bool

    init(_ edge: STEP.Edge) {
        id = edge.id
        kind = edge.kind
        curve = edge.curve
        points = edge.points
        startVertexID = edge.startVertexID
        endVertexID = edge.endVertexID
        adjacentFaceIDs = edge.adjacentFaceIDs
        isSeam = edge.isSeam
    }
}

/// Two boxes and a cylinder-like body, so there are several bodies and several kinds of edge.
private func severalBodies(_ b: StepBuilder) -> Data {
    let first = boxBody(b, origin: SIMD3(-50, -20, -5), size: SIMD3(10, 10, 10))
    let second = boxBody(b, origin: SIMD3(100, 30, 0), size: SIMD3(5, 5, 5))
    let vertex = b.vertex(SIMD3(5, 0, 0))
    let ring = b.edge(start: vertex, end: vertex, curve: b.circle(placement: b.placement(origin: .zero), radius: 5))
    let disc = StepBuilder.BodySpec(faces: [StepBuilder.FaceSpec(loops: [[StepBuilder.fwd(ring)]])])
    return b.data(bodies: [first, second, disc])
}

@Suite("STEP extractor")
struct STEPExtractorTests {

    // MARK: adjacentFaceIDs

    @Test func everyEdgeOfABoxNamesTheTwoFacesThatShareIt() throws {
        let b = StepBuilder()
        let topology = try STEP.readTopology(data: b.data(bodies: [boxBody(b)]))
        let faceIDs = Set(topology.faces.map(\.id))
        #expect(faceIDs.count == 6)

        var uses: [Int: Int] = [:]
        for edge in topology.edges.edges {
            #expect(edge.adjacentFaceIDs.count == 2)
            #expect(Set(edge.adjacentFaceIDs).count == 2, "two different faces, not one face twice")
            #expect(Set(edge.adjacentFaceIDs).isSubset(of: faceIDs))
            #expect(!edge.isSeam)
            for id in edge.adjacentFaceIDs { uses[id, default: 0] += 1 }
        }
        // Each face is named by its four edges, and by no others.
        #expect(Set(uses.keys) == faceIDs)
        #expect(uses.values.allSatisfy { $0 == 4 })
    }

    @Test func aFaceWithAHoleIsNamedByTheHolesEdgeToo() throws {
        let b = StepBuilder()
        let corners: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(20, 0, 0), SIMD3(20, 20, 0), SIMD3(0, 20, 0)]
        let vertices = corners.map { b.vertex($0) }
        var outer: [StepBuilder.Use] = []
        for i in 0..<4 {
            let from = corners[i]
            let to = corners[(i + 1) % 4]
            let edge = b.edge(start: vertices[i], end: vertices[(i + 1) % 4],
                              curve: b.line(from: from, direction: simd_normalize(to - from)))
            outer.append(StepBuilder.fwd(edge))
        }
        let start = b.vertex(SIMD3(14, 10, 0))
        let hole = b.edge(start: start, end: start,
                          curve: b.circle(placement: b.placement(origin: SIMD3(10, 10, 0)), radius: 4))
        let topology = try STEP.readTopology(data: b.data(bodies: [
            StepBuilder.BodySpec(faces: [StepBuilder.FaceSpec(loops: [outer, [StepBuilder.rev(hole)]])])
        ]))
        let face = try #require(topology.faces.first)
        #expect(topology.faces.count == 1 && topology.edges.edges.count == 5)
        for edge in topology.edges.edges {
            #expect(edge.adjacentFaceIDs == [face.id], "\(edge.kind) is used by the one face, once")
        }
    }

    // MARK: skippedEdgeCount

    @Test func anEdgeThatCannotBeSampledIsCountedAsSkipped() throws {
        let b = StepBuilder()
        let line = b.edge(start: b.vertex(.zero), end: b.vertex(SIMD3(10, 0, 0)),
                          curve: b.line(from: .zero, direction: SIMD3(1, 0, 0)))
        let parabola = b.add("PARABOLA('',#\(b.placement(origin: .zero)),1.0E+00)")
        let bad = b.edge(start: b.vertex(SIMD3(0, 5, 0)), end: b.vertex(SIMD3(10, 5, 0)), curve: parabola)
        let model = try STEP.read(data: b.data(loops: [[StepBuilder.fwd(line)], [StepBuilder.fwd(bad)]]))

        #expect(model.edges.count == 1)
        #expect(model.reachableEdgeCount == 2)
        #expect(model.skippedEdgeCount == 1)
        #expect(model.diagnostics.contains { $0.code == "unsupported-curve" && $0.severity == .skipped })
    }

    @Test func everyEdgeIsCountedOnceNoMatterHowManyFacesUseIt() throws {
        let b = StepBuilder()
        let model = try STEP.read(data: b.data(bodies: [boxBody(b)]))
        #expect(model.edges.count == 12 && model.reachableEdgeCount == 12 && model.skippedEdgeCount == 0)
    }

    @Test func anEdgeNoSupportedBodyReachesIsNotCounted() throws {
        let b = StepBuilder()
        let used = b.edge(start: b.vertex(.zero), end: b.vertex(SIMD3(10, 0, 0)),
                          curve: b.line(from: .zero, direction: SIMD3(1, 0, 0)))
        // Defined, but in no loop of any face.
        _ = b.edge(start: b.vertex(SIMD3(0, 9, 0)), end: b.vertex(SIMD3(10, 9, 0)),
                   curve: b.line(from: SIMD3(0, 9, 0), direction: SIMD3(1, 0, 0)))
        let model = try STEP.read(data: b.data(loops: [[StepBuilder.fwd(used)]]))
        #expect(model.edges.count == 1)
        #expect(model.reachableEdgeCount == 1 && model.skippedEdgeCount == 0)
    }

    // MARK: Determinism

    @Test func twoRunsWithTheSameImportIDGiveTheSameModel() throws {
        let b = StepBuilder()
        let data = severalBodies(b)
        let importID = UUID()
        let runs = try (0..<3).map { _ in try STEP.read(data: data, importID: importID) }

        for run in runs {
            #expect(run.importID == importID)
            #expect(run.edges.allSatisfy { $0.id.importID == importID })
        }
        for run in runs.dropFirst() {
            #expect(run.edges.map(EdgeSignature.init) == runs[0].edges.map(EdgeSignature.init))
            #expect(run.bodies.map(\.id) == runs[0].bodies.map(\.id))
            #expect(run.diagnostics == runs[0].diagnostics)
            #expect(run.reachableEdgeCount == runs[0].reachableEdgeCount)
            #expect(run.indexedEntityCount == runs[0].indexedEntityCount)
            #expect(run.bounds?.min == runs[0].bounds?.min && run.bounds?.max == runs[0].bounds?.max)
        }
    }

    @Test func aNewImportIDChangesTheIDsAndNothingElse() throws {
        let b = StepBuilder()
        let data = severalBodies(b)
        let first = try STEP.read(data: data)
        let second = try STEP.read(data: data)
        #expect(first.importID != second.importID)
        #expect(first.edges.count == second.edges.count)
        for (x, y) in zip(first.edges, second.edges) {
            #expect(x.id.importID != y.id.importID)
            #expect(x.id.bodyID == y.id.bodyID && x.id.entityID == y.id.entityID)
            #expect(x.points == y.points && x.kind == y.kind)
        }
    }

    @Test func edgesComeOutByBodyThenEntityNumber() throws {
        let b = StepBuilder()
        let model = try STEP.read(data: severalBodies(b))
        #expect(model.bodies.count == 3)
        // Grouped by body, in the order the bodies are listed.
        let order = model.bodies.map(\.id)
        var lastBody = -1
        var lastEntity = -1
        for edge in model.edges {
            let body = try #require(order.firstIndex(of: edge.id.bodyID))
            #expect(body >= lastBody)
            if body == lastBody { #expect(edge.id.entityID > lastEntity, "ascending within a body") }
            lastBody = body
            lastEntity = edge.id.entityID
        }
        #expect(model.edges.count == 12 + 12 + 1)
    }

    // MARK: Bounds

    @Test func theModelBoundsAreTheUnionOfEveryBodyAcrossZero() throws {
        let b = StepBuilder()
        let model = try STEP.read(data: severalBodies(b))
        let first = try #require(model.bodies[0].bounds)
        let second = try #require(model.bodies[1].bounds)
        let third = try #require(model.bodies[2].bounds)
        #expect(close(first.min, SIMD3(-50, -20, -5)) && close(first.max, SIMD3(-40, -10, 5)))
        #expect(close(second.min, SIMD3(100, 30, 0)) && close(second.max, SIMD3(105, 35, 5)))
        #expect(close(third.min, SIMD3(-5, -5, 0), 1e-6) && close(third.max, SIMD3(5, 5, 0), 1e-6))

        let all = try #require(model.bounds)
        #expect(close(all.min, SIMD3(-50, -20, -5)) && close(all.max, SIMD3(105, 35, 5)))
        #expect(close(all.size, SIMD3(155, 55, 10)))
        // A viewer places the part like a workpiece: lowest X and Y, top of Z.
        #expect(close(all.workpieceOrigin, SIMD3(-50, -20, 5)))
    }

    @Test func boundsGrowToCoverEveryPointAdded() {
        var bounds = STEP.Bounds(min: SIMD3(1, 1, 1), max: SIMD3(2, 2, 2))
        bounds.include(SIMD3(0, 5, 1.5))
        bounds.include(SIMD3(1.5, 1.5, 9))
        #expect(close(bounds.min, SIMD3(0, 1, 1)) && close(bounds.max, SIMD3(2, 5, 9)))
    }
}
