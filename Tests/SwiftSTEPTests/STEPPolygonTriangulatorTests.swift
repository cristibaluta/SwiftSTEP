import Testing
import Foundation
import simd
@testable import SwiftSTEP

// T31a: the planar triangulator on its own, in plain (u, v) numbers.

private typealias Vertex = STEPSlabTriangulator.Vertex

private func loop(_ points: [(Double, Double)]) -> [Vertex] {
    points.map { Vertex(u: $0.0, v: $0.1, position: SIMD3($0.0, $0.1, 0)) }
}

private func circle(_ centre: (Double, Double), radius: Double, count: Int, counterClockwise: Bool = true) -> [Vertex] {
    let points = (0..<count).map { i -> (Double, Double) in
        let angle = 2 * Double.pi * Double(i) / Double(count)
        return (centre.0 + radius * cos(angle), centre.1 + radius * sin(angle))
    }
    return loop(counterClockwise ? points : points.reversed())
}

private func area(_ result: STEPSlabTriangulator.Result, _ triangle: SIMD3<Int>) -> Double {
    let a = result.vertices[triangle.x], b = result.vertices[triangle.y], c = result.vertices[triangle.z]
    return ((b.u - a.u) * (c.v - a.v) - (c.u - a.u) * (b.v - a.v)) / 2
}

private func totalArea(_ result: STEPSlabTriangulator.Result) -> Double {
    result.triangles.reduce(0) { $0 + area(result, $1) }
}

private let limit = 1_000_000

@Suite("STEP planar polygon triangulator")
struct STEPPolygonTriangulatorTests {

