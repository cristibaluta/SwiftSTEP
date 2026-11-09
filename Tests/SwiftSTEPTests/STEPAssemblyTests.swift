import Testing
import Foundation
import simd
@testable import SwiftSTEP

// Fixtures are tiny Part 21 files: each part is one wireframe polyline (0,0,0) to (10,0,0), so a
// placed body's two edge points show exactly where the placement put it.

private final class AssemblyFile {
    private var lines: [String] = []
    private var next = 1

    @discardableResult
    func add(_ body: String) -> Int {
        let id = next
        next += 1
        lines.append("#\(id)=\(body);")
        return id
    }

    func context(inch: Bool = false) -> Int {
        let mm = add("( LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.) )")
        let rad = add("( NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.) )")
        var length = mm
        if inch {
            let dim = add("DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.)")
            let measure = add("LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),#\(mm))")
            length = add("( CONVERSION_BASED_UNIT('INCH',#\(measure)) LENGTH_UNIT() NAMED_UNIT(#\(dim)) )")
        }
        return add("( GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNIT_ASSIGNED_CONTEXT((#\(length),#\(rad))) REPRESENTATION_CONTEXT('c','3D') )")
    }

    func axis(_ origin: SIMD3<Double>, z: SIMD3<Double> = SIMD3(0, 0, 1), x: SIMD3<Double> = SIMD3(1, 0, 0)) -> Int {
        let p = add("CARTESIAN_POINT('',(\(origin.x),\(origin.y),\(origin.z)))")
        let dz = add("DIRECTION('',(\(z.x),\(z.y),\(z.z)))")
        let dx = add("DIRECTION('',(\(x.x),\(x.y),\(x.z)))")
        return add("AXIS2_PLACEMENT_3D('',#\(p),#\(dz),#\(dx))")
    }

    struct Product { var definition: Int; var shape: Int }

    func product(_ name: String) -> Product {
        let prod = add("PRODUCT('\(name)','\(name)','',())")
        let formation = add("PRODUCT_DEFINITION_FORMATION('','',#\(prod))")
        let definition = add("PRODUCT_DEFINITION('design','',#\(formation),$)")
        return Product(definition: definition, shape: add("PRODUCT_DEFINITION_SHAPE('','',#\(definition))"))
    }

    /// A part: a wire body and an axis at its origin. Returns (representation, origin axis, product).
    func part(_ name: String, context: Int) -> (rep: Int, axis: Int, product: Product) {
        let a = add("CARTESIAN_POINT('',(0.,0.,0.))")
        let b = add("CARTESIAN_POINT('',(10.,0.,0.))")
        let curve = add("POLYLINE('',(#\(a),#\(b)))")
        let set = add("GEOMETRIC_CURVE_SET('\(name)',(#\(curve)))")
        let origin = axis(.zero)
        let rep = add("GEOMETRICALLY_BOUNDED_WIREFRAME_SHAPE_REPRESENTATION('',(#\(origin),#\(set)),#\(context))")
        let product = product(name)
        add("SHAPE_DEFINITION_REPRESENTATION(#\(product.shape),#\(rep))")
        return (rep, origin, product)
    }

    func assembly(_ name: String, context: Int) -> (rep: Int, axis: Int, product: Product) {
        let origin = axis(.zero)
        let rep = add("SHAPE_REPRESENTATION('\(name)',(#\(origin)),#\(context))")
        let product = product(name)
        add("SHAPE_DEFINITION_REPRESENTATION(#\(product.shape),#\(rep))")
        return (rep, origin, product)
    }

    func usage(_ name: String, parent: (rep: Int, axis: Int, product: Product), child: (rep: Int, axis: Int, product: Product),
               at placed: Int, swapped: Bool = false) {
        let n = add("NEXT_ASSEMBLY_USAGE_OCCURRENCE('\(name)','\(name)','',#\(parent.product.definition),#\(child.product.definition),$)")
        let shape = add("PRODUCT_DEFINITION_SHAPE('','',#\(n))")
        let idt = add("ITEM_DEFINED_TRANSFORMATION('','',#\(child.axis),#\(placed))")
        let reps = swapped ? "#\(parent.rep),#\(child.rep)" : "#\(child.rep),#\(parent.rep)"
        let relation = add("( REPRESENTATION_RELATIONSHIP('','',\(reps)) REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#\(idt)) SHAPE_REPRESENTATION_RELATIONSHIP() )")
        add("CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#\(relation),#\(shape))")
    }

    func data() -> Data {
        Data(("ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('t'),'2;1');\nFILE_NAME('t.step','2026-01-01T00:00:00',(''),(''),'','','');\n"
              + "FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\nENDSEC;\nDATA;\n" + lines.joined(separator: "\n")
              + "\nENDSEC;\nEND-ISO-10303-21;\n").utf8)
    }
}

private func endPoints(_ body: STEP.Body) -> [SIMD3<Double>] {
    body.edges.flatMap { [$0.points.first!, $0.points.last!] }
}

