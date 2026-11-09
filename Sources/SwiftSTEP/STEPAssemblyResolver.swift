import Foundation
import simd

/// Works out where every body of a file sits in the assembly's coordinate system.
///
/// A STEP file states an assembly in one of two ways, and this reads both:
///
/// 1. **Product structure** (AP203/AP214, what most CAD systems write): a
///    `NEXT_ASSEMBLY_USAGE_OCCURRENCE` says "product A contains product B"; a
///    `CONTEXT_DEPENDENT_SHAPE_REPRESENTATION` ties it to a `REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION`
///    whose `ITEM_DEFINED_TRANSFORMATION` gives two axis placements: the part's own origin
///    (in the part's representation) and where that origin lands in the assembly's.
/// 2. **Mapped items**: a `MAPPED_ITEM` inside the assembly's representation points to a
///    `REPRESENTATION_MAP` (the part's representation and its origin) and an axis placement (where it goes).
///
/// If a file has product-structure placements those are used and mapped items are ignored (some
/// exporters write both for the same instances); otherwise mapped items are used.
///
/// Each placement is a rotation plus a translation, with the translations converted from the unit
/// of the representation they are written in to millimetres. Placements nest: a sub-assembly's
/// parts are placed by the sub-assembly's placement and then by its parent's.
///
/// Representations that a plain `REPRESENTATION_RELATIONSHIP` / `SHAPE_REPRESENTATION_RELATIONSHIP`
/// ties together (a part's `SHAPE_REPRESENTATION` and the `ADVANCED_BREP_SHAPE_REPRESENTATION` that
/// holds its solid) are one coordinate system, treated as one "group".
///
/// Task-confined like `STEPFile`.
final class STEPAssemblyResolver {
    struct Instance {
        /// The body as the edge pass found it (instance 0, untransformed).
        let prototype: STEP.BodyID
        /// Part coordinates (millimetres) → assembly coordinates (millimetres).
        let matrix: simd_double4x4
        /// Occurrence names from the top of the assembly down to this body's part; empty for a body
        /// that is not placed by anything.
        let path: [String]
        /// 0 for the first time this body is placed, then 1, 2, …: `BodyID.instance`.
        let index: Int
    }

    struct Resolution {
        var instances: [Instance] = []
        var diagnostics: [STEP.Diagnostic] = []
        /// Placements that were read and are in use (not counting skipped ones).
        var placementCount = 0
    }

    private struct Placement {
        let parent: Int
        let child: Int
        let matrix: simd_double4x4
        let label: String
    }

    private struct Relation {
        let rep1: Int
        let rep2: Int
        let transformation: Int?
    }

    private static let representationTypes = STEPEdgeExtractor.representationTypes.union(["REPRESENTATION"])

    private let file: STEPFile
    private let model: STEP.EdgeModel
    private let options: STEP.Options
    private var diagnostics: [STEP.Diagnostic] = []
    /// Union-find over representation IDs; the root of a set is its smallest ID.
    private var parents: [Int: Int] = [:]
    private var scaleByContext: [Int: Result<Double, STEP.ParseError>] = [:]

    init(file: STEPFile, model: STEP.EdgeModel, options: STEP.Options) {
        self.file = file
        self.model = model
        self.options = options
    }

    // MARK: Entry

