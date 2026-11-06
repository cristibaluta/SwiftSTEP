import Testing
import Foundation
import simd
@testable import SwiftSTEP

// MARK: - Fixture

/// A quarter-disc prism, radius 10 mm, height 4 mm: two planar caps, two planar walls and one
/// curved wall on a B-spline surface. The wall is either the exact rational circle (weights
/// 1, √½, 1) in the complex record layout, or a plain parabola in the simple 13-parameter
/// layout. Volumes: π·100/4·4 for the circle, 1000/3 for the parabola.
///
/// The text was generated and checked against an independent port of the tessellation
/// (all faces tessellate, outward normals, volumes within 0.05 %).
private enum QuarterDisc {
    static func data(rational: Bool, edits: [(String, String)] = []) -> Data {
        func curve(_ a: Int, _ b: Int, _ c: Int) -> String {
            rational
                ? "( BOUNDED_CURVE() B_SPLINE_CURVE(2,(#\(a),#\(b),#\(c)),.UNSPECIFIED.,.F.,.F.) "
                    + "B_SPLINE_CURVE_WITH_KNOTS((3,3),(0.0,1.0),.UNSPECIFIED.) CURVE() GEOMETRIC_REPRESENTATION_ITEM() "
                    + "RATIONAL_B_SPLINE_CURVE((1.0,0.7071067811865476,1.0)) REPRESENTATION_ITEM('') )"
                : "B_SPLINE_CURVE_WITH_KNOTS('',2,(#\(a),#\(b),#\(c)),.UNSPECIFIED.,.F.,.F.,(3,3),(0.0,1.0),.UNSPECIFIED.)"
        }
        let surface = rational
            ? "( BOUNDED_SURFACE() B_SPLINE_SURFACE(2,1,((#58,#59),(#60,#61),(#62,#63)),.UNSPECIFIED.,.F.,.F.,.F.) "
                + "B_SPLINE_SURFACE_WITH_KNOTS((3,3),(2,2),(0.0,1.0),(0.0,4.0),.UNSPECIFIED.) GEOMETRIC_REPRESENTATION_ITEM() "
                + "RATIONAL_B_SPLINE_SURFACE(((1.,1.),(0.7071067811865476,0.7071067811865476),(1.,1.))) "
                + "REPRESENTATION_ITEM('') SURFACE() )"
            : "B_SPLINE_SURFACE_WITH_KNOTS('',2,1,((#58,#59),(#60,#61),(#62,#63)),.UNSPECIFIED.,.F.,.F.,.F.,"
                + "(3,3),(2,2),(0.0,1.0),(0.0,4.0),.UNSPECIFIED.)"
        var text = """
        ISO-10303-21;
        HEADER;
        FILE_DESCRIPTION(('quarter disc prism'),'2;1');
        FILE_NAME('t.step','2026-01-01T00:00:00',(''),(''),'','','');
        FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
        ENDSEC;
        DATA;
        #1=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #2=VERTEX_POINT('',#1);
        #3=CARTESIAN_POINT('',(10.0,0.0,0.0));
        #4=VERTEX_POINT('',#3);
        #5=CARTESIAN_POINT('',(0.0,10.0,0.0));
        #6=VERTEX_POINT('',#5);
        #7=CARTESIAN_POINT('',(0.0,0.0,4.0));
        #8=VERTEX_POINT('',#7);
        #9=CARTESIAN_POINT('',(10.0,0.0,4.0));
        #10=VERTEX_POINT('',#9);
        #11=CARTESIAN_POINT('',(0.0,10.0,4.0));
        #12=VERTEX_POINT('',#11);
        #13=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #14=DIRECTION('',(1.0,0.0,0.0));
        #15=VECTOR('',#14,10.0);
        #16=LINE('',#13,#15);
        #17=EDGE_CURVE('',#2,#4,#16,.T.);
        #18=CARTESIAN_POINT('',(10.0,0.0,0.0));
        #19=CARTESIAN_POINT('',(10.0,10.0,0.0));
        #20=CARTESIAN_POINT('',(0.0,10.0,0.0));
        #21=\(curve(18, 19, 20));
        #22=EDGE_CURVE('',#4,#6,#21,.T.);
        #23=CARTESIAN_POINT('',(0.0,10.0,0.0));
        #24=DIRECTION('',(0.0,-1.0,0.0));
        #25=VECTOR('',#24,10.0);
        #26=LINE('',#23,#25);
        #27=EDGE_CURVE('',#6,#2,#26,.T.);
        #28=CARTESIAN_POINT('',(0.0,0.0,4.0));
        #29=DIRECTION('',(1.0,0.0,0.0));
        #30=VECTOR('',#29,10.0);
        #31=LINE('',#28,#30);
        #32=EDGE_CURVE('',#8,#10,#31,.T.);
        #33=CARTESIAN_POINT('',(10.0,0.0,4.0));
        #34=CARTESIAN_POINT('',(10.0,10.0,4.0));
        #35=CARTESIAN_POINT('',(0.0,10.0,4.0));
        #36=\(curve(33, 34, 35));
        #37=EDGE_CURVE('',#10,#12,#36,.T.);
        #38=CARTESIAN_POINT('',(0.0,10.0,4.0));
        #39=DIRECTION('',(0.0,-1.0,0.0));
        #40=VECTOR('',#39,10.0);
        #41=LINE('',#38,#40);
        #42=EDGE_CURVE('',#12,#8,#41,.T.);
        #43=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #44=DIRECTION('',(0.0,0.0,1.0));
        #45=VECTOR('',#44,4.0);
        #46=LINE('',#43,#45);
        #47=EDGE_CURVE('',#2,#8,#46,.T.);
        #48=CARTESIAN_POINT('',(10.0,0.0,0.0));
        #49=DIRECTION('',(0.0,0.0,1.0));
        #50=VECTOR('',#49,4.0);
        #51=LINE('',#48,#50);
        #52=EDGE_CURVE('',#4,#10,#51,.T.);
        #53=CARTESIAN_POINT('',(0.0,10.0,0.0));
        #54=DIRECTION('',(0.0,0.0,1.0));
        #55=VECTOR('',#54,4.0);
        #56=LINE('',#53,#55);
        #57=EDGE_CURVE('',#6,#12,#56,.T.);
        #58=CARTESIAN_POINT('',(10.0,0.0,0.0));
        #59=CARTESIAN_POINT('',(10.0,0.0,4.0));
        #60=CARTESIAN_POINT('',(10.0,10.0,0.0));
        #61=CARTESIAN_POINT('',(10.0,10.0,4.0));
        #62=CARTESIAN_POINT('',(0.0,10.0,0.0));
        #63=CARTESIAN_POINT('',(0.0,10.0,4.0));
        #64=\(surface);
        #65=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #66=DIRECTION('',(0.0,0.0,1.0));
        #67=DIRECTION('',(1.0,0.0,0.0));
        #68=AXIS2_PLACEMENT_3D('',#65,#66,#67);
        #69=PLANE('',#68);
        #70=ORIENTED_EDGE('',*,*,#27,.F.);
        #71=ORIENTED_EDGE('',*,*,#22,.F.);
        #72=ORIENTED_EDGE('',*,*,#17,.F.);
        #73=EDGE_LOOP('',(#70,#71,#72));
        #74=FACE_OUTER_BOUND('',#73,.T.);
        #75=ADVANCED_FACE('',(#74),#69,.F.);
        #76=CARTESIAN_POINT('',(0.0,0.0,4.0));
        #77=DIRECTION('',(0.0,0.0,1.0));
        #78=DIRECTION('',(1.0,0.0,0.0));
        #79=AXIS2_PLACEMENT_3D('',#76,#77,#78);
        #80=PLANE('',#79);
        #81=ORIENTED_EDGE('',*,*,#32,.T.);
        #82=ORIENTED_EDGE('',*,*,#37,.T.);
        #83=ORIENTED_EDGE('',*,*,#42,.T.);
        #84=EDGE_LOOP('',(#81,#82,#83));
        #85=FACE_OUTER_BOUND('',#84,.T.);
        #86=ADVANCED_FACE('',(#85),#80,.T.);
        #87=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #88=DIRECTION('',(0.0,-1.0,0.0));
        #89=DIRECTION('',(1.0,0.0,0.0));
        #90=AXIS2_PLACEMENT_3D('',#87,#88,#89);
        #91=PLANE('',#90);
        #92=ORIENTED_EDGE('',*,*,#17,.T.);
        #93=ORIENTED_EDGE('',*,*,#52,.T.);
        #94=ORIENTED_EDGE('',*,*,#32,.F.);
        #95=ORIENTED_EDGE('',*,*,#47,.F.);
        #96=EDGE_LOOP('',(#92,#93,#94,#95));
        #97=FACE_OUTER_BOUND('',#96,.T.);
        #98=ADVANCED_FACE('',(#97),#91,.T.);
        #99=CARTESIAN_POINT('',(0.0,0.0,0.0));
        #100=DIRECTION('',(-1.0,0.0,0.0));
        #101=DIRECTION('',(0.0,1.0,0.0));
        #102=AXIS2_PLACEMENT_3D('',#99,#100,#101);
        #103=PLANE('',#102);
        #104=ORIENTED_EDGE('',*,*,#27,.T.);
        #105=ORIENTED_EDGE('',*,*,#47,.T.);
        #106=ORIENTED_EDGE('',*,*,#42,.F.);
        #107=ORIENTED_EDGE('',*,*,#57,.F.);
        #108=EDGE_LOOP('',(#104,#105,#106,#107));
        #109=FACE_OUTER_BOUND('',#108,.T.);
        #110=ADVANCED_FACE('',(#109),#103,.T.);
        #111=ORIENTED_EDGE('',*,*,#22,.T.);
        #112=ORIENTED_EDGE('',*,*,#57,.T.);
        #113=ORIENTED_EDGE('',*,*,#37,.F.);
        #114=ORIENTED_EDGE('',*,*,#52,.F.);
        #115=EDGE_LOOP('',(#111,#112,#113,#114));
        #116=FACE_OUTER_BOUND('',#115,.T.);
        #117=ADVANCED_FACE('',(#116),#64,.T.);
        #118=CLOSED_SHELL('',(#75,#86,#98,#110,#117));
        #119=MANIFOLD_SOLID_BREP('',#118);
        #120=( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) );
        #121=( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) );
        #122=( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#120,#121)) REPRESENTATION_CONTEXT('ctx','3D') );
        #123=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#119),#122);
        ENDSEC;
        END-ISO-10303-21;

        """
        for (old, new) in edits { text = text.replacingOccurrences(of: old, with: new) }
        return Data(text.utf8)
    }
}