private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_distance(a, b) < 1e-9 }

@Suite("Assemblies and multiple bodies")
struct STEPAssemblyTests {

    @Test func aFileOfSeveralBodiesIsAnArrayOfUnplacedBodies() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        _ = f.part("A", context: ctx)
        _ = f.part("B", context: ctx)
        let bodies = try STEP.readBodies(data: f.data(), includeSurfaces: false)
        #expect(bodies.count == 2)
        #expect(Set(bodies.map { $0.id }).count == 2)
        #expect(bodies.allSatisfy { $0.path.isEmpty && $0.id.instance == 0 })
        let assembly = try STEP.readAssembly(data: f.data(), includeSurfaces: false)
        #expect(assembly.placementCount == 0)
        #expect(!assembly.diagnostics.contains { $0.code.hasPrefix("assembly-") })
    }

    @Test func aPlacementMovesTheBodyAndRecordsItsTransform() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        f.usage("left", parent: top, child: part, at: f.axis(SIMD3(100, 5, 0)))
        let bodies = try STEP.readBodies(data: f.data(), includeSurfaces: false)
        let body = try #require(bodies.first)
        #expect(bodies.count == 1)
        #expect(body.path == ["left"])
        let points = endPoints(body)
        #expect(close(points[0], SIMD3(100, 5, 0)) && close(points[1], SIMD3(110, 5, 0)))
        #expect(close(SIMD3(body.transform.columns.3.x, body.transform.columns.3.y, body.transform.columns.3.z), SIMD3(100, 5, 0)))
        #expect(close(body.bounds!.min, SIMD3(100, 5, 0)))
    }

    @Test func aPartUsedTwiceIsTwoBodiesWithDistinctIDs() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        f.usage("one", parent: top, child: part, at: f.axis(SIMD3(0, 20, 0)))
        f.usage("two", parent: top, child: part, at: f.axis(SIMD3(0, 40, 0)))
        let bodies = try STEP.readBodies(data: f.data(), includeSurfaces: false)
        #expect(bodies.count == 2)
        #expect(Set(bodies.map { $0.id }).count == 2)
        #expect(Set(bodies.map { $0.id.instance }) == [0, 1])
        #expect(Set(bodies.flatMap { $0.edges.map { $0.id } }).count == 2)
        let ys = bodies.map { endPoints($0)[0].y }.sorted()
        #expect(ys == [20, 40])
    }

    @Test func aRotationTurnsThePart() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        // The part's x axis becomes the assembly's y axis.
        f.usage("turned", parent: top, child: part, at: f.axis(SIMD3(5, 5, 0), x: SIMD3(0, 1, 0)))
        let points = endPoints(try #require(try STEP.readBodies(data: f.data(), includeSurfaces: false).first))
        #expect(close(points[0], SIMD3(5, 5, 0)) && close(points[1], SIMD3(5, 15, 0)))
    }

    @Test func subAssembliesNest() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let sub = f.assembly("Sub", context: ctx)
        let top = f.assembly("Top", context: ctx)
        f.usage("in sub", parent: sub, child: part, at: f.axis(SIMD3(10, 0, 0)))
        f.usage("sub", parent: top, child: sub, at: f.axis(SIMD3(0, 0, 7), x: SIMD3(0, 1, 0)))
        let body = try #require(try STEP.readBodies(data: f.data(), includeSurfaces: false).first)
        #expect(body.path == ["sub", "in sub"])
        // (0,0,0) -> (10,0,0) in sub -> turned a quarter about z and lifted 7.
        let points = endPoints(body)
        #expect(close(points[0], SIMD3(0, 10, 7)) && close(points[1], SIMD3(0, 20, 7)))
    }

    @Test func translationsUseTheUnitOfTheirOwnRepresentation() throws {
        let f = AssemblyFile()
        let part = f.part("Part", context: f.context())
        let top = f.assembly("Top", context: f.context(inch: true))
        f.usage("moved", parent: top, child: part, at: f.axis(SIMD3(2, 0, 0)))
        let points = endPoints(try #require(try STEP.readBodies(data: f.data(), includeSurfaces: false).first))
        #expect(close(points[0], SIMD3(50.8, 0, 0)) && close(points[1], SIMD3(60.8, 0, 0)))
    }

    @Test func aUsageWrittenWithTheRepresentationsSwappedStillPlacesTheChild() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        // rep_1 is the parent here; the product structure says which one is the child.
        f.usage("swapped", parent: top, child: part, at: f.axis(.zero), swapped: true)
        let body = try #require(try STEP.readBodies(data: f.data(), includeSurfaces: false).first)
        #expect(body.path == ["swapped"])
    }

    @Test func mappedItemsPlacePartsInTheContainingRepresentationsUnit() throws {
        let f = AssemblyFile()
        let part = f.part("Part", context: f.context())
        let inch = f.context(inch: true)
        let map = f.add("REPRESENTATION_MAP(#\(part.axis),#\(part.rep))")
        let item = f.add("MAPPED_ITEM('mapped',#\(map),#\(f.axis(SIMD3(1, 0, 0))))")
        f.add("SHAPE_REPRESENTATION('Top',(#\(f.axis(.zero)),#\(item)),#\(inch))")
        let assembly = try STEP.readAssembly(data: f.data(), includeSurfaces: false)
        let body = try #require(assembly.bodies.first)
        #expect(assembly.bodies.count == 1 && assembly.placementCount == 1)
        #expect(body.path == ["mapped"])
        #expect(close(endPoints(body)[0], SIMD3(25.4, 0, 0)))
        #expect(!assembly.diagnostics.contains { $0.code == "assembly-untransformed" })
    }

    @Test func aPartPlacedInsideItselfDoesNotLoop() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let top = f.assembly("Top", context: ctx)
        let part = f.part("Part", context: ctx)
        f.usage("self", parent: part, child: part, at: f.axis(SIMD3(1, 0, 0)))
        f.usage("ok", parent: top, child: part, at: f.axis(SIMD3(0, 3, 0)))
        let assembly = try STEP.readAssembly(data: f.data(), includeSurfaces: false)
        #expect(assembly.bodies.count == 1)
        #expect(assembly.diagnostics.contains { $0.code == "assembly-cycle" })
    }

    @Test func theInstanceCapStopsTheExpansion() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        for i in 0..<5 { f.usage("u\(i)", parent: top, child: part, at: f.axis(SIMD3(Double(i) * 20, 0, 0))) }
        let assembly = try STEP.readAssembly(data: f.data(), options: STEP.Options(maximumInstanceCount: 3), includeSurfaces: false)
        #expect(assembly.bodies.count == 3)
        #expect(assembly.diagnostics.contains { $0.code == "instance-limit" })
    }

    @Test func theOlderEntryPointsStillImportAssembliesUntransformed() throws {
        let f = AssemblyFile()
        let ctx = f.context()
        let part = f.part("Part", context: ctx)
        let top = f.assembly("Top", context: ctx)
        f.usage("moved", parent: top, child: part, at: f.axis(SIMD3(100, 0, 0)))
        let model = try STEP.read(data: f.data())
        #expect(model.edges.count == 1 && close(model.edges[0].points[0], .zero))
        #expect(model.diagnostics.contains { $0.code == "assembly-untransformed" })
    }

    // MARK: Moving geometry

    @Test func surfacesFollowAPlacement() throws {
        let rotated = try #require(STEPPlacement(STEPPlacement.matrix(origin: SIMD3(1, 2, 3), x: SIMD3(0, 1, 0),
                                                                      y: SIMD3(-1, 0, 0), z: SIMD3(0, 0, 1), scale: 2)))
        let frame = STEP.Frame(origin: SIMD3(1, 0, 0), x: SIMD3(1, 0, 0), y: SIMD3(0, 1, 0), z: SIMD3(0, 0, 1))
        guard case .cylinder(let moved, let radius) = STEP.Surface.cylinder(frame, radius: 4).transformed(by: rotated) else {
            Issue.record("not a cylinder"); return
        }
        #expect(radius == 8)
        #expect(close(moved.origin, SIMD3(1, 4, 3)) && close(moved.x, SIMD3(0, 1, 0)) && close(moved.y, SIMD3(-1, 0, 0)))
    }

    @Test func meshesFollowAPlacementAndKeepTheirOutwardNormals() throws {
        let id = STEP.BodyID(representationID: 1, entityID: 2)
        var mesh = STEP.BodyMesh(id: id)
        mesh.positions = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        mesh.normals = Array(repeating: SIMD3<Float>(0, 0, 1), count: 3)
        mesh.indices = [0, 1, 2]
        let placement = try #require(STEPPlacement(STEPPlacement.matrix(origin: SIMD3(10, 0, 0), x: SIMD3(0, 1, 0),
                                                                        y: SIMD3(-1, 0, 0), z: SIMD3(0, 0, 1))))
        let moved = mesh.placed(by: placement, as: STEP.BodyID(representationID: 1, entityID: 2, instance: 1),
                                from: SIMD3(5, 0, 0), to: SIMD3(2, 0, 0))
        // (0,0,0) relative to (5,0,0) is the point (5,0,0); turned and moved it is (10,5,0); relative to (2,0,0): (8,5,0).
        #expect(moved.positions[0] == SIMD3<Float>(8, 5, 0))
        #expect(moved.normals[0] == SIMD3<Float>(0, 0, 1))
        #expect(moved.id.instance == 1 && moved.indices == [0, 1, 2])
    }

    @Test func placementsThatAreNotRigidAreRefused() {
        let skewed = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(1, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        #expect(STEPPlacement(skewed) == nil)
        let mirrored = simd_double4x4(columns: (SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        #expect(STEPPlacement(mirrored) == nil)
        #expect(STEPPlacement(matrix_identity_double4x4)?.isIdentity == true)
    }
}