    @Test func aSquareIsTwoTriangles() throws {
        let result = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (10, 0), (10, 10), (0, 10)]),
                                                            holes: [], triangleLimit: limit)
        #expect(result.triangles.count == 2)
        #expect(result.vertices.count == 4)
        #expect(abs(totalArea(result) - 100) < 1e-9)
    }

    @Test func aSquareWithASquareHoleIsEightTriangles() throws {
        let hole = loop([(3, 3), (3, 7), (7, 7), (7, 3)])
        let result = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (10, 0), (10, 10), (0, 10)]),
                                                            holes: [hole], triangleLimit: limit)
        // n + 2h - 2 with n = 8 points and one hole.
        #expect(result.triangles.count == 8)
        #expect(abs(totalArea(result) - 84) < 1e-9)
        // No point is added: every corner is one of the eight boundary points.
        #expect(result.vertices.count == 8)
        for triangle in result.triangles {
            #expect(area(result, triangle) > 0, "every triangle runs counter-clockwise")
            let centre = (result.vertices[triangle.x].u + result.vertices[triangle.y].u + result.vertices[triangle.z].u) / 3
            let middle = (result.vertices[triangle.x].v + result.vertices[triangle.y].v + result.vertices[triangle.z].v) / 3
            #expect(!(centre > 3 && centre < 7 && middle > 3 && middle < 7), "no triangle lies in the hole")
        }
    }

    @Test func theDirectionOfEachLoopDoesNotMatter() throws {
        let clockwiseOuter = loop([(0, 0), (10, 0), (10, 10), (0, 10)].reversed())
        let counterClockwiseHole = circle((5, 5), radius: 2, count: 24, counterClockwise: true)
        let result = try STEPPolygonTriangulator.triangulate(outer: clockwiseOuter, holes: [counterClockwiseHole],
                                                            triangleLimit: limit)
        #expect(result.triangles.count == 4 + 24)
        #expect(result.triangles.allSatisfy { area(result, $0) > 0 })
        let hole = abs(STEPPolygonTriangulator.signedArea(counterClockwiseHole))
        #expect(abs(totalArea(result) - (100 - hole)) < 1e-9)
    }

    @Test func aConcaveOutlineIsCoveredExactly() throws {
        let result = try STEPPolygonTriangulator.triangulate(
            outer: loop([(0, 0), (10, 0), (10, 4), (4, 4), (4, 10), (0, 10)]), holes: [], triangleLimit: limit)
        #expect(result.triangles.count == 4)
        #expect(abs(totalArea(result) - 64) < 1e-9)
        #expect(result.triangles.allSatisfy { area(result, $0) > 0 })
    }

    @Test func aHoleThatTouchesTheOutlineAlongAnEdgeStillCoversTheRest() throws {
        let hole = loop([(0, 3), (3, 3), (3, 7), (0, 7)])
        let result = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (10, 0), (10, 10), (0, 10)]),
                                                            holes: [hole], triangleLimit: limit)
        #expect(abs(totalArea(result) - 88) < 1e-9)
    }

    @Test func triangleCountGrowsLinearlyWithTheNumberOfHoles() throws {
        // 10 x 10 holes of 32 points in a plate: n = 4 + 3200 points, h = 100 holes.
        var holes: [[Vertex]] = []
        for i in 0..<10 {
            for j in 0..<10 {
                holes.append(circle((5 + 10 * Double(i), 5 + 10 * Double(j)), radius: 2, count: 32))
            }
        }
        let result = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (100, 0), (100, 100), (0, 100)]),
                                                            holes: holes, triangleLimit: limit)
        let points = 4 + 100 * 32
        #expect(result.triangles.count == points + 2 * 100 - 2)
        #expect(result.vertices.count == points)
        let holeArea = holes.reduce(0) { $0 + abs(STEPPolygonTriangulator.signedArea($1)) }
        #expect(abs(totalArea(result) - (10_000 - holeArea)) < 1e-6)
        #expect(result.triangles.allSatisfy { area(result, $0) > 0 })
    }

    @Test func holesInARowAndInAColumnWork() throws {
        let row = (0..<50).map { circle((5 + 10 * Double($0), 5), radius: 2, count: 16) }
        let wide = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (500, 0), (500, 10), (0, 10)]),
                                                          holes: row, triangleLimit: limit)
        #expect(wide.triangles.count == 4 + 50 * 16 + 2 * 50 - 2)
        let column = (0..<50).map { circle((5, 5 + 10 * Double($0)), radius: 2, count: 16) }
        let tall = try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (10, 0), (10, 500), (0, 500)]),
                                                          holes: column, triangleLimit: limit)
        #expect(tall.triangles.count == 4 + 50 * 16 + 2 * 50 - 2)
    }

    @Test func aFaceFarFromTheOriginKeepsItsShape() throws {
        let far = 1.0e6
        let hole = loop([(far + 3, far + 3), (far + 3, far + 7), (far + 7, far + 7), (far + 7, far + 3)])
        let result = try STEPPolygonTriangulator.triangulate(
            outer: loop([(far, far), (far + 10, far), (far + 10, far + 10), (far, far + 10)]),
            holes: [hole], triangleLimit: limit)
        #expect(result.triangles.count == 8)
        #expect(abs(totalArea(result) - 84) < 1e-4)
    }

    @Test func loopsThatCrossOrOverlapAreRefusedNotMisfilled() {
        let square = loop([(0, 0), (10, 0), (10, 10), (0, 10)])
        let outside = loop([(20, 3), (20, 7), (24, 7), (24, 3)])
        let crossing = loop([(8, 3), (8, 7), (14, 7), (14, 3)])
        let first = loop([(2, 2), (2, 6), (6, 6), (6, 2)])
        let second = loop([(4, 4), (4, 8), (8, 8), (8, 4)])
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: square, holes: [outside], triangleLimit: limit)
        }
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: square, holes: [crossing], triangleLimit: limit)
        }
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: square, holes: [first, second], triangleLimit: limit)
        }
    }

    @Test func aBoundaryWithoutAreaIsRefused() {
        let bowtie = loop([(0, 0), (10, 10), (10, 0), (0, 10)])
        let line = loop([(0, 0), (5, 0), (10, 0)])
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: bowtie, holes: [], triangleLimit: limit)
        }
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: line, holes: [], triangleLimit: limit)
        }
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: loop([(0, 0), (1, 0)]), holes: [], triangleLimit: limit)
        }
    }

    @Test func theTriangleLimitIsEnforced() throws {
        let square = loop([(0, 0), (10, 0), (10, 10), (0, 10)])
        #expect(throws: STEP.ParseError.self) {
            try STEPPolygonTriangulator.triangulate(outer: square, holes: [], triangleLimit: 1)
        }
        let exact = try STEPPolygonTriangulator.triangulate(outer: square, holes: [], triangleLimit: 2)
        #expect(exact.triangles.count == 2)
    }

    @Test func aPointOnAStraightRunNeverChangesTheShape() throws {
        // (5, 0) lies on the bottom edge. A triangle may use it or not; the area is the same either way.
        let result = try STEPPolygonTriangulator.triangulate(
            outer: loop([(0, 0), (5, 0), (10, 0), (10, 10), (0, 10)]), holes: [], triangleLimit: limit)
        #expect(abs(totalArea(result) - 100) < 1e-9)
        #expect((2...3).contains(result.triangles.count))
        #expect(result.triangles.allSatisfy { area(result, $0) > 0 })
    }
}