    func resolve() throws -> Resolution {
        try Task.checkCancellation()
        let representations = file.entities(ofTypes: Self.representationTypes)
        try joinSameCoordinateSystems()

        var bodiesByGroup: [Int: [STEP.BodyInfo]] = [:]
        for body in model.bodies { bodiesByGroup[find(body.id.representationID), default: []].append(body) }

        let usagePlacements = try productStructurePlacements()
        var placements: [Placement]
        var ignoredMapped = 0
        if usagePlacements.placed {
            placements = usagePlacements.all
            ignoredMapped = file.entities(ofTypes: ["MAPPED_ITEM"]).count
        } else {
            let mapped = try mappedItemPlacements(representations: representations)
            placements = mapped.isEmpty ? usagePlacements.all : mapped
        }
        if ignoredMapped > 0 {
            diagnose(nil, "The file has \(ignoredMapped) mapped items as well as assembly usages; the usages' placements are used",
                     .info, code: "assembly-mapped-ignored")
        }
        // Only a placement with a usable matrix counts (checked while reading, see `makePlacement`).
        placements.sort { ($0.parent, $0.child, $0.label) < ($1.parent, $1.child, $1.label) }

        var childrenByParent: [Int: [Placement]] = [:]
        for placement in placements { childrenByParent[placement.parent, default: []].append(placement) }
        let children = Set(placements.map { $0.child })
        var groups = Set(bodiesByGroup.keys)
        for placement in placements { groups.insert(placement.parent); groups.insert(placement.child) }
        let roots = groups.filter { !children.contains($0) }.sorted()

        var resolution = Resolution()
        var counts: [STEP.BodyID: Int] = [:]
        var visited: Set<Int> = []
        var limitHit = false
        let maximum = max(0, options.maximumInstanceCount)

        func visit(_ group: Int, _ matrix: simd_double4x4, _ path: [String], _ ancestors: Set<Int>) throws {
            try Task.checkCancellation()
            visited.insert(group)
            for body in bodiesByGroup[group] ?? [] {
                guard resolution.instances.count < maximum else { limitHit = true; return }
                let index = counts[body.id, default: 0]
                counts[body.id] = index + 1
                resolution.instances.append(Instance(prototype: body.id, matrix: matrix, path: path, index: index))
            }
            guard ancestors.count < 64 else {
                diagnose(nil, "Assembly nesting is deeper than 64 levels below #\(group); the rest is left out",
                         .skipped, code: "assembly-cycle")
                return
            }
            for placement in childrenByParent[group] ?? [] {
                if placement.child == group || ancestors.contains(placement.child) {
                    diagnose(nil, "Assembly usage \"\(placement.label)\" contains its own parent; it is left out",
                             .skipped, code: "assembly-cycle")
                    continue
                }
                try visit(placement.child, matrix * placement.matrix, path + [placement.label], ancestors.union([group]))
                if limitHit { return }
            }
        }

        for root in roots {
            try visit(root, matrix_identity_double4x4, [], [])
            if limitHit { break }
        }
        // A cycle can leave a group with bodies that no root reaches: show it where its file puts it.
        if !limitHit {
            for group in bodiesByGroup.keys.sorted() where !visited.contains(group) {
                try visit(group, matrix_identity_double4x4, [], [])
                if limitHit { break }
            }
        }
        if limitHit {
            diagnose(nil, "The assembly holds more than \(maximum) body instances; the rest are left out "
                     + "(raise Options.maximumInstanceCount)", .skipped, code: "instance-limit")
        }

        resolution.placementCount = placements.count
        let hasAssemblyEntities = !file.entities(ofTypes: ["MAPPED_ITEM", "NEXT_ASSEMBLY_USAGE_OCCURRENCE",
                                                           "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION"]).isEmpty
        if hasAssemblyEntities && placements.isEmpty {
            diagnose(nil, "The file has assembly entities but no placement could be read; bodies are imported untransformed",
                     .warning, code: "assembly-untransformed")
        }
        resolution.diagnostics = diagnostics
        return resolution
    }

    private func diagnose(_ id: Int?, _ message: String, _ severity: STEP.Diagnostic.Severity, code: String) {
        diagnostics.append(STEP.Diagnostic(entityID: id, message: message, severity: severity, code: code))
    }

    // MARK: Representation groups

    private func find(_ id: Int) -> Int {
        var root = id
        while let up = parents[root], up != root { root = up }
        var node = id
        while let up = parents[node], up != root {
            parents[node] = root
            node = up
        }
        return root
    }