// MARK: - Helpers

/// Volume enclosed by a closed mesh (divergence theorem), independent of the display origin.
private func signedVolume(_ mesh: STEP.BodyMesh) -> Double {
    var volume = 0.0
    for triangle in 0..<mesh.triangleCount {
        let a = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * triangle])])
        let b = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * triangle + 1])])
        let c = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * triangle + 2])])
        volume += simd_dot(a, simd_cross(b, c)) / 6
    }
    return volume
}

private func isFreeform(_ face: STEP.FaceMesh) -> Bool {
    if case .bspline = face.surface { return true }
    return false
}

private func quarterCircleSurface() throws -> STEP.BSplineSurface {
    let w = 0.5.squareRoot()
    return try STEP.BSplineSurface(
        uDegree: 2, vDegree: 1,
        controlPoints: [[SIMD3(10, 0, 0), SIMD3(10, 0, 4)],
                        [SIMD3(10, 10, 0), SIMD3(10, 10, 4)],
                        [SIMD3(0, 10, 0), SIMD3(0, 10, 4)]],
        weights: [[1, 1], [w, w], [1, 1]],
        uMultiplicities: [3, 3], uKnotValues: [0, 1], vMultiplicities: [2, 2], vKnotValues: [0, 4])
}

// MARK: - Surface

@Suite struct BSplineSurfaceTests {
    @Test func rationalSurfaceStaysOnTheTrueCylinderWithOutwardNormals() throws {
        let surface = try quarterCircleSurface()
        for step in 0...20 {
            let u = Double(step) / 20
            for v in [0.0, 1.5, 4.0] {
                let p = surface.point(u: u, v: v)
                #expect(abs(hypot(p.x, p.y) - 10) < 1e-9)
                #expect(abs(p.z - v) < 1e-9)
                // ∂P/∂u × ∂P/∂v is the STEP normal: radially outward here.
                #expect(simd_distance(surface.normal(u: u, v: v), SIMD3(p.x, p.y, 0) / 10) < 1e-6)
            }
        }
    }

    @Test func projectionRecoversParametersAndSnapsToTheDomainEnds() throws {
        let surface = try quarterCircleSurface()
        for (u, v) in [(0.13, 0.4), (0.5, 2.0), (0.87, 3.7), (0.31, 1.1)] {
            let found = surface.parameters(of: surface.point(u: u, v: v))
            #expect(found.distance < 1e-9)
            #expect(abs(found.u - u) < 1e-7)
            #expect(abs(found.v - v) < 1e-7)
        }
        let corner = surface.parameters(of: SIMD3(10, 0, 4))
        #expect(corner.u == 0 && corner.v == 4)
        let far = surface.parameters(of: SIMD3(30, 30, 2))
        #expect(far.distance > 10)
    }