    private func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        if rootA != rootB { parents[max(rootA, rootB)] = min(rootA, rootB) }
    }

    /// Plain relationships (no transformation) say two representations share a coordinate system.
    private func joinSameCoordinateSystems() throws {
        for id in file.entities(ofTypes: ["REPRESENTATION_RELATIONSHIP", "SHAPE_REPRESENTATION_RELATIONSHIP"]) {
            try Task.checkCancellation()
            if file.hasType(id, "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION") { continue }
            guard let parts = try? file.components(id),
                  let part = parts.first(where: { $0.type == "REPRESENTATION_RELATIONSHIP" && $0.parameters.count >= 4 })
                    ?? parts.first(where: { $0.type == "SHAPE_REPRESENTATION_RELATIONSHIP" && $0.parameters.count >= 4 }),
                  let first = try? part.parameters.reference(at: 2),
                  let second = try? part.parameters.reference(at: 3) else { continue }
            union(first, second)
        }
    }

    // MARK: Reading values

    private func representationParameters(_ id: Int) -> [STEPValue]? {
        guard let parts = try? file.components(id) else { return nil }
        let part = parts.first(where: { $0.type == "REPRESENTATION" })
            ?? parts.first(where: { STEPEdgeExtractor.representationTypes.contains($0.type) })
        return part?.parameters
    }

    /// Millimetres per unit of the representation's context. An unresolvable unit follows the same
    /// rule as the rest of the import: `Options.assumedUnitScaleToMM`, or a `.unresolvedUnits` error.
    private func unitScale(of representation: Int) throws -> Double {
        guard let parameters = representationParameters(representation),
              let context = try? parameters.reference(at: 2) else {
            throw STEP.ParseError("Representation #\(representation) has no context")
        }
        if let cached = scaleByContext[context] { return try cached.get() }
        let result: Result<Double, STEP.ParseError>
        do {
            result = .success(try STEPUnits(file: file).scaleToMM(contextID: context))
        } catch let error as STEP.ParseError {
            if let fallback = options.assumedUnitScaleToMM {
                result = .success(fallback)
            } else {
                result = .failure(STEP.ParseError(error.description, kind: .unresolvedUnits(contextID: context)))
            }
        }
        scaleByContext[context] = result
        return try result.get()
    }

    private func vector(_ id: Int, type: String) throws -> SIMD3<Double> {
        let parameters = try file.parameters(id, type: type)
        guard let list = try parameters.argument(1).list, list.count == 3 else {
            throw STEP.ParseError("Expected 3D \(type) at #\(id)")
        }
        var result = SIMD3<Double>.zero
        for axis in 0..<3 {
            guard let value = list[axis].number, value.isFinite else {
                throw STEP.ParseError("Nonfinite \(type) at #\(id)")
            }
            result[axis] = value
        }
        return result
    }

    private func optionalDirection(_ value: STEPValue) throws -> SIMD3<Double>? {
        switch value {
            case .unset:
                return nil
            case .reference(let id):
                let raw = try vector(id, type: "DIRECTION")
                let length = simd_length(raw)
                guard length.isFinite, length > 0 else { throw STEP.ParseError("Zero-length direction #\(id)") }
                return raw / length
            default:
                throw STEP.ParseError("Expected direction reference or $")
        }
    }

    /// Part (or assembly) coordinates → the coordinates of the representation holding the
    /// placement, as a matrix, with the origin converted to millimetres by `unitScale`.
    /// An `AXIS2_PLACEMENT_3D` is a frame; a `CARTESIAN_TRANSFORMATION_OPERATOR_3D` is a frame with a scale.
    private func axisMatrix(_ id: Int, unitScale: Double) throws -> simd_double4x4 {
        if file.hasType(id, "CARTESIAN_TRANSFORMATION_OPERATOR_3D") {
            return try operatorMatrix(id, unitScale: unitScale)
        }
        let p = try file.parameters(id, type: "AXIS2_PLACEMENT_3D")
        let origin = try vector(p.reference(at: 1), type: "CARTESIAN_POINT") * unitScale
        let z = try optionalDirection(p.argument(2)) ?? SIMD3<Double>(0, 0, 1)
        let seed = try optionalDirection(p.argument(3))
            ?? (abs(z.z) > 1 - 1e-12 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1))
        let projected = seed - simd_dot(seed, z) * z
        let length = simd_length(projected)
        guard length > 1e-9 else {
            throw STEP.ParseError("Degenerate placement #\(id): reference direction is parallel to the axis")
        }
        let x = projected / length
        return STEPPlacement.matrix(origin: origin, x: x, y: simd_cross(z, x), z: z)
    }

    /// `CARTESIAN_TRANSFORMATION_OPERATOR_3D(name, description, axis1, axis2, local_origin, scale, axis3)`.
    private func operatorMatrix(_ id: Int, unitScale: Double) throws -> simd_double4x4 {
        let p = try file.parameters(id, type: "CARTESIAN_TRANSFORMATION_OPERATOR_3D")
        guard p.count >= 7 else { throw STEP.ParseError("Unsupported transformation operator layout at #\(id)") }
        let origin = try vector(p.reference(at: 4), type: "CARTESIAN_POINT") * unitScale
        let scale = p[5] == .unset ? 1 : (p[5].number ?? 0)
        guard scale.isFinite, scale > 0 else { throw STEP.ParseError("Invalid scale in transformation operator #\(id)") }
        let z = try optionalDirection(p[6]) ?? SIMD3<Double>(0, 0, 1)
        let seed = try optionalDirection(p[2])
            ?? (abs(z.z) > 1 - 1e-12 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1))
        let projected = seed - simd_dot(seed, z) * z
        let length = simd_length(projected)
        guard length > 1e-9 else { throw STEP.ParseError("Degenerate transformation operator #\(id)") }
        let x = projected / length
        return STEPPlacement.matrix(origin: origin, x: x, y: simd_cross(z, x), z: z, scale: scale)
    }

    private func text(_ value: STEPValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }

    /// The product name behind a `PRODUCT_DEFINITION`, for labelling an occurrence the file leaves unnamed.
    private func productName(ofDefinition definition: Int) -> String? {
        guard let parameters = try? file.parameters(definition, type: "PRODUCT_DEFINITION"),
              let formationID = try? parameters.reference(at: 2),
              let formation = (try? file.components(formationID))?.first(where: {
                  $0.type == "PRODUCT_DEFINITION_FORMATION" || $0.type == "PRODUCT_DEFINITION_FORMATION_WITH_SPECIFIED_SOURCE"
              }),
              let productID = try? formation.parameters.reference(at: 2),
              let product = try? file.parameters(productID, type: "PRODUCT") else { return nil }
        return text(product.count > 1 ? product[1] : nil) ?? text(product.first)
    }

    private func makePlacement(parent: Int, child: Int, matrix: simd_double4x4, label: String) throws -> Placement {
        guard STEPPlacement(matrix) != nil else {
            throw STEP.ParseError("The placement of \"\(label)\" is not a rotation with a uniform scale")
        }
        return Placement(parent: parent, child: child, matrix: matrix, label: label)
    }

    // MARK: Product structure

    /// `placed` is true when at least one usage came with a transformation.
    private func productStructurePlacements() throws -> (all: [Placement], placed: Bool) {
        let usages = file.entities(ofTypes: ["NEXT_ASSEMBLY_USAGE_OCCURRENCE"])
        guard !usages.isEmpty else { return ([], false) }

        var definitionOfShape: [Int: Int] = [:]
        for id in file.entities(ofTypes: ["PRODUCT_DEFINITION_SHAPE"]) {
            if let p = try? file.parameters(id, type: "PRODUCT_DEFINITION_SHAPE"), let definition = try? p.reference(at: 2) {
                definitionOfShape[id] = definition
            }
        }
        var representationOfDefinition: [Int: Int] = [:]
        for id in file.entities(ofTypes: ["SHAPE_DEFINITION_REPRESENTATION"]) {
            if let p = try? file.parameters(id, type: "SHAPE_DEFINITION_REPRESENTATION"),
               let shape = try? p.reference(at: 0), let representation = try? p.reference(at: 1),
               let definition = definitionOfShape[shape], representationOfDefinition[definition] == nil {
                representationOfDefinition[definition] = representation
            }
        }
        var relationOfUsage: [Int: Int] = [:]
        for id in file.entities(ofTypes: ["CONTEXT_DEPENDENT_SHAPE_REPRESENTATION"]) {
            if let p = try? file.parameters(id, type: "CONTEXT_DEPENDENT_SHAPE_REPRESENTATION"),
               let relation = try? p.reference(at: 0), let shape = try? p.reference(at: 1),
               let usage = definitionOfShape[shape], relationOfUsage[usage] == nil {
                relationOfUsage[usage] = relation
            }
        }

        var result: [Placement] = []
        var anyPlaced = false
        for usage in usages {
            try Task.checkCancellation()
            do {
                let p = try file.parameters(usage, type: "NEXT_ASSEMBLY_USAGE_OCCURRENCE")
                let relating = try p.reference(at: 3)
                let related = try p.reference(at: 4)
                let label = text(p.count > 1 ? p[1] : nil) ?? productName(ofDefinition: related) ?? "#\(usage)"
                let parentGroup = representationOfDefinition[relating].map { find($0) }
                let childGroup = representationOfDefinition[related].map { find($0) }

                if let relationID = relationOfUsage[usage] {
                    let link = try relation(relationID)
                    var child = find(link.rep1)
                    var parent = find(link.rep2)
                    var matrix = try transformationMatrix(link)
                    // The usual order is (child, parent). The product structure can contradict it.
                    if let parentGroup, let childGroup, parentGroup != childGroup, child == parentGroup, parent == childGroup {
                        swap(&child, &parent)
                        matrix = simd_inverse(matrix)
                    }
                    result.append(try makePlacement(parent: parent, child: child, matrix: matrix, label: label))
                    anyPlaced = true
                } else if let parentGroup, let childGroup {
                    diagnose(usage, "Assembly usage \"\(label)\" has no placement; it is put at its parent's origin",
                             .warning, code: "assembly-no-placement")
                    result.append(try makePlacement(parent: parentGroup, child: childGroup,
                                                    matrix: matrix_identity_double4x4, label: label))
                } else {
                    throw STEP.ParseError("Assembly usage \"\(label)\" has no placement and its products have no shape")
                }
            } catch let error as STEP.ParseError {
                diagnose(usage, error.description, .skipped, code: "assembly-placement-skipped")
            }
        }
        return (result, anyPlaced)
    }

    /// `REPRESENTATION_RELATIONSHIP(name, description, rep_1, rep_2)` plus, in a complex record,
    /// `REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(transformation_operator)`.
    private func relation(_ id: Int) throws -> Relation {
        let parts = try file.components(id)
        if let transformed = parts.first(where: { $0.type == "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION" }) {
            if let base = parts.first(where: { $0.type == "REPRESENTATION_RELATIONSHIP" }), base.parameters.count >= 4 {
                return Relation(rep1: try base.parameters.reference(at: 2), rep2: try base.parameters.reference(at: 3),
                                transformation: try transformed.parameters.reference(at: 0))
            }
            // One simple record: name, description, rep_1, rep_2, transformation_operator.
            if transformed.parameters.count >= 5 {
                return Relation(rep1: try transformed.parameters.reference(at: 2),
                                rep2: try transformed.parameters.reference(at: 3),
                                transformation: try transformed.parameters.reference(at: 4))
            }
        } else if let base = parts.first(where: { $0.type == "REPRESENTATION_RELATIONSHIP" || $0.type == "SHAPE_REPRESENTATION_RELATIONSHIP" }),
                  base.parameters.count >= 4 {
            return Relation(rep1: try base.parameters.reference(at: 2), rep2: try base.parameters.reference(at: 3),
                            transformation: nil)
        }
        throw STEP.ParseError("Unsupported representation relationship #\(id)")
    }

    /// The matrix that takes `rep_1`'s coordinates to `rep_2`'s. With `ITEM_DEFINED_TRANSFORMATION`
    /// it moves the first placement onto the second: `second * inverse(first)`.
    private func transformationMatrix(_ relation: Relation) throws -> simd_double4x4 {
        guard let operatorID = relation.transformation else { return matrix_identity_double4x4 }
        let scale1 = try unitScale(of: relation.rep1)
        let scale2 = try unitScale(of: relation.rep2)
        if file.hasType(operatorID, "ITEM_DEFINED_TRANSFORMATION") {
            let p = try file.parameters(operatorID, type: "ITEM_DEFINED_TRANSFORMATION")
            let first = try axisMatrix(try p.reference(at: 2), unitScale: scale1)
            let second = try axisMatrix(try p.reference(at: 3), unitScale: scale2)
            return second * simd_inverse(first)
        }
        if file.hasType(operatorID, "CARTESIAN_TRANSFORMATION_OPERATOR_3D") {
            return try operatorMatrix(operatorID, unitScale: scale2)
        }
        throw STEP.ParseError("Unsupported transformation #\(operatorID)")
    }

    // MARK: Mapped items

    private func mappedItemPlacements(representations: [Int]) throws -> [Placement] {
        let mappedItems = file.entities(ofTypes: ["MAPPED_ITEM"])
        guard !mappedItems.isEmpty else { return [] }

        // Which representation lists each mapped item among its items.
        var containerOf: [Int: Int] = [:]
        for representation in representations {
            try Task.checkCancellation()
            guard let items = try? representationParameters(representation)?.references(at: 1) else { continue }
            for item in items where file.hasType(item, "MAPPED_ITEM") && containerOf[item] == nil {
                containerOf[item] = representation
            }
        }

        var result: [Placement] = []
        for item in mappedItems {
            try Task.checkCancellation()
            do {
                // Simple record: (name, mapping_source, mapping_target); in a complex record the name
                // lives in another component and only the last two are left.
                let p = try file.parameters(item, type: "MAPPED_ITEM")
                let offset = p.count >= 3 ? 1 : 0
                let name = offset == 1 ? text(p.first) : nil
                let source = try p.reference(at: offset)
                let target = try p.reference(at: offset + 1)
                guard let container = containerOf[item] else {
                    throw STEP.ParseError("Mapped item #\(item) is not an item of any representation")
                }
                let map = try file.parameters(source, type: "REPRESENTATION_MAP")
                let origin = try map.reference(at: 0)
                let mapped = try map.reference(at: 1)
                let originMatrix = try axisMatrix(origin, unitScale: try unitScale(of: mapped))
                let targetMatrix = try axisMatrix(target, unitScale: try unitScale(of: container))
                let label = name ?? "#\(item)"
                result.append(try makePlacement(parent: find(container), child: find(mapped),
                                                matrix: targetMatrix * simd_inverse(originMatrix), label: label))
            } catch let error as STEP.ParseError {
                diagnose(item, error.description, .skipped, code: "assembly-placement-skipped")
            }
        }
        return result
    }
}