    @Test func divisionsFollowTheCurvatureNotTheNetSize() throws {
        let surface = try quarterCircleSurface()
        let divisions = surface.divisions(tolerance: 0.01)
        #expect(divisions.u > 2)
        #expect(divisions.v == 1)
    }

    @Test func surfacesThatCloseOnThemselvesOrCollapseAreRefused() throws {
        let closed = try STEP.BSplineSurface(
            uDegree: 2, vDegree: 1,
            controlPoints: [[SIMD3(0, 0, 0), SIMD3(0, 0, 4)],
                            [SIMD3(10, 5, 0), SIMD3(10, 5, 4)],
                            [SIMD3(0, 0, 0), SIMD3(0, 0, 4)]],
            weights: nil, uMultiplicities: [3, 3], uKnotValues: [0, 1], vMultiplicities: [2, 2], vKnotValues: [0, 4])
        #expect(closed.limitation?.contains("closes on itself in u") == true)

        let collapsed = try STEP.BSplineSurface(
            uDegree: 2, vDegree: 1,
            controlPoints: [[SIMD3(0, 0, 0), SIMD3(10, 0, 0)],
                            [SIMD3(0, 0, 0), SIMD3(10, 5, 2)],
                            [SIMD3(0, 0, 0), SIMD3(0, 10, 0)]],
            weights: nil, uMultiplicities: [3, 3], uKnotValues: [0, 1], vMultiplicities: [2, 2], vKnotValues: [0, 1])
        #expect(collapsed.limitation?.contains("collapsed") == true)

        #expect(try quarterCircleSurface().limitation == nil)
    }

    @Test func malformedKnotsAreRejected() {
        // Two knots of multiplicity 3 need 6 knots for 3 control points of degree 2: ok above.
        // Here v claims multiplicity 3 at the ends of a degree-1 direction.
        #expect(throws: STEP.ParseError.self) {
            try STEP.BSplineSurface(
                uDegree: 2, vDegree: 1,
                controlPoints: [[SIMD3(0, 0, 0), SIMD3(0, 0, 1)], [SIMD3(1, 0, 0), SIMD3(1, 0, 1)],
                                [SIMD3(2, 0, 0), SIMD3(2, 0, 1)]],
                weights: nil, uMultiplicities: [3, 3], uKnotValues: [0, 1],
                vMultiplicities: [3, 3], vKnotValues: [0, 1])
        }
    }
}

// MARK: - Importer

@Suite struct FreeformSolidTests {
    private func volumeAndWall(rational: Bool) throws -> (geometry: STEP.Geometry, volume: Double, wall: STEP.FaceMesh, mesh: STEP.BodyMesh) {
        let geometry = try STEP.readGeometry(data: QuarterDisc.data(rational: rational))
        let mesh = try #require(geometry.surfaces.bodies.first)
        let wall = try #require(mesh.faces.first(where: isFreeform))
        return (geometry, signedVolume(mesh), wall, mesh)
    }

    @Test func solidWithRationalCircularWallGetsASurface() throws {
        let (geometry, volume, wall, mesh) = try volumeAndWall(rational: true)
        #expect(geometry.edges.skippedEdgeCount == 0)
        #expect(geometry.surfaces.unsurfacedBodies.isEmpty)
        #expect(geometry.surfaces.failedFaceCount == 0)
        #expect(geometry.surfaces.tessellatedFaceCount == 5)

        let exact = Double.pi * 100 / 4 * 4
        #expect(abs(volume - exact) < 0.005 * exact)

        // Every vertex of the curved wall is on the true circle, every triangle faces outward.
        let origin = geometry.surfaces.origin
        for triangle in wall.triangles {
            var centroid = SIMD3<Double>.zero
            var corners: [SIMD3<Double>] = []
            for corner in 0..<3 {
                let p = SIMD3<Double>(mesh.positions[Int(mesh.indices[3 * triangle + corner])]) + origin
                #expect(abs(hypot(p.x, p.y) - 10) < 1e-4)
                corners.append(p)
                centroid += p / 3
            }
            let normal = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
            #expect(simd_dot(normal, SIMD3(centroid.x, centroid.y, 0)) > 0)
        }
    }

    @Test func solidWithPlainParabolicWallInTheSimpleRecordLayoutGetsASurface() throws {
        let (geometry, volume, _, _) = try volumeAndWall(rational: false)
        #expect(geometry.surfaces.unsurfacedBodies.isEmpty)
        #expect(geometry.surfaces.tessellatedFaceCount == 5)
        #expect(abs(volume - 1000.0 / 3) < 0.005 * 1000.0 / 3)
    }

    @Test func unsupportedSweptSurfaceStillDropsTheBodyAndIsNamed() throws {
        let data = QuarterDisc.data(rational: false, edits: [
            ("B_SPLINE_SURFACE_WITH_KNOTS('',2,1,", "SURFACE_OF_LINEAR_EXTRUSION('',2,1,")])
        let geometry = try STEP.readGeometry(data: data)
        #expect(geometry.edges.edges.count == 9)
        #expect(geometry.surfaces.bodies.isEmpty)
        #expect(geometry.surfaces.unsurfacedBodies.count == 1)
        #expect(geometry.surfaces.diagnostics.contains { $0.message.contains("SURFACE_OF_LINEAR_EXTRUSION") })
    }

    @Test func boundaryThatLeavesTheSurfaceIsRefusedInsteadOfMeshedWrongly() throws {
        // Weights of 1 turn the circle into a parabola, so the circular edges no longer lie on it.
        let data = QuarterDisc.data(rational: true, edits: [
            ("RATIONAL_B_SPLINE_SURFACE(((1.,1.),(0.7071067811865476,0.7071067811865476),(1.,1.)))",
             "RATIONAL_B_SPLINE_SURFACE(((1.,1.),(1.,1.),(1.,1.)))")])
        let geometry = try STEP.readGeometry(data: data)
        #expect(geometry.surfaces.bodies.isEmpty)
        #expect(geometry.surfaces.unsurfacedBodies.count == 1)
        #expect(geometry.surfaces.diagnostics.contains { $0.message.contains("off its B-spline surface") })
    }
}
